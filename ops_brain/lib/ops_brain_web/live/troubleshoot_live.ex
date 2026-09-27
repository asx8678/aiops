defmodule OpsBrainWeb.TroubleshootLive do
  @moduledoc "Everything known about one service in one environment, on one page."
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Insights, Services, Store, Tenancy}
  import OpsBrainWeb.CommandLive, only: [sparkline: 1, troubleshoot_path: 3]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 30_000)
    {:ok, assign(socket, info: nil, services: [], service: nil, environment: nil)}
  end

  def handle_params(params, _url, socket) do
    scope = socket.assigns.current_scope

    with {:ok, company} <- Tenancy.company(scope),
         {:ok, services} <- Services.overview(scope) do
      {service, environment} = selection(params, services)

      load(
        assign(socket,
          company_name: company.name,
          services: services,
          service: service,
          environment: environment,
          picker: to_form(%{"target" => if(service, do: "#{service}|#{environment}", else: "")})
        )
      )
    else
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    load(socket)
  end

  def handle_event("pick", %{"target" => target}, socket) do
    case String.split(target, "|") do
      [service, environment] ->
        {:noreply,
         push_patch(socket,
           to: troubleshoot_path(socket.assigns.current_scope, service, environment)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _, socket), do: load(socket)

  # Default to the first production service so the page is never empty.
  defp selection(%{"service" => s, "environment" => e}, services)
       when is_binary(s) and is_binary(e) do
    if Enum.any?(services, &(&1["service_key"] == s and &1["environment"] == e)),
      do: {s, e},
      else: selection(%{}, services)
  end

  defp selection(_, services) do
    case Enum.find(services, &(&1["environment"] == "prod")) || List.first(services) do
      nil -> {nil, nil}
      s -> {s["service_key"], s["environment"]}
    end
  end

  defp load(%{assigns: %{service: nil}} = socket), do: {:noreply, assign(socket, info: nil)}

  defp load(socket) do
    %{current_scope: scope, service: service, environment: environment} = socket.assigns

    case Insights.service(scope, service, environment) do
      {:ok, info} -> {:noreply, assign(socket, info: info, refreshed_at: Store.now())}
      {:error, :not_found} -> {:noreply, assign(socket, info: nil)}
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:troubleshoot}
      company={@company_name}
      title="Troubleshoot"
      live_refresh={true}
    >
      <UI.page_header
        eyebrow="TROUBLESHOOT"
        title={if @service, do: "#{@service} · #{@environment}", else: "Troubleshoot"}
        description="Recent changes, runtime state, metrics, storage, pipelines, findings and data coverage for one service."
      >
        <:actions>
          <.form for={@picker} id="service-picker" phx-change="pick" class="cc-picker">
            <.input
              field={@picker[:target]}
              type="select"
              aria-label="Choose service"
              options={
                for s <- Enum.sort_by(@services, &{&1["environment"] != "prod", &1["service_key"]}),
                    do:
                      {"#{s["service_key"]} · #{s["environment"]}",
                       "#{s["service_key"]}|#{s["environment"]}"}
              }
            />
          </.form>
          <button class="btn" id="refresh-troubleshoot" phx-click="refresh"><.icon name="hero-arrow-path" /></button>
        </:actions>
      </UI.page_header>

      <div :if={!@info} class="panel">
        <UI.empty
          icon="hero-server-stack"
          title="No service selected"
          description="Map a service to an environment first; then everything about it appears here."
        />
      </div>

      <div :if={@info}>
        <div class="stats-grid" id="troubleshoot-stats">
          <div class="stat-card">
            <div class="stat-label">Condition<.icon name="hero-heart" /></div>
            <div class="stat-value"><UI.badge value={@info.condition} /></div>
            <p class="mono">{@info.instance["target"]}</p>
          </div>
          <UI.stat
            label="Open findings"
            value={length(@info.findings)}
            hint="Grouped evidence for this target"
            icon="hero-magnifying-glass"
          />
          <UI.stat
            label="Unhealthy pods"
            value={Enum.count(@info.resources, &(&1["kind"] == "Pod" and &1["status"] != "Running"))}
            hint={"of #{Enum.count(@info.resources, &(&1["kind"] == "Pod"))} pods"}
            icon="hero-cube"
          />
          <div class="stat-card">
            <div class="stat-label">Last pipeline<.icon name="hero-command-line" /></div>
            <div class="stat-value">
              <UI.badge value={@info.pipeline && @info.pipeline.last_run["result"]} />
              <span :if={@info.pipeline && @info.pipeline.flaky} class="badge badge-warning">flaky</span>
            </div>
            <p>{@info.pipeline && @info.pipeline.reason}</p>
          </div>
        </div>

        <section class="panel cc-checks" id="next-checks">
          <div class="panel-heading">
            <div>
              <h2>What to check next</h2>
              <p>Derived from the signals on this page</p>
            </div>
          </div>
          <ol :if={@info.checks != []} class="panel-body">
            <li :for={c <- @info.checks}>{c}</li>
          </ol>
          <p :if={@info.checks == []} class="panel-body muted">
            No abnormal signals for this service. If users still report problems, check the data coverage below.
          </p>
        </section>

        <div class="cc-columns">
          <section class="panel" id="timeline">
            <div class="panel-heading">
              <div>
                <h2>What changed</h2>
                <p>Deploys, evidence and Kubernetes warnings, newest first</p>
              </div>
            </div>
            <p :if={@info.timeline == []} class="panel-body muted">No recorded changes.</p>
            <ol :if={@info.timeline != []} class="cc-timeline">
              <li :for={e <- @info.timeline} class={"cc-#{e.level}"}>
                <time>{UI.timestamp(e.at)}</time>
                <span class="cc-kind">{UI.humanize(e.kind)}</span>
                <p>{e.text}</p>
              </li>
            </ol>
          </section>

          <div>
            <section :if={@info.metric} class="panel" id="metrics">
              <div class="panel-heading">
                <div>
                  <h2>Metrics</h2>
                  <p>Latest observation window</p>
                </div>
              </div>
              <div class="panel-body cc-metrics">
                <div><small>CPU</small><strong>{@info.metric["cpu_percent"]}%</strong></div>
                <div><small>Memory</small><strong>{@info.metric["memory_percent"]}%</strong></div>
                <div>
                  <small>p95 latency</small><strong>{@info.metric["p95_latency_ms"]} ms</strong>
                </div>
              </div>
              <div :if={is_list(@info.metric["history"])} class="panel-body cc-spark-wide">
                <small class="muted">CPU %, last hour</small>
                <.sparkline values={Enum.map(@info.metric["history"], & &1["cpu_percent"])} max={100} />
              </div>
            </section>

            <section
              :if={@info.storage || @info.database || @info.saturation != []}
              class="panel"
              id="storage"
            >
              <div class="panel-heading">
                <div>
                  <h2>Database &amp; storage</h2>
                  <p>{(@info.storage && @info.storage.volume) || @info.database["name"]}</p>
                </div>
                <UI.badge
                  :if={@info.storage}
                  value={if @info.storage.level == "ok", do: "normal", else: @info.storage.level}
                />
              </div>
              <div :if={@info.storage} class="panel-body">
                <.sparkline
                  values={@info.storage.history}
                  max={@info.storage.size_gib}
                  level={@info.storage.level}
                />
                <p class="tiny">
                  {Insights.fmt(@info.storage.used_gib)} / {Insights.fmt_size(@info.storage.size_gib)} GiB · {Insights.fmt(
                    @info.storage.recent_rate
                  )} GiB/h now vs {Insights.fmt(@info.storage.baseline_rate)} GiB/h baseline · full in {Insights.fmt_hours(
                    @info.storage.hours_to_full
                  )}
                </p>
                <p :for={r <- @info.storage.reasons} class="muted tiny">{r}</p>
              </div>
              <div :if={@info.saturation != []} class="panel-body">
                <p :for={c <- @info.saturation} class="tiny">
                  <UI.badge value={c.level} /> <strong>{c.volume}</strong>: {Insights.fmt(c.value)} / {Insights.fmt_size(
                    c.limit
                  )} {c.unit} ({Insights.fmt_percent(c.percent)})
                  <span :for={r <- c.reasons} class="muted tiny">{r}</span>
                </p>
              </div>
              <div :if={@info.database} class="panel-body cc-metrics">
                <div>
                  <small>Connections</small><strong>{@info.database["details"]["connections"]}/{@info.database[
                    "details"
                  ]["max_connections"]}</strong>
                </div>
                <div>
                  <small>Replication lag</small><strong>{@info.database["details"][
                    "replication_lag_seconds"
                  ]} s</strong>
                </div>
                <div>
                  <small>Engine</small><strong>{@info.database["details"]["engine"]}</strong>
                </div>
              </div>
            </section>
          </div>
        </div>

        <section :for={f <- @info.findings} class="panel" id={"finding-#{f["id"]}"}>
          <div class="panel-heading">
            <div>
              <h2>{f["data"]["template"]}</h2>
              <p>
                First seen {UI.timestamp(f["first_seen"])} · {f["occurrences"]} observations · owner {f[
                  "owner"
                ] ||
                  "unassigned"}
              </p>
            </div>
            <UI.badge value={f["severity"]} />
          </div>
          <div class="panel-body">
            <p>
              <strong>Likely cause:</strong> {f["correlation"]["hypothesis"] || f["data"]["reason"]}
            </p>
            <p
              :for={c <- get_in(f, ["correlation", "result", "candidates"]) || []}
              :if={c["counterevidence"] != []}
              class="muted"
            >
              <strong>Against it:</strong> {Enum.join(c["counterevidence"], " ")}
            </p>
            <p class="muted tiny">{f["data"]["missing"]}</p>
            <.link href={
              ~p"/companies/#{@current_scope.company_id}/investigations?#{%{focus: f["id"]}}" <>
                "#groups-#{f["id"]}"
            }>Review, assign or snooze in Investigations →</.link>
          </div>
        </section>

        <section class="panel" id="runtime">
          <div class="panel-heading">
            <div>
              <h2>Runtime</h2>
              <p>Kubernetes objects for this service in {@info.cluster}</p>
            </div>
          </div>
          <p :if={@info.resources == []} class="panel-body muted">
            No Kubernetes objects retained for this service.
          </p>
          <div :if={@info.resources != []} class="table-scroll">
            <table class="data-table">
              <thead>
                <tr>
                  <th scope="col">Kind</th><th scope="col">Name</th><th scope="col">Status</th><th scope="col">
                    Details
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={
                  r <-
                    Enum.sort_by(
                      @info.resources,
                      &{&1["status"] in ~w(Running Available Configured Observed Normal), &1["kind"]}
                    )
                }>
                  <td>{r["kind"]}</td>
                  <td class="mono">{r["name"]}</td>
                  <td><UI.badge value={resource_tone(r["status"])} label={r["status"]} /></td>
                  <td class="tiny">{resource_details(r)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="panel" id="service-pipelines">
          <div class="panel-heading">
            <div>
              <h2>Pipeline runs</h2>
              <p>Most recent first</p>
            </div>
          </div>
          <p :if={@info.runs == []} class="panel-body muted">
            No pipeline runs mapped to this service.
          </p>
          <div :if={@info.runs != []} class="table-scroll">
            <table class="data-table">
              <tbody>
                <tr :for={r <- Enum.take(@info.runs, 10)}>
                  <td class="mono">#{r["run_id"]}</td>
                  <td><UI.badge value={r["result"]} /></td>
                  <td class="mono tiny">{r["branch"]}</td>
                  <td class="tiny">
                    <span :if={r["environment"]} class="env-code">{Enum.join(
                      r["environments"] || [],
                      "/"
                    )}</span>
                    <span :if={is_nil(r["environment"])} class="badge badge-neutral">environment unknown</span>
                  </td>
                  <td class="time-cell">{UI.timestamp(r["finish_at"])}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="panel" id="coverage">
          <div class="panel-heading">
            <div>
              <h2>Data coverage</h2>
              <p>Where the information above comes from. Stale sources mean blind spots.</p>
            </div>
          </div>
          <ul class="cc-list">
            <li
              :for={s <- @info.coverage}
              class={["cc-item", if(s["error"], do: "cc-warning", else: "cc-ok")]}
            >
              <span class="cc-bar" aria-hidden="true"></span>
              <div class="cc-main">
                <div class="cc-top">
                  <UI.badge value={s["freshness"]} /><strong>{s["name"]}</strong>
                </div>
                <p class="muted tiny">
                  {s["error"] || "OK"} · last success {UI.timestamp(s["last_success_at"])}
                </p>
              </div>
            </li>
          </ul>
        </section>

        <p class="panel-note">Updated {UI.timestamp(@refreshed_at)}</p>
      </div>
    </Layouts.app>
    """
  end

  defp resource_tone(status)
       when status in ~w(Running Available Configured Observed Normal Bound Ready),
       do: "normal"

  defp resource_tone(_), do: "warning"

  defp resource_details(%{"kind" => "Pod", "details" => d}),
    do:
      "node #{d["node"]} · restarts #{d["restartCount"]} · limit #{get_in(d, ["limits", "memory"])}"

  defp resource_details(%{"kind" => "Deployment", "details" => d}),
    do: "#{d["readyReplicas"]}/#{d["replicas"]} ready · #{d["image"]}"

  defp resource_details(%{"kind" => "Event", "details" => d}),
    do: "#{d["reason"]} ×#{d["count"]}"

  defp resource_details(%{"kind" => "Service", "details" => d}), do: "#{d["type"]} :#{d["port"]}"
  defp resource_details(_), do: ""
end
