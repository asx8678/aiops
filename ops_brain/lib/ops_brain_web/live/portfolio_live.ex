defmodule OpsBrainWeb.PortfolioLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.Tenancy

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: load(socket)

  @impl true
  def handle_event("refresh", _params, socket), do: load(socket)

  defp load(socket) do
    case Tenancy.list_companies(socket.assigns.session_token) do
      {:ok, companies} ->
        {:noreply,
         socket |> assign(:empty?, companies == []) |> stream(:companies, companies, reset: true)}

      _ ->
        {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1>Ops Brain — authorized companies</h1>
      <p id="coverage-not-configured">
        Monitoring is not configured. No operational health has been measured.
      </p>
      <p>Showing up to 100 authorized companies.</p>
      <p :if={@empty?} id="no-companies">No company memberships.</p>
      <div id="companies" phx-update="stream">
        <article :for={{dom_id, company} <- @streams.companies} id={dom_id}>
          <.link navigate={~p"/companies/#{company.id}"}>{company.name}</.link>
        </article>
      </div>
      <button id="refresh" phx-click="refresh">Refresh memberships</button>
      <.link href={~p"/sign-out"} method="delete">Sign out</.link>
    </Layouts.app>
    """
  end
end
