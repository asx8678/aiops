defmodule OpsBrainWeb.DemoLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Demo, Tenancy}
  alias OpsBrain.Demo.Dataset
  @page_size 40

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(query: "", kind: "", cluster: "", namespace: "", page: 1)
     |> stream(:resources, [])}
  end

  def handle_params(_params, _url, socket),
    do: load(assign(socket, query: "", kind: "", cluster: "", namespace: "", page: 1))

  def handle_event("filter", params, socket) do
    filters =
      Map.new([:query, :kind, :cluster, :namespace], fn key ->
        value = params[Atom.to_string(key)]
        {key, if(is_binary(value), do: String.slice(value, 0, 100), else: "")}
      end)

    load(socket |> assign(filters) |> assign(:page, 1))
  end

  def handle_event("next", _, socket), do: load(assign(socket, :page, socket.assigns.page + 1))

  def handle_event("previous", _, socket),
    do: load(assign(socket, :page, max(1, socket.assigns.page - 1)))

  def handle_event("refresh", _, socket), do: load(socket)

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, company} <- Tenancy.company(scope), {:ok, snapshot} <- Demo.snapshot(scope) do
      rows = snapshot.resources

      filtered =
        Enum.filter(rows, fn row ->
          d = row["data"]

          Enum.all?([:kind, :cluster, :namespace], fn key ->
            socket.assigns[key] == "" or d[Atom.to_string(key)] == socket.assigns[key]
          end) and
            String.contains?(
              String.downcase(Jason.encode!(d)),
              String.downcase(String.trim(socket.assigns.query))
            )
        end)

      pages = max(1, ceil(length(filtered) / @page_size))
      page = min(socket.assigns.page, pages)

      visible =
        filtered
        |> Enum.drop((page - 1) * @page_size)
        |> Enum.take(@page_size)
        |> Enum.map(&Map.put(&1, :id, &1["id"]))

      choices = fn field ->
        rows |> Enum.map(& &1["data"][field]) |> Enum.uniq() |> Enum.sort()
      end

      form =
        to_form(
          Map.new(
            [:query, :kind, :cluster, :namespace],
            &{Atom.to_string(&1), socket.assigns[&1]}
          )
        )

      {:noreply,
       socket
       |> assign(
         company: company,
         manifest: snapshot.manifest,
         matched: length(filtered),
         total: length(rows),
         page: page,
         pages: pages,
         kinds: choices.("kind"),
         clusters: choices.("cluster"),
         namespaces: choices.("namespace"),
         filter_form: form,
         scenarios: Dataset.scenarios(),
         source_fixtures: Dataset.sources()
       )
       |> stream(:resources, visible, reset: true)}
    else
      {:error, :not_found} -> {:noreply, redirect(socket, to: ~p"/companies/#{scope.company_id}")}
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:demo}
      title="Demo explorer"
      company={@company.name}
    >
      <div class="demo-heading">
        <UI.page_header
          eyebrow="OFFLINE SANDBOX"
          title="A connected picture of your systems"
          description="Explore a mid-size retail platform, then follow evidence across delivery, Kubernetes, metrics, logs, and databases."
        >
          <:actions>
            <button id="refresh-demo" class="btn" phx-click="refresh"><.icon name="hero-arrow-path" />Refresh snapshot</button><.link
              class="btn btn-primary"
              navigate={~p"/companies/#{@company.id}/investigations"}
            >Explore investigations <.icon name="hero-arrow-right" /></.link>
          </:actions>
        </UI.page_header>
      </div>
      <%= if @manifest do %>
        <div class="stats-grid" id="demo-stats">
          <UI.stat
            label="Simulated clusters"
            value={@manifest["counts"]["Cluster"]}
            hint="Production + staging fixtures"
            icon="hero-server-stack"
          />
          <UI.stat
            label="Namespace identities"
            value={@manifest["counts"]["Namespace"]}
            hint="Across both simulated clusters"
            icon="hero-squares-2x2"
          />
          <UI.stat
            label="Pod snapshots"
            value={@manifest["counts"]["Pod"]}
            hint="Including database replicas"
            icon="hero-square-3-stack-3d"
          />
          <UI.stat
            label="Linked investigations"
            value={@manifest["finding_count"]}
            hint="Hypotheses, not causal proof"
            icon="hero-magnifying-glass"
          />
        </div>
        <section class="panel" id="demo-tour">
          <div class="panel-heading">
            <div>
              <h2>Start with the checkout incident</h2><p>
                Five observations. Four source identities. One hypothesis to investigate.
              </p>
            </div><UI.badge value="critical" label="Scripted incident" />
          </div>
          <div class="panel-body">
            <p>
              A rollout increases the connection pool, pods lose readiness, HTTP latency spikes, logs show SQLSTATE 53300, and database metrics show 492 of 500 connections used. Is the rollout responsible? Staging provides counterevidence.
            </p>
            <div class="demo-flow" aria-label="Synthetic evidence chain">
              <span>Build / YAML</span><b>→</b><span>Kubernetes</span><b>→</b><span>Metrics</span><b>→</b><span>Logs</span><b>→</b><span>Database</span>
            </div>
            <.link class="text-link" navigate={~p"/companies/#{@company.id}/investigations"}>Open Investigations, then choose Evidence on the checkout finding
            <.icon name="hero-arrow-right" /></.link>
            <details class="demo-scenarios">
              <summary>All five demo scenarios</summary><ul>
                <li :for={scenario <- @scenarios}>
                  <strong>{scenario.title}</strong> — {scenario.hypothesis}
                </li>
              </ul>
            </details>
          </div>
        </section>
        <section class="panel" id="demo-connections">
          <div class="panel-heading">
            <div>
              <h2>Simulated connections</h2><p>
                Offline snapshots only. No API servers, exporters, databases, or log backends are contacted.
              </p>
            </div>
          </div>
          <div class="demo-source-grid">
            <article :for={source <- @source_fixtures}>
              <.icon name="hero-signal" /><strong>{source.cluster}</strong><small>{UI.humanize(
                source.kind
              )}</small><UI.badge
                value={if(source.key == "nw-eu-staging-loki", do: "warning", else: "unknown")}
                label={
                  if(source.key == "nw-eu-staging-loki",
                    do: "Simulated timeout",
                    else: "Simulated snapshot"
                  )
                }
              />
            </article>
          </div>
        </section>
        <section class="panel" id="demo-inventory">
          <div class="panel-heading">
            <div>
              <h2>Resource inventory</h2><p>
                {@total} synthetic objects · snapshot {@manifest["snapshot_at"]} · retained for 30 days
              </p>
            </div><span class="section-count">{@matched} matching</span>
          </div>
          <.form
            for={@filter_form}
            id="demo-filter"
            phx-change="filter"
            phx-submit="filter"
            class="demo-filters"
          >
            <.input
              field={@filter_form[:query]}
              type="search"
              label="Search resources"
              placeholder="checkout, postgres, OOMKilled…"
              phx-debounce="250"
            />
            <.input
              field={@filter_form[:cluster]}
              type="select"
              label="Cluster"
              options={[{"All clusters", ""} | @clusters]}
            />
            <.input
              field={@filter_form[:namespace]}
              type="select"
              label="Namespace"
              options={[{"All namespaces", ""} | @namespaces]}
            />
            <.input
              field={@filter_form[:kind]}
              type="select"
              label="Resource kind"
              options={[{"All kinds", ""} | @kinds]}
            />
          </.form>
          <div class="table-scroll">
            <table class="data-table">
              <thead>
                <tr>
                  <th scope="col">Resource / kind</th><th scope="col">Cluster / namespace</th><th scope="col">
                    Simulated state
                  </th><th scope="col">Snapshot details</th>
                </tr>
              </thead>
              <tbody id="demo-resources" phx-update="stream">
                <tr :for={{dom_id, r} <- @streams.resources} id={dom_id}>
                  <td><strong>{r["data"]["name"]}</strong><small>{r["data"]["kind"]}</small></td>
                  <td>{r["data"]["cluster"]}<small>{r["data"]["namespace"]}</small></td>
                  <td><UI.badge value={tone(r["data"]["status"])} label={r["data"]["status"]} /></td>
                  <td>
                    <details>
                      <summary>Inspect JSON</summary><pre>{Jason.encode!(r["data"], pretty: true)}</pre>
                    </details>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@matched == 0} id="demo-empty" class="compact-empty">
            No matching resources. Try another namespace or clear the search.
          </p>
          <div class="demo-pagination">
            <span id="demo-page" aria-live="polite">Page {@page} of {@pages} · {@matched} matching · 40 per page</span><div>
              <button id="demo-previous" class="btn" phx-click="previous" disabled={@page == 1}>Previous</button><button
                id="demo-next"
                class="btn"
                phx-click="next"
                disabled={@page == @pages}
              >Next</button>
            </div>
          </div>
        </section>
      <% else %>
        <UI.empty
          title="Demo snapshot unavailable"
          description="The demo evidence is missing or expired. Ask the local administrator to reseed with mix ops_brain.demo --operator NAME --confirm --reset."
        />
      <% end %>
    </Layouts.app>
    """
  end

  defp tone(status)
       when status in ~w(OOMKilled ImagePullBackOff ReadinessFailed Degraded DiskPressure Warning),
       do: "warning"

  defp tone(_), do: "unknown"
end
