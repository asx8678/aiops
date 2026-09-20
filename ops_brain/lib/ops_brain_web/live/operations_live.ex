defmodule OpsBrainWeb.OperationsLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Tenancy, Store, Services, Issues, Notifications}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    socket =
      assign(socket,
        groups_count: 0,
        summary: [],
        query: "",
        environment: "",
        filter_form: to_form(%{"query" => "", "environment" => ""}),
        refreshed_at: nil,
        runs: [],
        sources: [],
        services: [],
        windows: [],
        selected_evidence: nil,
        evidence_company: nil
      )

    {:ok, stream(socket, :groups, [])}
  end

  def handle_info(:refresh, socket) do
    # Reauthorize every push; no global tenant PubSub subscription is used.
    Process.send_after(self(), :refresh, 10_000)
    load(socket)
  end

  def handle_params(params, _url, socket) do
    environment =
      if socket.assigns.live_action in [:services, :capacity],
        do: environment(params["environment"]),
        else: ""

    # R22: never reuse tenant-specific evidence across a company switch.
    socket =
      if socket.assigns.evidence_company == socket.assigns.current_scope.company_id do
        socket
      else
        assign(socket,
          selected_evidence: nil,
          evidence_company: socket.assigns.current_scope.company_id
        )
      end

    with {:ok, company} <- Tenancy.company(socket.assigns.current_scope) do
      load(
        assign(socket,
          company_name: company.name,
          query: "",
          environment: environment,
          filter_form: to_form(%{"query" => "", "environment" => environment})
        )
      )
    else
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def handle_event("refresh", _, socket), do: load(socket)

  def handle_event("filter", %{"query" => query} = params, socket) when is_binary(query) do
    query = String.slice(query, 0, 100)

    environment =
      if socket.assigns.live_action in [:services, :capacity],
        do: environment(Map.get(params, "environment", socket.assigns.environment)),
        else: ""

    load(
      assign(socket,
        query: query,
        environment: environment,
        filter_form: to_form(%{"query" => query, "environment" => environment})
      )
    )
  end

  def handle_event("close-evidence", _, socket),
    do: {:noreply, assign(socket, :selected_evidence, nil)}

  def handle_event("snooze", %{"id" => id}, socket) do
    case Issues.snooze(socket.assigns.current_scope, id, DateTime.add(Store.now(), 3600)) do
      {:ok, row} when is_map(row) -> load(socket)
      {:error, :unauthorized} -> {:noreply, redirect(socket, to: ~p"/sign-in")}
      _ -> {:noreply, put_flash(socket, :error, "Snooze could not be saved.")}
    end
  end

  def handle_event("assign", %{"id" => id, "owner" => owner}, socket) do
    result =
      if String.trim(owner) == "",
        do: Issues.unassign(socket.assigns.current_scope, id),
        else: Issues.assign(socket.assigns.current_scope, id, owner)

    case result do
      {:ok, row} when is_map(row) -> load(socket)
      {:error, :unauthorized} -> {:noreply, redirect(socket, to: ~p"/sign-in")}
      _ -> {:noreply, put_flash(socket, :error, "Assignment could not be saved.")}
    end
  end

  def handle_event("review", %{"id" => id, "status" => status}, socket) do
    case Issues.review(socket.assigns.current_scope, id, status) do
      {:ok, %{}} ->
        load(socket)

      {:error, :unauthorized} ->
        {:noreply, redirect(socket, to: ~p"/sign-in")}

      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, "Finding unavailable. Refresh and try again.")}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Review could not be saved. Refresh and check the current state."
         )}
    end
  end

  def handle_event("evidence", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, items} <- Issues.evidence(scope, id),
         {:ok, revisions} <- Issues.revisions(scope, id),
         {:ok, notifications} <- Notifications.status(scope, id) do
      {:noreply,
       assign(socket, :selected_evidence, %{
         group_id: id,
         items: items,
         revisions: revisions,
         notifications: notifications
       })}
    else
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp environment(value) when value in ["dev", "staging", "prod"], do: value
  defp environment(_), do: ""

  # Filter the bounded authorized set by explicit service identity, not name inference.
  defp environment_records(services, windows, ""), do: {services, windows}

  defp environment_records(services, windows, environment) do
    services = Enum.filter(services, &(&1["environment"] == environment))
    ids = MapSet.new(services, & &1["id"])
    {services, Enum.filter(windows, &MapSet.member?(ids, &1["service_id"]))}
  end

  # R21: each route loads only the data it renders instead of every dataset.
  defp load(socket) do
    scope = socket.assigns.current_scope
    # Never keep an expired evidence snapshot across a refresh or navigation.
    socket = assign(socket, selected_evidence: nil, refreshed_at: Store.now())

    case socket.assigns.live_action do
      :investigations ->
        case Issues.list(scope) do
          {:ok, groups} ->
            socket = assign(socket, :summary, UI.summaries(:investigations, groups))
            groups = filter_records(groups, socket.assigns.query)

            {:noreply,
             socket
             |> assign(:groups_count, length(groups))
             |> stream(
               :groups,
               Enum.map(groups, fn group ->
                 group
                 |> Map.put(:id, group["id"])
                 |> Map.put(:owner_form, to_form(%{"owner" => group["owner"] || ""}))
               end),
               reset: true
             )}

          _ ->
            {:noreply, redirect(socket, to: ~p"/sign-in")}
        end

      action when action in [:services, :capacity] ->
        with {:ok, services} <- Services.overview(scope),
             {:ok, windows} <- Services.windows(scope) do
          {services, windows} = environment_records(services, windows, socket.assigns.environment)

          {:noreply,
           socket
           |> assign(:summary, UI.summaries(action, {services, windows}))
           |> assign(:services, filter_records(services, socket.assigns.query))
           |> assign(:windows, filter_records(windows, socket.assigns.query))}
        else
          _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
        end

      :sources ->
        with {:ok, sources} <- Services.sources(scope) do
          {:noreply,
           assign(socket,
             summary: UI.summaries(:sources, sources),
             sources: filter_records(sources, socket.assigns.query)
           )}
        else
          _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
        end

      :pipelines ->
        with {:ok, runs} <- pipeline_runs(scope) do
          {:noreply,
           assign(socket,
             summary: UI.summaries(:pipelines, runs),
             runs: filter_records(runs, socket.assigns.query)
           )}
        else
          _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp pipeline_runs(scope) do
    Tenancy.with_scope(scope, fn ->
      Store.rows(
        """
        WITH runs AS MATERIALIZED (
          SELECT * FROM pipeline_runs ORDER BY received_at DESC,id DESC LIMIT 100
        )
        SELECT r.id::text,r.source_id::text,r.run_id,r.definition_id,r.status,r.result,r.finish_at,r.received_at,r.revision,
          COALESCE(m.targets,'[]'::jsonb) AS targets
        FROM runs r LEFT JOIN LATERAL (
          SELECT jsonb_agg(t.data) AS targets FROM (
            SELECT jsonb_build_object('service',s.service_key,'target',s.target,'environment',env.name,
              'result',e.data->>'reported_result','attempt',e.data->>'attempt') AS data
            FROM evidence_items e
            JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
            JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
            WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
              AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $1
            ORDER BY e.received_at DESC,e.id DESC LIMIT 20
          ) t
        ) m ON true ORDER BY r.received_at DESC,r.id DESC
        """,
        [Store.now()]
      )
    end)
  end

  # Search only bounded, already-authorized records and presentation fields.
  defp filter_records(rows, query) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(rows, fn row ->
      fields =
        Map.take(
          row,
          ~w(run_id definition_id status result service_key environment target kind profile name freshness severity owner)
        )

      data = Map.take(row["data"] || %{}, ~w(template condition scope))
      String.contains?(String.downcase(Jason.encode!([fields, data])), query)
    end)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={@live_action}
      company={@company_name}
      title={UI.title(@live_action)}
      live_refresh={true}
    >
      <UI.page_header
        eyebrow="OPERATIONS WORKSPACE"
        title={UI.title(@live_action)}
        description={UI.description(@live_action)}
      >
        <:actions>
          <button
            class="btn"
            id="refresh-operations"
            phx-click="refresh"
            phx-disable-with="Refreshing…"
          ><.icon name="hero-arrow-path" />Refresh view</button>
        </:actions>
      </UI.page_header>
      <div class="stats-grid" id="operations-stats">
        <UI.stat
          :for={{label, value, hint, icon} <- @summary}
          label={label}
          value={value}
          hint={hint}
          icon={icon}
        />
      </div>
      <div id="coverage-disclaimer" class="notice">
        <.icon name="hero-information-circle" /><p>
          <strong>Configured scopes only.</strong>
          Missing data is unknown. CI failure is not production downtime. Each dataset is capped at 100 retained records, not total history.
        </p>
      </div>
      <p :if={@live_action in [:services, :capacity]} id="environment-filter-note" class="panel-note">
        {if @environment == "", do: "All environments", else: "Environment: #{@environment}"} · scoped within the loaded set, before text search. Unmapped windows appear only under All environments.
      </p>
      <div class="toolbar">
        <.form
          for={@filter_form}
          id="operations-filter"
          phx-change="filter"
          phx-submit="filter"
          class="search-form"
        >
          <div class="search-field">
            <.icon name="hero-magnifying-glass" /><.input
              field={@filter_form[:query]}
              id="operations-query"
              type="search"
              aria-label="Search retained records in this view"
              placeholder={"Search #{String.downcase(UI.title(@live_action))}…"}
              phx-debounce="200"
              maxlength="100"
            />
          </div>
          <.input
            :if={@live_action in [:services, :capacity]}
            field={@filter_form[:environment]}
            id="operations-environment"
            type="select"
            aria-label="Filter by environment"
            options={[
              {"All environments", ""},
              {"Development", "dev"},
              {"Staging", "staging"},
              {"Production", "prod"}
            ]}
          />
        </.form><p>View updated <time id="view-updated">{UI.timestamp(@refreshed_at)}</time></p>
      </div>

      <section :if={@live_action == :pipelines} id="pipelines" class="panel">
        <div class="panel-heading">
          <div>
            <h2>Pipeline runs</h2><p>Build / YAML · most recently received first</p>
          </div><UI.badge label={"#{length(@runs)} shown"} />
        </div>
        <UI.empty
          :if={@runs == []}
          icon="hero-command-line"
          title={if @query == "", do: "No run observations yet", else: "No matching runs"}
          description={
            if @query == "",
              do:
                "Approved Build/YAML collection will populate this view. A passing pipeline is not proof of runtime health.",
              else:
                "Try a run ID, definition, status, or result. Search covers only the retained records loaded in this view."
          }
        >
          <:action>
            <.link class="btn" navigate={~p"/companies/#{@current_scope.company_id}/source-health"}>Inspect source coverage
            <.icon name="hero-arrow-right" /></.link>
          </:action>
        </UI.empty>
        <div :if={@runs != []} class="table-scroll">
          <table class="data-table">
            <caption class="table-caption">
              Reported deployment, not runtime-confirmed. At most 20 retained mappings per run.
            </caption><thead>
              <tr>
                <th scope="col">Run / definition</th><th scope="col">Status</th><th scope="col">
                  Result
                </th><th scope="col">Deployment evidence</th><th scope="col">Received</th>
              </tr>
            </thead><tbody>
              <tr :for={r <- @runs} id={"run-#{r["id"]}"}>
                <td>
                  <strong class="mono">#{r["run_id"]}</strong><small>Definition {r["definition_id"]} · rev {r[
                    "revision"
                  ]}</small>
                </td><td><UI.badge value={r["status"]} /></td><td>
                  <UI.badge value={r["result"]} />
                </td><td>
                  <p :if={r["targets"] == []} class="target">
                    Target unresolved — no retained explicit deployment evidence. CI-only, not runtime health.
                  </p><p :for={t <- r["targets"]} class="mapped-target">
                    <strong>{t["service"]}</strong>
                    / {t["environment"]} / {t["target"]}<br />Reported {t["result"]} · attempt {t[
                      "attempt"
                    ]}
                  </p>
                </td><td class="time-cell">
                  {UI.timestamp(r["received_at"])}<small>Finished: {UI.timestamp(r["finish_at"])}</small>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="panel-note">
          Classic releases are unsupported. No full-history failure percentage is asserted.
        </div>
      </section>

      <div :if={@live_action in [:services, :capacity]} id="services">
        <div :if={@live_action == :capacity} class="notice notice-warning" id="capacity-prerequisites">
          <.icon name="hero-chart-bar" /><p>
            <strong>Forecasts need evidence.</strong>
            Capacity forecasts appear only when a reviewed policy, explicit service mapping, and sufficient fresh history exist. Unknown is not healthy.
          </p>
        </div>
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h2>Explicit service targets</h2><p>
                Identity mappings, not inferred from pipeline names
              </p>
            </div><UI.badge label={"#{length(@services)} shown"} />
          </div>
          <UI.empty
            :if={@services == []}
            icon="hero-server-stack"
            title={
              if @query == "", do: "No mapped service targets", else: "No matching service targets"
            }
            description={
              if @query == "",
                do:
                  "Map a service to an approved source, environment, and runtime target before evaluating its condition. Forecast eligibility is unknown.",
                else:
                  "Try a service name, environment, or target. Clear the search to restore this view."
            }
          />
          <div :if={@services != []} class="table-scroll">
            <table class="data-table">
              <thead>
                <tr>
                  <th scope="col">Service</th><th scope="col">Environment</th><th scope="col">
                    Runtime target
                  </th><th scope="col">Mapping</th>
                </tr>
              </thead><tbody>
                <tr :for={s <- @services} id={"service-#{s["id"]}"}>
                  <td><strong>{s["service_key"]}</strong></td><td>
                    <UI.badge value={s["environment"]} />
                  </td><td class="mono">{s["target"]}</td><td>
                    <span class="muted tiny">Explicit identity</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h2>Observations &amp; evaluations</h2><p>Stored results · newest window first</p>
            </div><UI.badge label={"#{length(@windows)} shown"} />
          </div>
          <UI.empty
            :if={@windows == []}
            icon="hero-chart-bar"
            title={
              if @query == "", do: "No retained observation windows", else: "No matching observations"
            }
            description="Conditions appear here when approved collection produces retained evidence. No data does not mean normal operation."
          />
          <article :for={w <- @windows} id={"window-#{w["id"]}"} class="observation">
            <div class="observation-head">
              <div>
                <h3>{UI.humanize(w["kind"])} <span class="muted">/ {w["profile"]}</span></h3><p class="observation-meta">
                  {UI.timestamp(w["window_start"])} – {UI.timestamp(w["window_end"])} · revision {w[
                    "revision"
                  ]}
                </p>
              </div><UI.badge value={w["data"]["condition"]} />
            </div><p :if={w["data"]["missing"]} class="missing-data">
              Missing prerequisite: {w["data"]["missing"]}
            </p><details>
              <summary>Inspect diagnostic JSON</summary><pre>{Jason.encode!(w["data"], pretty: true)}</pre>
            </details>
          </article>
        </section>
      </div>

      <section :if={@live_action == :sources} id="source-health" class="panel">
        <div class="panel-heading">
          <div>
            <h2>Source coverage</h2><p>Freshness, collection errors, and recorded query use</p>
          </div><UI.badge label={"#{length(@sources)} shown"} />
        </div>
        <UI.empty
          :if={@sources == []}
          title={
            if @query == "", do: "No configured sources for this company", else: "No matching sources"
          }
          description={
            if @query == "",
              do:
                "Start with one approved source. Your administrator defines endpoints, read permissions, secret references, and collection budgets.",
              else:
                "Try a source name, type, or freshness state. Search is limited to this company’s loaded records."
          }
        >
          <:action>
            <.link class="btn" navigate={~p"/companies/#{@current_scope.company_id}"}>View source setup guidance
            <.icon name="hero-arrow-right" /></.link>
          </:action>
        </UI.empty>
        <div :if={@sources != []} class="table-scroll">
          <table class="data-table">
            <thead>
              <tr>
                <th scope="col">Source</th><th scope="col">Coverage / freshness</th><th scope="col">
                  Query use
                </th><th scope="col">Last success</th>
              </tr>
            </thead><tbody>
              <tr :for={s <- @sources} id={"health-#{s["id"]}"}>
                <td><strong>{s["name"]}</strong><small>{s["kind"]}</small></td><td>
                  <UI.badge value={s["freshness"]} /><small>{s["error"] || "No recorded error"}</small>
                </td><td>
                  <strong>{s["requests"] || 0}</strong>
                  requests<small>{s["bytes"] || 0} bytes received</small>
                </td><td class="time-cell">{UI.timestamp(s["last_success_at"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="panel-note">
          Source identity alone does not enable collection. A successful read does not establish complete coverage.
        </div>
      </section>

      <section :if={@live_action == :investigations} id="investigations">
        <div class="section-heading">
          <div>
            <h2>Findings &amp; local review</h2><p>
              No upstream acknowledgment, silence, or remediation.
            </p>
          </div><UI.badge label={"#{@groups_count} shown"} />
        </div>
        <div :if={@groups_count == 0} class="panel">
          <UI.empty
            icon="hero-magnifying-glass"
            title={if @query == "", do: "No retained findings", else: "No matching findings"}
            description={
              if @query == "",
                do:
                  "Findings appear when configured detectors identify evidence worth reviewing. An empty queue is not a statement about operational health.",
                else:
                  "Search by summary, severity, status, owner, or scope. Clear the search to show all loaded findings."
            }
          />
        </div>
        <div id="issue-groups" phx-update="stream" class="record-list">
          <article :for={{dom_id, g} <- @streams.groups} id={dom_id} class="issue-card">
            <div class="issue-main">
              <div class="issue-topline">
                <UI.badge value={g["severity"]} /><UI.badge value={g["status"]} label={g["status"]} /><span class="revision">Revision {g[
                  "revision"
                ]}</span>
              </div><h3>{g["data"]["template"]}</h3><div class="issue-meta">
                <span>{g["distinct_runs"]} distinct runs</span><span>{g["occurrences"]} occurrences · {g[
                  "data"
                ]["count_basis"]}</span><span>Owner: {g["owner"] || "unassigned"}</span>
              </div><div class="issue-meta">
                <span>First: {UI.timestamp(g["first_seen"])}</span><span>Last: {UI.timestamp(
                  g["last_seen"]
                )}</span><span>Snoozed until: {if g["snoozed_until"],
                  do: UI.timestamp(g["snoozed_until"]),
                  else: "not snoozed"}</span>
              </div><div class="issue-explanation">
                <strong>Scope: {g["data"]["scope"] || "unresolved"}.</strong> {g["data"]["reason"]}<br />Missing: {g[
                  "data"
                ]["missing"]}
              </div><.form
                for={g.owner_form}
                id={"assign-#{g["id"]}"}
                phx-submit="assign"
                phx-value-id={g["id"]}
                class="owner-form"
              >
                <.input
                  field={g.owner_form[:owner]}
                  id={"owner-#{g["id"]}"}
                  label="Local owner (blank to unassign)"
                  maxlength="100"
                  placeholder="Assign an owner…"
                /><button class="btn" type="submit" phx-disable-with="Saving…">Save owner</button>
              </.form>
            </div><div class="issue-actions">
              <button class="btn btn-primary" phx-click="evidence" phx-value-id={g["id"]}><.icon name="hero-magnifying-glass" />Inspect evidence</button><button
                class="btn"
                phx-click="snooze"
                phx-value-id={g["id"]}
                phx-disable-with="Saving…"
              ><.icon name="hero-clock" />Snooze locally · 1h</button><button
                class="btn"
                phx-click="review"
                phx-value-id={g["id"]}
                phx-value-status="locally_acknowledged"
                phx-disable-with="Saving…"
              >Acknowledge locally</button><button
                class="btn btn-quiet"
                phx-click="review"
                phx-value-id={g["id"]}
                phx-value-status="closed_by_reviewer"
                phx-disable-with="Saving…"
              >Close by review</button>
            </div>
          </article>
        </div>
      </section>

      <section
        :if={@selected_evidence}
        id="evidence"
        class="panel evidence-panel"
        aria-labelledby="evidence-title"
      >
        <div class="panel-heading">
          <div>
            <h2 id="evidence-title" tabindex="-1" phx-mounted={JS.focus()}>Evidence workspace</h2><p class="mono">
              Finding {@selected_evidence.group_id}
            </p>
          </div><button class="btn" id="close-evidence" phx-click="close-evidence"><.icon name="hero-x-mark" />Close</button>
        </div><div class="panel-body">
          <p class="muted tiny">
            Up to 20 occurrence samples, 5 correlation/recovery records, 50 revisions and 20 local notifications. Counts are not full-history totals. Evidence closes on refresh to avoid stale snapshots.
          </p><h4>Local notification state</h4><p
            :if={@selected_evidence.notifications == []}
            class="muted tiny"
          >
            No local notification records.
          </p><article
            :for={n <- @selected_evidence.notifications}
            id={"notice-#{n["id"]}"}
            class="notice-row"
          >
            <div>
              <strong>{n["destination"]}</strong><small>{n["attempts"]} attempts · next {UI.timestamp(
                n["next_at"]
              )}</small>
            </div><UI.badge value={n["status"]} label={n["status"]} />
          </article><p class="muted tiny">Ambiguous sends are not retried automatically.</p><h4>
            Evidence revisions
          </h4><p :if={@selected_evidence.revisions == []} class="muted tiny">
            No revision history retained.
          </p><div :if={@selected_evidence.revisions != []} class="table-scroll">
            <table id="evidence-revisions" class="data-table">
              <thead>
                <tr>
                  <th scope="col">Revision</th><th scope="col">Kind / reason</th><th scope="col">
                    Version
                  </th><th scope="col">Occurred / received</th><th scope="col">Availability</th>
                </tr>
              </thead><tbody>
                <tr :for={e <- @selected_evidence.revisions}>
                  <td>{e["revision"]}</td><td>{e["kind"]}<small>{e["reason"]}</small></td><td>
                    {if e["current"], do: "current", else: "historical"}
                  </td><td>
                    {UI.timestamp(e["occurred_at"])}<small>{UI.timestamp(e["received_at"])}</small>
                  </td><td>{e["data"]["status"] || "retained"}</td>
                </tr>
              </tbody>
            </table>
          </div><h4>Retained evidence &amp; investigation candidates</h4><p
            :if={@selected_evidence.items == []}
            class="muted tiny"
          >
            No retained evidence items.
          </p><article :for={e <- @selected_evidence.items} class="evidence-item">
            <h5>{UI.humanize(e["kind"])} <span class="muted mono">{e["id"]}</span></h5><p>
              Occurred {UI.timestamp(e["occurred_at"])} · received {UI.timestamp(e["received_at"])} · expires {UI.timestamp(
                e["expires_at"]
              )}
            </p><p :if={e["data"]["summary"]} class="evidence-summary">{e["data"]["summary"]}</p>
            <ol
              :if={e["data"]["synthetic"] == true && is_list(e["data"]["timeline"])}
              class="demo-timeline"
            >
              <li :for={step <- e["data"]["timeline"]}>
                <small>{step["at"]} · {step["source"]}</small><strong>{step["summary"]}</strong><span class="mono">Evidence {step[
                  "evidence_id"
                ]}</span>
              </li>
            </ol>
            <p :if={e["data"]["status"] == "expired"} class="missing-data">
              Evidence expired; exact replay unavailable.
            </p><div
              :if={e["kind"] == "correlation" && e["data"]["result"]}
              class="investigation-candidates"
            >
              <p>Missing: {e["data"]["result"]["missing"]}</p><p :if={
                e["data"]["result"]["candidates"] == []
              }>
                No supported candidate from retained evidence.
              </p><article :for={candidate <- e["data"]["result"]["candidates"] || []}>
                <p>
                  {candidate["relation"]}. Change evidence {candidate["change_evidence_id"]}; symptom evidence {candidate[
                    "symptom_evidence_id"
                  ]}; separation {candidate["elapsed_seconds"]} seconds.
                </p><p :for={counter <- candidate["counterevidence"] || []}>
                  Counterevidence: {counter}
                </p>
              </article>
            </div><details>
              <summary>Sanitized diagnostic JSON</summary><pre>{Jason.encode!(e, pretty: true)}</pre>
            </details>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
