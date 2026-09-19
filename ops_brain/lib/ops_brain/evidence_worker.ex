defmodule OpsBrain.EvidenceWorker do
  use Oban.Worker,
    queue: :enrich,
    max_attempts: 3,
    unique: [period: 120, fields: [:worker, :args]]

  alias OpsBrain.{AzureBuild, SourceConfig, Evidence, Store}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => id, "run_id" => run} = args}) do
    if Application.get_env(:ops_brain, :collection_enabled, false),
      do: collect(id, run, args),
      else: :discard
  end

  defp collect(id, run, args) do
    with {:ok, c} <- SourceConfig.fetch(id),
         {:ok, %{"revision" => expected_revision}} <-
           SourceConfig.transaction(id, fn _ ->
             Store.one(
               "SELECT revision FROM pipeline_runs WHERE source_id=$1::text::uuid AND run_id=$2 AND status='completed' AND ($3::bigint IS NULL OR revision=$3)",
               [id, run, args["revision"]]
             )
           end),
         {:ok, %{status: 200, body: body}} <- AzureBuild.timeline(c, run),
         {:ok, leaves} <- Evidence.parse_timeline(body) do
      # One bounded log read maximum per enrichment tick. Structured issues take precedence.
      records =
        Enum.map(
          leaves,
          &Map.put(
            &1,
            "evidence_status",
            if(&1["issues"] == [], do: "log_not_sampled", else: "structured")
          )
        )

      records =
        case records do
          [first | rest] -> [enrich(c, run, first) | rest]
          [] -> []
        end

      persisted =
        SourceConfig.transaction(id, fn trusted ->
          current =
            Store.one(
              "SELECT revision FROM pipeline_runs WHERE source_id=$1::text::uuid AND run_id=$2 FOR UPDATE",
              [id, run]
            )

          if current == nil or current["revision"] != expected_revision,
            do: OpsBrain.Repo.rollback(:stale_run_revision)

          now = Store.now()
          OpsBrain.Deployments.persist(trusted, run, body, now)

          for r <- records do
            key = "run:#{run}:#{r["record_id"]}:#{r["attempt"]}"
            Evidence.failure(trusted, key, r, run, now)
          end

          if records == [], do: Evidence.unavailable(trusted, run, :no_failed_leaf_evidence, now)
        end)

      case persisted do
        {:ok, _} ->
          if Enum.any?(records, &(&1["evidence_status"] == "log_unavailable")),
            do: {:error, :log_unavailable},
            else: :ok

        _ ->
          {:error, :evidence_not_persisted}
      end
    else
      _ ->
        SourceConfig.transaction(id, fn c ->
          Evidence.unavailable(c, run, :timeline_unavailable, Store.now())
        end)

        {:error, :timeline_unavailable}
    end
  end

  defp enrich(c, run, %{"issues" => [], "log_id" => log} = r) when is_integer(log) and log > 0 do
    case AzureBuild.log(c, run, log, 0, 199) do
      {:ok, %{status: 200, body: body}} ->
        Map.merge(r, %{
          "snippet" => OpsBrain.Redactor.clean(body),
          "evidence_status" => "bounded_head_sample",
          "line_start" => 0,
          "line_end" => 199,
          "missing" => "Only the first 200 lines requested; later failure context may be missing"
        })

      _ ->
        Map.put(r, "evidence_status", "log_unavailable")
    end
  end

  defp enrich(_, _, r), do: r
end
