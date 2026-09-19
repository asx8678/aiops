defmodule OpsBrainWeb.OperationsLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Tenancy, Store, Services, Issues}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)
    {:ok, assign(socket, :selected_evidence, [])}
  end

  def handle_info(:refresh, socket) do
    # Reauthorize every push; no global tenant PubSub subscription is used.
    Process.send_after(self(), :refresh, 10_000)
    load(socket)
  end

  def handle_params(_params, _url, socket), do: load(socket)
  def handle_event("refresh", _, socket), do: load(socket)

  def handle_event("snooze", %{"id" => id}, socket) do
    Issues.snooze(socket.assigns.current_scope, id, DateTime.add(Store.now(), 3600))
    load(socket)
  end

  def handle_event("review", %{"id" => id, "status" => status}, socket) do
    Issues.review(socket.assigns.current_scope, id, status)
    load(socket)
  end

  def handle_event("evidence", %{"id" => id}, socket) do
    case Issues.evidence(socket.assigns.current_scope, id) do
      {:ok, items} -> {:noreply, assign(socket, :selected_evidence, items)}
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, groups} <- Issues.list(scope),
         {:ok, sources} <- Services.sources(scope),
         {:ok, services} <- Services.overview(scope),
         {:ok, windows} <- Services.windows(scope),
         {:ok, runs} <-
           Tenancy.with_scope(scope, fn ->
             Store.rows(
               "SELECT id::text,source_id::text,run_id,definition_id,status,result,finish_at,received_at,revision FROM pipeline_runs ORDER BY received_at DESC LIMIT 100"
             )
           end) do
      {:noreply,
       socket
       |> assign(:runs, runs)
       |> assign(:sources, sources)
       |> assign(:services, services)
       |> assign(:windows, windows)
       |> stream(:groups, Enum.map(groups, &Map.put(&1, :id, &1["id"])), reset: true)}
    else
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1>Operations — {@live_action}</h1>
      <nav>
        <.link navigate={~p"/companies/#{@current_scope.company_id}"}>Overview</.link>
        <.link navigate={~p"/companies/#{@current_scope.company_id}/pipelines"}>Pipelines</.link>
        <.link navigate={~p"/companies/#{@current_scope.company_id}/services"}>Services</.link>
        <.link navigate={~p"/companies/#{@current_scope.company_id}/investigations"}>Investigations</.link>
        <.link navigate={~p"/companies/#{@current_scope.company_id}/capacity"}>Capacity</.link>
        <.link navigate={~p"/companies/#{@current_scope.company_id}/source-health"}>Sources</.link>
      </nav>
      <p id="coverage-disclaimer">
        Configured scopes only. Missing data is unknown. CI failure is not production downtime. Views are capped at 100 retained records, not total history.
      </p>
      <section :if={@live_action == :pipelines} id="pipelines">
        <h2>Distinct run projections — Build/YAML only</h2>
        <p>Classic releases unsupported. No full-history failure percentage is asserted.</p>
        <p :if={@runs == []}>No run observations.</p>
        <article :for={r <- @runs} id={"run-#{r["id"]}"}>
          Run {r["run_id"]} / definition {r["definition_id"]}: {r["status"]} / {r["result"]}; revision {r[
            "revision"
          ]}. Target unresolved / CI-only.
        </article>
      </section>
      <section :if={@live_action in [:services, :capacity]} id="services">
        <h2>Explicit service targets</h2>
        <p :if={@services == []}>No mapped service targets. Forecast eligibility unknown.</p>
        <article :for={s <- @services}>
          {s["service_key"]} / {s["environment"]} / {s["target"]}
        </article>
        <h2>Stored observations and evaluations</h2>
        <article :for={w <- @windows} id={"window-#{w["id"]}"}>
          {w["kind"]}: {w["profile"]} {w["window_start"]} – {w["window_end"]} / revision {w[
            "revision"
          ]}
          <pre>{Jason.encode!(w["data"],pretty: true)}</pre>
        </article>
      </section>
      <section :if={@live_action == :sources} id="source-health">
        <h2>Source coverage and query use</h2>
        <article :for={s <- @sources} id={"health-#{s["id"]}"}>
          {s["name"]}: {s["freshness"]}; {s["error"]}; requests {s["requests"] || 0}, bytes received {s[
            "bytes"
          ] || 0}. Last success: {s["last_success_at"] || "never"}.
        </article>
      </section>
      <h2>Local notices — no upstream acknowledgment or silence</h2>
      <div id="issue-groups" phx-update="stream">
        <article :for={{dom_id, g} <- @streams.groups} id={dom_id}>
          <h3>{g["severity"]}: {g["data"]["template"]}</h3>
          <p>
            {g["status"]}; first {g["first_seen"]}; last {g["last_seen"]}; {g["distinct_runs"]} distinct runs; {g[
              "occurrences"
            ]} occurrences ({g["data"]["count_basis"]}).
          </p>
          <p>{g["data"]["reason"]}. Missing: {g["data"]["missing"]}</p>
          <button phx-click="evidence" phx-value-id={g["id"]}>Evidence</button>
          <button phx-click="snooze" phx-value-id={g["id"]}>Snooze locally for 1 hour</button>
          <button phx-click="review" phx-value-id={g["id"]} phx-value-status="locally_acknowledged">Acknowledge locally</button>
          <button phx-click="review" phx-value-id={g["id"]} phx-value-status="closed_by_reviewer">Close by review</button>
        </article>
      </div>
      <section id="evidence">
        <pre :for={e <- @selected_evidence}>{Jason.encode!(e,pretty: true)}</pre>
      </section>
      <button id="refresh-operations" phx-click="refresh">Refresh authorized data</button>
    </Layouts.app>
    """
  end
end
