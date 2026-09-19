defmodule OpsBrain.AzureBuild do
  @moduledoc "Azure Build REST 7.1 reads only; classic release APIs are not supported."
  alias OpsBrain.{Transport, Store, Redactor}

  def list(c, state) do
    query = [
      {"api-version", "7.1"},
      {"definitions", Enum.join(c.definitions, ",")},
      {"$top", c.page_size}
    ]

    query =
      if state["mode"] == "active" do
        query ++
          [
            {"statusFilter", "notStarted,inProgress,postponed"},
            {"queryOrder", "queueTimeAscending"}
          ]
      else
        query ++
          [
            {"statusFilter", "completed"},
            {"queryOrder", "finishTimeAscending"},
            {"minTime", Store.iso(state["window_start"])},
            {"maxTime", Store.iso(state["window_end"])}
          ]
      end

    query = if state["cursor"], do: query ++ [{"continuationToken", state["cursor"]}], else: query
    Transport.get(c, base(c), query)
  end

  def run(c, id) when is_integer(id) and id > 0,
    do: Transport.get(c, base(c) <> "/#{id}", [{"api-version", "7.1"}])

  def timeline(c, id) when is_integer(id) and id > 0,
    do: Transport.get(c, base(c) <> "/#{id}/timeline", [{"api-version", "7.1"}])

  def log(c, run, log, first, last)
      when is_integer(run) and run > 0 and is_integer(log) and log > 0 and is_integer(first) and
             first >= 0 and is_integer(last) and last >= first and last - first <= 200 do
    Transport.get(c, base(c) <> "/#{run}/logs/#{log}", [
      {"api-version", "7.1"},
      {"startLine", first},
      {"endLine", last}
    ])
  end

  defp base(c), do: "/#{c.organization}/#{c.project_id}/_apis/build/builds"

  def decode(c, response) do
    with 200 <- response.status,
         {:ok, body} <- Jason.decode(response.body),
         rows when is_list(rows) <- body["value"],
         true <- length(rows) <= c.page_size do
      normalized = Enum.map(rows, &normalize(c, &1))
      token = List.first(Map.get(response.headers, "x-ms-continuationtoken", []))

      if Enum.any?(normalized, &match?({:error, _}, &1)) or (token && byte_size(token) > 2048) do
        {:error, :invalid_page}
      else
        {:ok, Enum.map(normalized, &elem(&1, 1)), token}
      end
    else
      _ -> {:error, :invalid_page}
    end
  end

  def normalize(c, r) when is_map(r) do
    with id when is_integer(id) and id > 0 <- r["id"],
         %{"id" => project} <- r["project"],
         true <- project == c.project_id,
         %{"id" => definition} <- r["definition"],
         true <- definition in c.definitions,
         status
         when status in ["notStarted", "inProgress", "completed", "postponed", "cancelling"] <-
           r["status"],
         true <- status != "completed" or Store.parse(r["finishTime"]) != nil do
      result =
        if r["result"] in ["succeeded", "failed", "canceled", "partiallySucceeded", "none"],
          do: r["result"],
          else: "unknown"

      {:ok,
       %{
         "run_id" => id,
         "project_id" => project,
         "definition_id" => definition,
         "status" => status,
         "result" => result,
         "finish_at" => r["finishTime"],
         "queue_at" => r["queueTime"],
         "start_at" => r["startTime"],
         "branch" => Redactor.clean(r["sourceBranch"] || "", 256),
         "commit" => Redactor.clean(r["sourceVersion"] || "", 100),
         "environment" => nil
       }}
    else
      _ -> {:error, :out_of_scope_or_malformed_run}
    end
  end

  def normalize(_, _), do: {:error, :malformed_run}
end
