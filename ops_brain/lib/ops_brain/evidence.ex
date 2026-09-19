defmodule OpsBrain.Evidence do
  @moduledoc "Selected bounded timeline facts with explicit attempt/hierarchy provenance."
  alias OpsBrain.{Store, Redactor, Fingerprints}

  def parse_timeline(body) do
    with {:ok, %{"records" => records}} <- Jason.decode(body),
         true <- is_list(records) and length(records) <= 500 do
      parents = MapSet.new(Enum.map(records, & &1["parentId"]))

      records
      |> Enum.filter(
        &(&1["result"] in ["failed", "abandoned"] and not MapSet.member?(parents, &1["id"]))
      )
      |> Enum.take(40)
      |> Enum.map(fn r ->
        %{
          "record_id" => Redactor.clean(r["id"], 100),
          "coverage_limit" =>
            "At most 40 failed leaves, 10 issues and 10 prior-attempt references; historical attempt timelines are not fetched",
          "parent_id" => Redactor.clean(r["parentId"] || "", 100),
          "attempt" => if(is_integer(r["attempt"]), do: r["attempt"], else: 1),
          "name" => Redactor.clean(r["name"] || "", 100),
          "tool" => Redactor.clean(get_in(r, ["task", "id"]) || r["type"] || "unknown", 100),
          "result" => r["result"],
          "occurred_at" => r["finishTime"],
          "log_id" => get_in(r, ["log", "id"]),
          "issues" =>
            Enum.take(r["issues"] || [], 10)
            |> Enum.map(&Redactor.clean(&1["message"] || "", 1000)),
          "previous_attempts" =>
            Enum.take(r["previousAttempts"] || [], 10)
            |> Enum.map(fn a ->
              %{
                "attempt" => if(is_integer(a["attempt"]), do: a["attempt"], else: nil),
                "timelineId" => Redactor.clean(a["timelineId"] || "", 100),
                "recordId" => Redactor.clean(a["recordId"] || "", 100)
              }
            end)
        }
      end)
      |> then(&{:ok, &1})
    else
      _ -> {:error, :timeline_unavailable_or_truncated}
    end
  rescue
    _ -> {:error, :malformed_timeline}
  end

  def save(c, key, kind, data, occurred, now) do
    id = Ecto.UUID.generate()

    data =
      if byte_size(Jason.encode!(data)) > 30_000 do
        %{
          "evidence_truncated" => true,
          "reason" => "evidence storage byte budget",
          "kind" => kind,
          "count" => data["count"],
          "sample_entries_returned" => length(data["samples"] || []),
          "reference" => key
        }
      else
        data
      end

    row =
      Store.one(
        """
        INSERT INTO evidence_items(id,company_id,source_id,evidence_key,kind,occurred_at,received_at,expires_at,data)
        VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,$6,$7,$8,$9)
        ON CONFLICT(company_id,source_id,evidence_key) DO UPDATE SET evidence_key=EXCLUDED.evidence_key
        RETURNING id::text
        """,
        [
          id,
          c.company_id,
          c.id,
          key,
          kind,
          occurred || now,
          now,
          DateTime.add(now, c.retention_days, :day),
          data
        ]
      )

    row["id"]
  end

  def failure(c, key, data, run_id, now) do
    evidence_id =
      save(
        c,
        key <> ":" <> Store.digest(data),
        "pipeline_task",
        data,
        Store.parse(data["occurred_at"]),
        now
      )

    text = Enum.join(data["issues"] || [], "\n")
    text = if text == "", do: data["snippet"] || "Unclassified failed operation", else: text
    fp = Fingerprints.identify(c.company_id, {c.id, "CI-only"}, data["tool"], text)

    OpsBrain.Issues.record(
      c,
      key,
      evidence_id,
      fp,
      %{
        run_id: run_id,
        attempt: data["attempt"],
        occurred_at: Store.parse(data["occurred_at"]) || now
      },
      now
    )

    evidence_id
  end

  def unavailable(c, run, reason, now),
    do:
      save(
        c,
        "run:#{run}:unavailable:#{reason}",
        "missing",
        %{"run_id" => run, "reason" => to_string(reason)},
        now,
        now
      )
end
