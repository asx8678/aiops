defmodule OpsBrainWeb.LoginLimiter do
  @moduledoc "Bounded per-instance login admission. Peer IP only; no trusted user-controlled forwarded headers."
  use GenServer
  import Plug.Conn

  def start_link(opts), do: GenServer.start_link(__MODULE__, {:server, opts}, name: __MODULE__)
  def init({:server, _}), do: {:ok, %{window: nil, total: 0, peers: %{}}}
  def init(opts), do: opts

  def call(conn, _opts) do
    if (conn.method == "POST" and conn.request_path in ["/sign-in", "/auth/oidc"]) or
         conn.request_path == "/auth/oidc/callback" do
      case GenServer.call(__MODULE__, {:allow, conn.remote_ip, System.monotonic_time(:second)}) do
        :ok ->
          conn

        :limited ->
          conn
          |> put_resp_header("retry-after", "60")
          |> send_resp(429, "Sign-in rate limit; retry later")
          |> halt()
      end
    else
      conn
    end
  end

  def handle_call({:allow, peer, now}, _, state) do
    {result, state} = admit(state, peer, now)
    {:reply, result, state}
  end

  @doc false
  def admit(state, peer, now) do
    window = div(now, 60)
    state = if state.window == window, do: state, else: %{window: window, total: 0, peers: %{}}
    count = Map.get(state.peers, peer, 0)

    if state.total >= 200 or count >= 30 do
      {:limited, state}
    else
      {:ok, %{state | total: state.total + 1, peers: Map.put(state.peers, peer, count + 1)}}
    end
  end
end
