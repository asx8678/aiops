defmodule Mix.Tasks.OpsBrain.ValidateConfig do
  use Mix.Task

  @shortdoc "Validate deployment-owned source/sink configuration without network or database effects"
  def run([path]) do
    cfg = OpsBrain.Configuration.read!(path)

    Mix.shell().info(
      "Valid static configuration: #{map_size(cfg.sources)} sources, #{map_size(cfg.notification_sinks)} notification destinations. No credential or live access check performed."
    )
  end

  def run(_), do: Mix.raise("Usage: mix ops_brain.validate_config /approved/local/config.json")
end
