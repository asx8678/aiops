defmodule OpsBrainWeb.CommandLive do
  @moduledoc "Single landing view: what needs attention now and what is about to break."
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Insights, Store, Tenancy}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 30_000)

    {:ok,
     assign(socket,
       data: nil,
       refreshed_at: nil,
       company_name: nil,
       environment: "",
       filter_form: to_form(%{"environment" => ""})
     )}
  end

  def handle_params(params, _url, socket) do
    # The URL carries the selection so navigation, refreshes and shared links
    # keep it; anything but dev/staging/prod is treated as All environments.
    environment = environment(params["environment"])

    case Tenancy.company(socket.assigns.current_scope) do
      {:ok, company} ->
        load(
          assign(socket,
            company_name: company.name,
            environment: environment,
            filter_form: to_form(%{"environment" => environment})
          )
        )

      _ ->
        {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    load(socket)
  end

  def handle_event("refresh", _, socket), do: load(socket)

  def handle_event("environment", %{"environment" => value}, socket) do
    environment = environment(value)
    company_id = socket.assigns.current_scope.company_id

    # Patching the URL keeps the selection in the address bar and re-loads the
    # filtered reads through handle_params.
    {:noreply,
     push_patch(socket,
       to:
         if(environment == "",
           do: ~p"/companies/#{company_id}/command",
           else: ~p"/companies/#{company_id}/command?#{%{environment: environment}}"
         )
     )}
  end

  def handle_event("environment", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid environment selection.")}

  defp environment(value) when value in ["dev", "staging", "prod"], do: value
  defp environment(_), do: ""

  defp load(socket) do
    case Insights.command(
           socket.assigns.current_scope,
           socket.assigns.environment,
           Store.now()
         ) do
      {:ok, data} -> {:noreply, assign(socket, data: data, refreshed_at: Store.now())}
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:command}
      company={@company_name}
      title="Command center"
      live_refresh={true}
    >
      <UI.page_header
        eyebrow="START HERE"
        title="Command center"
        description="What is broken now, what is about to break, and where you are blind. Click any item to troubleshoot it."
      >
        <:actions>
          <.form
            for={@filter_form}
            id="command-environment-form"
            phx-change="environment"
            class="heading-filter"
          >
            <.input
              field={@filter_form[:environment]}
              id="command-environment"
              type="select"
              aria-label="Filter by environment"
              options={[
                {"All environments", ""},
                {"Development", "dev"},
                {"Staging", "staging"},
                {"Production", "prod"}
              ]}
            />
          </.form>
          <button
            class="btn"
            id="refresh-command"
            phx-click="refresh"
            phx-disable-with="Refreshing…"
          ><.icon name="hero-arrow-path" />Refresh</button>
        </:actions>
      </UI.page_header>

      <div :if={@data} class="stats-grid" id="command-stats">
        <UI.stat
          label="Act now"
          value={@data.counts.critical}
          hint="Critical signals"
          icon="hero-fire"
        />
        <UI.stat
          label="Watch"
          value={@data.counts.warning}
          hint="Warnings on live targets"
          icon="hero-eye"
        />
        <UI.stat
          label="Predicted problems"
          value={@data.counts.predicted}
          hint="Storage and pipelines trending badly"
          icon="hero-arrow-trending-up"
        />
        <UI.stat
          label="Blind spots"
          value={@data.counts.blind}
          hint="Sources with stale or failing data"
          icon="hero-eye-slash"
        />
      </div>

      <section :if={@data} class="panel" id="attention">
        <div class="panel-heading">
          <div>
            <h2>Needs attention now</h2>
            <p>
              Findings, degraded targets, saturated databases and unhealthy nodes · production first
            </p>
          </div>
          <UI.badge label={"#{length(@data.attention)} items"} />
        </div>
        <UI.empty
          :if={@data.attention == []}
          icon="hero-check-circle"
          title="Nothing flagged right now"
          description="No open findings or degraded signals in the retained data. Check blind spots below: missing data is not the same as healthy."
        />
        <ul :if={@data.attention != []} class="cc-list">
          <li :for={item <- @data.attention} class={["cc-item", "cc-#{item.level}"]}>
            <span class="cc-bar" aria-hidden="true"></span>
            <div class="cc-main">
              <div class="cc-top">
                <UI.badge value={item.level} />
                <span class="cc-kind">{item.kind}</span>
                <span :if={item.environment} class="env-code">{item.environment}</span>
                <span :if={item.owner} class="muted tiny">owner: {item.owner}</span>
                <span :if={item.status} class="muted tiny">{UI.humanize(item.status)}</span>
              </div>
              <strong>{item.title}</strong>
              <p :if={item.detail} class="muted">{item.detail}</p>
            </div>
            <.link
              :if={item[:group_id]}
              class="btn"
              href={
                ~p"/companies/#{@current_scope.company_id}/investigations?#{%{focus: item[:group_id]}}" <>
                  "#groups-#{item[:group_id]}"
              }
            >Investigate<.icon name="hero-arrow-right" /></.link>
            <.link
              :if={item.service && item.environment}
              class="btn"
              navigate={troubleshoot_path(@current_scope, item.service, item.environment)}
            >Troubleshoot<.icon name="hero-arrow-right" /></.link>
          </li>
        </ul>
        <p class="panel-note">
          Runtime coverage: Kubernetes collectors retain pods, deployments, replicasets and events only — node and database health is not collected and appears here only from stored evidence.
        </p>
      </section>

      <div :if={@data} class="cc-columns">
        <section class="panel" id="storage-risks">
          <div class="panel-heading">
            <div>
              <h2>Storage forecast</h2>
              <p>
                Last 24 h of used space · abnormal growth compares the last 6 h with the earlier baseline
              </p>
            </div>
          </div>
          <UI.empty
            :if={@data.storage == []}
            icon="hero-circle-stack"
            title="No storage history"
            description="Volumes appear here once used-space samples are collected."
          />
          <ul :if={@data.storage != []} class="cc-list">
            <li :for={s <- @data.storage} class={["cc-item", "cc-#{s.level}"]}>
              <span class="cc-bar" aria-hidden="true"></span>
              <div class="cc-main">
                <div class="cc-top">
                  <UI.badge value={level_value(s.level)} />
                  <strong>{s.volume}</strong>
                  <span class="env-code">{s.environment}</span>
                  <span :if={s.abnormal} class="badge badge-danger">abnormal growth</span>
                </div>
                <div
                  :if={is_number(s.used_percent)}
                  class="cc-meter"
                  title={"#{round(s.used_percent)}% used"}
                >
                  <span style={"width: #{min(s.used_percent, 100)}%"}></span>
                </div>
                <p class="tiny">
                  {Insights.fmt(s.used_gib)} / {Insights.fmt_size(s.size_gib)} GiB ({Insights.fmt_percent(
                    s.used_percent
                  )}) ·
                  now {Insights.fmt(s.recent_rate)} GiB/h · full in {Insights.fmt_hours(
                    s.hours_to_full
                  )}
                </p>
                <p :for={r <- s.reasons} class="muted tiny">{r}</p>
              </div>
              <.sparkline values={s.history} max={s.size_gib} level={s.level} />
              <.link
                :if={s.service && s.environment}
                class="text-link"
                navigate={troubleshoot_path(@current_scope, s.service, s.environment)}
              ><.icon name="hero-arrow-right" /></.link>
            </li>
          </ul>
        </section>

        <section :if={@data.saturation != []} class="panel" id="saturation-risks">
          <div class="panel-heading">
            <div>
              <h2>Saturation</h2>
              <p>
                Count and memory signals with verified limits · unverified or mixed data stays unknown
              </p>
            </div>
          </div>
          <ul class="cc-list">
            <li :for={c <- @data.saturation} class={["cc-item", "cc-#{c.level}"]}>
              <span class="cc-bar" aria-hidden="true"></span>
              <div class="cc-main">
                <div class="cc-top">
                  <UI.badge value={level_value(c.level)} />
                  <strong>{c.volume}</strong>
                  <span :if={c.environment} class="env-code">{c.environment}</span>
                </div>
                <div :if={is_number(c.percent)} class="cc-meter" title={"#{round(c.percent)}% used"}>
                  <span style={"width: #{min(c.percent, 100)}%"}></span>
                </div>
                <p class="tiny">
                  {Insights.fmt(c.value)} / {Insights.fmt_size(c.limit)} {c.unit} ({Insights.fmt_percent(
                    c.percent
                  )}) ·
                  now {Insights.fmt(c.recent_rate)} {c.unit}/h · full in {Insights.fmt_hours(
                    c.hours_to_full
                  )}
                </p>
                <p :for={r <- c.reasons} class="muted tiny">{r}</p>
              </div>
              <.link
                :if={c.service && c.environment}
                class="text-link"
                navigate={troubleshoot_path(@current_scope, c.service, c.environment)}
              ><.icon name="hero-arrow-right" /></.link>
            </li>
          </ul>
        </section>

        <section class="panel" id="pipeline-risks">
          <div class="panel-heading">
            <div>
              <h2>Pipeline health</h2>
              <p>Last 10 runs per pipeline, newest on the left · streaks predict blocked deploys</p>
            </div>
          </div>
          <UI.empty
            :if={@data.pipelines == []}
            icon="hero-command-line"
            title="No pipeline runs"
            description="Runs appear here once build collection is enabled."
          />
          <ul :if={@data.pipelines != []} class="cc-list" id="pipeline-list">
            <li
              :for={p <- Enum.take(@data.pipelines, 12)}
              class={["cc-item", "cc-#{p.level}"]}
              id={"pipeline-#{p.name}"}
            >
              <span class="cc-bar" aria-hidden="true"></span>
              <div class="cc-main">
                <div class="cc-top">
                  <UI.badge value={level_value(p.level)} /><strong>{p.name}</strong>
                  <span :if={p.ci_only} class="badge badge-neutral">CI-only</span>
                  <span :if={p.flaky} class="badge badge-warning">flaky</span>
                </div>
                <p class="muted tiny">
                  {p.reason} · last success {UI.timestamp(p.last_success)}
                </p>
              </div>
              <div class="cc-runs" aria-label={"Recent results: #{Enum.join(p.results, ", ")}"}>
                <span
                  :for={r <- p.results}
                  class={"cc-run cc-run-#{Insights.result_level(r)}"}
                  title={UI.humanize(r)}
                ></span>
              </div>
            </li>
          </ul>
          <p :if={length(@data.pipelines) > 12} class="panel-note">
            {length(@data.pipelines) - 12} more healthy pipelines ·
            <.link navigate={~p"/companies/#{@current_scope.company_id}/pipelines"}>all runs</.link>
          </p>
        </section>
      </div>

      <section :if={@data} class="panel" id="blind-spots">
        <div class="panel-heading">
          <div>
            <h2>Blind spots</h2>
            <p>Sources that are stale or erroring. Anything they cover is unknown, not healthy.</p>
          </div>
        </div>
        <UI.empty
          :if={@data.blind_spots == []}
          icon="hero-signal"
          title="All sources reporting"
          description="Every configured source returned data recently."
        />
        <ul :if={@data.blind_spots != []} class="cc-list">
          <li :for={s <- @data.blind_spots} class="cc-item cc-warning">
            <span class="cc-bar" aria-hidden="true"></span>
            <div class="cc-main">
              <div class="cc-top">
                <UI.badge value={s["freshness"]} /><strong>{s["name"]}</strong>
              </div>
              <p class="muted tiny">
                {s["error"] || "No recent data"} · last success {UI.timestamp(s["last_success_at"])}
              </p>
            </div>
          </li>
        </ul>
      </section>

      <section :if={@data} class="panel" id="service-jump">
        <div class="panel-heading">
          <div>
            <h2>Troubleshoot any service</h2>
            <p>
              Everything about one service on one page: changes, pods, metrics, storage, pipelines, findings
            </p>
          </div>
        </div>
        <div class="panel-body cc-chips">
          <.link
            :for={
              s <- Enum.sort_by(@data.services, &{&1["environment"] != "prod", &1["service_key"]})
            }
            class="cc-chip"
            navigate={troubleshoot_path(@current_scope, s["service_key"], s["environment"])}
          >{s["service_key"]}<span class="env-code">{s["environment"]}</span></.link>
        </div>
      </section>

      <p class="panel-note">Updated {UI.timestamp(@refreshed_at)} · refreshes every 30 s</p>
    </Layouts.app>
    """
  end

  attr :values, :list, required: true
  attr :max, :any, required: true
  attr :level, :string, default: "ok"

  def sparkline(assigns) do
    # History values and the volume limit can be unknown (nil); render only the
    # usable numbers instead of crashing on term-ordering comparisons.
    values = Enum.filter(assigns.values || [], &is_number/1)
    count = max(length(values) - 1, 1)

    top =
      case assigns.max do
        m when is_number(m) and m > 0 -> max(m, Enum.max(values, fn -> 1 end))
        _ -> Enum.max(values, fn -> 1 end)
      end

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        "#{Float.round(i * 120 / count, 1)},#{Float.round(36 - v / top * 34, 1)}"
      end)

    assigns = assign(assigns, points: points)

    ~H"""
    <svg
      class={"cc-spark cc-spark-#{@level}"}
      viewBox="0 0 120 38"
      role="img"
      aria-label="Used space, last 24 hours"
    >
      <line x1="0" y1="2" x2="120" y2="2" class="cc-spark-limit" />
      <polyline points={@points} fill="none" />
    </svg>
    """
  end

  def troubleshoot_path(scope, service, environment),
    do:
      ~p"/companies/#{scope.company_id}/troubleshoot?#{[service: service, environment: environment]}"

  defp level_value("ok"), do: "normal"
  defp level_value(level), do: level
end
