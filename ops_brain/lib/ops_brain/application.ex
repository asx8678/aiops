defmodule OpsBrain.Application do
  use Application

  @impl true
  def start(_type, _args) do
    OpsBrain.Configuration.load!()

    children = [
      OpsBrain.Repo,
      OpsBrain.DatabaseSafety,
      OpsBrainWeb.Telemetry,
      {Phoenix.PubSub, name: OpsBrain.PubSub},
      {Oban, Application.fetch_env!(:ops_brain, Oban)},
      OpsBrainWeb.LoginLimiter,
      OpsBrainWeb.Endpoint,
      {Registry, keys: :unique, name: OpsBrain.WatchRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: OpsBrain.WatchSupervisor},
      OpsBrain.Scheduler
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OpsBrain.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    OpsBrainWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
