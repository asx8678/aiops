defmodule OpsBrain.Replay do
  @moduledoc "Bounded, read-only offline detector replay. See docs/REPLAY_RETENTION.md."
  alias OpsBrain.{Repo, Store, Tenancy}
  alias OpsBrain.Replay.Detectors

  @doc "Page latest-known observation revisions or evidence with separate event/knowledge cutoffs."
  def page(scope, opts \\ []) do
    with {:ok, p} <- options(opts),
         {:ok, after_time, after_id} <- cursor(p, scope) do
      read_scope(scope, fn ->
        rows =
          Store.rows(
            query(p.stream) <>
              """
              SELECT * FROM inputs
              WHERE ($4::timestamp IS NULL OR (occurred_at,id) > ($4,$5::text))
              ORDER BY occurred_at,id LIMIT $6
              """,
            [p.occurred_before, p.received_before, p.source_id, after_time, after_id, p.limit + 1]
          )

        selected = Enum.take(rows, p.limit)
        more = length(rows) > p.limit
        last = List.last(selected)

        %{
          items: Enum.map(selected, &evaluate(&1, p)),
          continuation: if(more, do: continuation(last, p, scope), else: nil),
          complete: not more,
          occurred_before: p.occurred_before,
          received_before: p.received_before,
          coverage: "retained inputs only; missing/deleted history is not a healthy result"
        }
      end)
    end
  end

  @doc "Fetch one evidence ID or observation window ID; absent and invisible IDs are indistinguishable."
  def one(scope, id, opts \\ []) do
    with {:ok, _} <- Ecto.UUID.cast(id), {:ok, p} <- options(opts) do
      read_scope(scope, fn ->
        key = if p.stream == :observations, do: "window_id", else: "id"

        row =
          Store.one(
            query(p.stream) <> "SELECT * FROM inputs WHERE #{key}=$4 LIMIT 1",
            [p.occurred_before, p.received_before, p.source_id, id]
          )

        if row, do: evaluate(row, p), else: %{id: id, status: :missing_or_not_known, exact: false}
      end)
    else
      :error -> {:error, :invalid_id}
      error -> error
    end
  end

  @doc "Offline correlation of explicit retained evidence IDs and caller-supplied topology, not historical configuration."
  def correlate(scope, symptom_id, change_ids, topology, opts \\ []) do
    with {:ok, p} <- options(opts),
         true <- is_list(change_ids) and length(change_ids) <= 20,
         true <- Enum.all?([symptom_id | change_ids], &match?({:ok, _}, Ecto.UUID.cast(&1))),
         true <- is_list(topology) and length(topology) <= 100,
         true <-
           Enum.all?(topology, fn
             {a, b} -> is_binary(a) and is_binary(b)
             _ -> false
           end) do
      read_scope(scope, fn ->
        ids = Enum.uniq([symptom_id | change_ids])

        rows =
          Store.rows(
            """
            SELECT id::text,company_id::text,source_id::text,kind,occurred_at,received_at,expires_at,data
            FROM evidence_items WHERE id::text=ANY($1) AND occurred_at <= $2 AND received_at <= $3
            AND ($4::text IS NULL OR source_id=$4::text::uuid)
            """,
            [ids, p.occurred_before, p.received_before, p.source_id]
          )

        cond do
          length(rows) != length(ids) ->
            %{status: :missing_or_not_known, exact: false}

          Enum.any?(rows, &expired?(&1, Store.now())) ->
            %{status: :expired, exact: false}

          Enum.any?(
            rows,
            &(not is_binary(&1["data"]["target_id"]) or
                  not is_binary(&1["data"]["environment_id"]))
          ) ->
            %{status: :missing_inputs, exact: false}

          Enum.any?(rows, &(&1["id"] in change_ids and &1["kind"] != "deployment")) ->
            %{status: :unsupported_kind, exact: false}

          true ->
            symptom = Enum.find(rows, &(&1["id"] == symptom_id))
            changes = Enum.filter(rows, &(&1["id"] in change_ids))

            Detectors.correlate(
              fact(symptom),
              Enum.map(changes, &fact/1),
              topology,
              p.occurred_before,
              p.received_before
            )
        end
      end)
    else
      false -> {:error, :invalid_inputs}
      error -> error
    end
  end

  # Compatibility entry point; use page/2 for resumable traversal.
  def fingerprints(scope, now, version \\ 1) do
    if version != OpsBrain.Fingerprints.version() do
      {:error, :parser_version_unavailable}
    else
      read_scope(scope, fn ->
        Store.rows(
          """
          SELECT id::text,company_id::text,source_id::text,kind,data,expires_at
          FROM evidence_items WHERE kind='pipeline_task' AND received_at <= $1 AND occurred_at <= $1
          ORDER BY occurred_at,id LIMIT 1000
          """,
          [now]
        )
        |> Enum.map(fn row ->
          result =
            Detectors.evaluate(
              Map.put(row, "detector_version", Map.get(row["data"], "parser_version", 1)),
              now,
              now,
              Store.now()
            )

          case result do
            %{status: :ok, result: value} ->
              %{evidence_id: row["id"], result: value}

            %{status: :expired} ->
              %{evidence_id: row["id"], status: "expired: exact replay unavailable"}

            other ->
              Map.put(other, :evidence_id, row["id"])
          end
        end)
      end)
    end
  end

  defp read_scope(scope, fun) do
    Tenancy.with_scope(scope, fn ->
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      fun.()
    end)
  end

  defp query(:observations) do
    """
    WITH inputs AS (
      SELECT r.id::text,r.company_id::text,r.source_id::text,r.service_id::text,r.window_id::text,
        r.profile,r.kind,r.window_start,r.window_end AS occurred_at,r.received_at,r.revision,
        r.data,r.policy,r.detector_version,e.expires_at,(e.data->>'expired'='true') AS retention_expired
      FROM observation_revisions r
      LEFT JOIN evidence_items e ON e.company_id=r.company_id AND e.source_id=r.source_id
        AND e.evidence_key='window:' || r.window_id::text || ':' || r.revision::text
      WHERE r.window_end <= $1 AND r.received_at <= $2
        AND ($3::text IS NULL OR r.source_id=$3::text::uuid)
        AND NOT EXISTS (SELECT 1 FROM observation_revisions newer
          WHERE newer.company_id=r.company_id AND newer.window_id=r.window_id
            AND newer.window_end <= $1 AND newer.received_at <= $2 AND newer.revision > r.revision)
    )
    """
  end

  defp query(:evidence) do
    """
    WITH inputs AS (
      SELECT id::text,company_id::text,source_id::text,kind,occurred_at,received_at,expires_at,data
      FROM evidence_items WHERE occurred_at <= $1 AND received_at <= $2
        AND ($3::text IS NULL OR source_id=$3::text::uuid)
    )
    """
  end

  defp evaluate(row, p) do
    row =
      if p.stream == :evidence do
        version =
          case row["kind"] do
            "pipeline_task" -> Map.get(row["data"], "parser_version", 1)
            _ -> row["data"]["version"]
          end

        # Output-only old correlations are missing inputs, not a claim of a new parser.
        version = if row["kind"] == "correlation" and version == nil, do: 1, else: version
        Map.put(row, "detector_version", version)
      else
        row
      end

    result = Detectors.evaluate(row, p.occurred_before, p.received_before, Store.now())

    result =
      if p.stream == :observations and row["kind"] in ["prometheus", "loki", "kubernetes"] and
           result.status == :ok,
         do: persistence(row, result, p),
         else: result

    Map.merge(result, %{
      id: row["id"],
      window_id: row["window_id"],
      revision: row["revision"],
      kind: row["kind"]
    })
  end

  defp persistence(row, result, p) do
    prior =
      Store.one(
        """
        SELECT r.company_id::text,r.source_id::text,r.service_id::text,r.kind,r.data,r.policy,r.detector_version,e.expires_at,
          (e.data->>'expired'='true') AS retention_expired
        FROM observation_revisions r
        LEFT JOIN evidence_items e ON e.company_id=r.company_id AND e.source_id=r.source_id
          AND e.evidence_key='window:' || r.window_id::text || ':' || r.revision::text
        WHERE r.source_id=$1::text::uuid AND r.profile=$2 AND r.window_end=$3 AND r.received_at <= $4
        ORDER BY r.revision DESC LIMIT 1
        """,
        [row["source_id"], row["profile"], row["window_start"], p.received_before]
      )

    previous =
      if prior, do: Detectors.evaluate(prior, p.occurred_before, p.received_before, Store.now())

    breached = result.result.condition in ["warning", "critical", "watch"]

    sustained =
      cond do
        not breached -> false
        row["service_id"] == nil -> false
        previous == nil -> :missing_prior_window
        previous.status != :ok -> :missing_prior_window
        true -> previous.result.condition in ["warning", "critical", "watch"]
      end

    Map.put(result, :sustained, sustained)
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(
           Keyword.keys(opts),
           &(&1 in [
               :occurred_before,
               :received_before,
               :limit,
               :stream,
               :source_id,
               :continuation
             ])
         ) do
      occurred = Keyword.get(opts, :occurred_before)
      received = Keyword.get(opts, :received_before, occurred)
      limit = Keyword.get(opts, :limit, 100)
      stream = Keyword.get(opts, :stream, :observations)
      source = Keyword.get(opts, :source_id)

      if match?(%DateTime{}, occurred) and match?(%DateTime{}, received) and
           is_integer(limit) and limit in 1..100 and stream in [:observations, :evidence] and
           (source == nil or match?({:ok, _}, Ecto.UUID.cast(source))) do
        {:ok,
         %{
           occurred_before: occurred,
           received_before: received,
           limit: limit,
           stream: stream,
           source_id: source,
           cursor: Keyword.get(opts, :continuation)
         }}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp options(_), do: {:error, :invalid_options}

  defp binding(p, scope),
    do:
      Store.digest(
        {scope.company_id, p.stream, p.source_id, Store.iso(p.occurred_before),
         Store.iso(p.received_before)}
      )

  defp cursor(%{cursor: nil}, _), do: {:ok, nil, nil}

  defp cursor(%{cursor: %{"version" => 1, "binding" => b, "at" => at, "id" => id}} = p, scope) do
    with true <- b == binding(p, scope),
         %DateTime{} = time <- Store.parse(at),
         {:ok, _} <- Ecto.UUID.cast(id) do
      {:ok, time, id}
    else
      _ -> {:error, :invalid_continuation}
    end
  end

  defp cursor(_, _), do: {:error, :invalid_continuation}

  defp continuation(row, p, scope),
    do: %{
      "version" => 1,
      "binding" => binding(p, scope),
      "at" => Store.iso(row["occurred_at"]),
      "id" => row["id"]
    }

  defp expired?(row, now),
    do: row["data"]["expired"] == true or DateTime.compare(row["expires_at"], now) != :gt

  defp fact(row),
    do: %{
      company_id: row["company_id"],
      environment_id: row["data"]["environment_id"],
      target_id: row["data"]["target_id"],
      evidence_id: row["id"],
      occurred_at: DateTime.to_unix(row["occurred_at"]),
      received_at: DateTime.to_unix(row["received_at"])
    }
end
