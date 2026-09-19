defmodule OpsBrainWeb.CompanyLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.Tenancy

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :source_id, params["id"])
    load(socket)
  end

  @impl true
  def handle_event("refresh", _params, socket), do: load(socket)

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, data} <- Tenancy.overview(scope),
         {:ok, selected} <- selected_source(scope, socket.assigns.source_id) do
      {:noreply,
       socket
       |> assign(:company, data.company)
       |> assign(:selected_source, selected)
       |> assign(:environments, data.environments)
       |> assign(:empty_sources?, data.sources == [])
       |> stream(:sources, data.sources, reset: true)}
    else
      {:error, :not_found} -> {:noreply, redirect(socket, to: ~p"/companies/#{scope.company_id}")}
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp selected_source(_, nil), do: {:ok, nil}
  defp selected_source(scope, id), do: Tenancy.get_source(scope, id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.link navigate={~p"/"}>Companies</.link>
      <h1>{@company.name}</h1>
      <.link navigate={~p"/companies/#{@company.id}/pipelines"}>Operations: pipelines, notices, services and sources</.link>
      <p id="company-coverage">
        Overall condition: unknown. Coverage is limited to explicitly configured checks; inspect Services and Sources for stored results.
      </p>
      <h2>Configured environment identities</h2>
      <ul id="environments">
        <li :for={environment <- @environments} id={"environment-#{environment.id}"}>
          {environment.name} — identity only; runtime health requires explicitly mapped service evidence
        </li>
      </ul>
      <h2>Source identities</h2>
      <p>
        Showing up to 100 sources. Identity metadata only; consult Source health for configured collection and freshness. Classic release pipelines are unsupported.
      </p>
      <p :if={@empty_sources?} id="no-sources">No configured source identities.</p>
      <div id="sources" phx-update="stream">
        <article :for={{dom_id, source} <- @streams.sources} id={dom_id}>
          <.link patch={~p"/companies/#{@company.id}/sources/#{source.id}"}>{source.name}</.link>
        </article>
      </div>
      <section :if={@selected_source} id="selected-source">
        <h2>{@selected_source.name}</h2>
        <p>
          Source type: {@selected_source.kind}. Endpoint, credential reference and collection budgets require separately approved deployment configuration.
        </p>
        <.link navigate={~p"/companies/#{@company.id}/source-health"}>View actual source coverage</.link>
        <p :if={is_nil(@selected_source.environment_id)}>
          Environment mapping: unresolved / CI-only, not production.
        </p>
      </section>
      <button id="refresh" phx-click="refresh">Refresh authorized data</button>
    </Layouts.app>
    """
  end
end
