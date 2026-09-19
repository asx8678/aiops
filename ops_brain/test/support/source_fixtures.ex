defmodule OpsBrain.SourceFixtures do
  @moduledoc "Synthetic HTTP-boundary fixture helpers. No real endpoints/credentials."
  def config(f, side \\ :a, extra \\ %{}) do
    source = Map.fetch!(f, if(side == :a, do: :source_a, else: :source_b))

    c =
      Map.merge(
        %{
          id: source.id,
          company_id: source.company_id,
          kind: "azure_build",
          endpoint: "https://ado.invalid",
          approved_origins: ["https://ado.invalid"],
          approved_ips: ["192.0.2.1"],
          network_reviewed: true,
          enabled: true,
          anonymous_approved: true,
          interval_seconds: 30,
          max_bytes: 200_000,
          page_size: 100,
          max_pages: 10,
          max_window_seconds: 3600,
          retention_days: 7,
          requests_per_minute: 60,
          organization: "synthetic",
          project_id: "00000000-0000-4000-8000-000000000020",
          definitions: [7]
        },
        extra
      )

    Application.put_env(:ops_brain, :collection_enabled, true)
    Application.put_env(:ops_brain, :sources, Map.put(OpsBrain.SourceConfig.all(), c.id, c))
    c
  end

  def run(c, id, result \\ "failed") do
    %{
      "id" => id,
      "project" => %{"id" => c.project_id},
      "definition" => %{"id" => 7},
      "status" => "completed",
      "result" => result,
      "queueTime" => "2025-01-01T00:00:00Z",
      "finishTime" => "2025-01-02T00:30:00Z",
      "sourceBranch" => "refs/heads/main"
    }
  end

  def page(rows, token \\ nil) do
    %{
      status: 200,
      headers: if(token, do: %{"x-ms-continuationtoken" => [token]}, else: %{}),
      body: Jason.encode!(%{value: rows}),
      bytes: 100
    }
  end

  def cleanup do
    for key <- [
          :sources,
          :collection_enabled,
          :clock,
          :http_plug,
          :notification_sinks,
          :notification_plug,
          :delivery_enabled
        ],
        do: Application.delete_env(:ops_brain, key)
  end
end
