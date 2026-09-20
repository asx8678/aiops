defmodule OpsBrainWeb.OperationsLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Tenancy, Store, Services, Issues, Notifications}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    socket =
      assign(socket,
        groups_count: 0,
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

  def handle_params(_params, _url, socket) do
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

    load(socket)
  end

  def handle_event("refresh", _, socket), do: load(socket)

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

  # R21: each route loads only the data it renders instead of every dataset.
  defp load(socket) do
    scope = socket.assigns.current_scope
    # Never keep an expired evidence snapshot across a refresh or navigation.
    socket = assign(socket, :selected_evidence, nil)

    case socket.assigns.live_action do
      :investigations ->
        case Issues.list(scope) do
          {:ok, groups} ->
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
          {:noreply, socket |> assign(:services, services) |> assign(:windows, windows)}
        else
          _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
        end

      :sources ->
        with {:ok, sources} <- Services.sources(scope) do
          {:noreply, assign(socket, :sources, sources)}
        else
          _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
        end

      :pipelines ->
        with {:ok, runs} <- pipeline_runs(scope) do
          {:noreply, assign(socket, :runs, runs)}
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
        <p>
          Classic releases unsupported. No full-history failure percentage is asserted. CI status is not verified runtime health.
        </p>
        <p :if={@runs == []}>No run observations.</p>
        <article :for={r <- @runs} id={"run-#{r["id"]}"}>
          Run {r["run_id"]} / definition {r["definition_id"]}: {r["status"]} / {r["result"]}; revision {r[
            "revision"
          ]}; observed {r["received_at"]}.
          <span :if={r["targets"] == []} class="target">Target unresolved — no retained explicit deployment evidence. CI-only, not runtime health.</span>
          <p :for={t <- r["targets"]} class="mapped-target">
            {t["service"]} / {t["environment"]} / {t["target"]}: reported {t["result"]}, attempt {t[
              "attempt"
            ]}.
            Reported deployment, not runtime-confirmed. At most 20 retained mappings per run.
          </p>
        </article>
      </section>

      <section :if={@live_action in [:services, :capacity]} id="services">
        <h2>Explicit service targets</h2>
        <p :if={@services == []}>No mapped service targets. Forecast eligibility unknown.</p>
        <article :for={s <- @services} id={"service-#{s["id"]}"}>
          {s["service_key"]} / {s["environment"]} / {s["target"]}
        </article>
        <h2>Stored observations and evaluations</h2>
        <p :if={@windows == []}>No retained observation windows.</p>
        <article :for={w <- @windows} id={"window-#{w["id"]}"}>
          {w["kind"]}: {w["profile"]} {w["window_start"]} – {w["window_end"]} / revision {w[
            "revision"
          ]} / condition {w["data"]["condition"] || "unknown"}
          <p :if={w["data"]["missing"]}>Missing prerequisite: {w["data"]["missing"]}</p>
          <details>
            <summary>Diagnostic JSON</summary>
            <pre>{Jason.encode!(w["data"], pretty: true)}</pre>
          </details>
        </article>
        <p :if={@live_action == :capacity}>
          Capacity forecasts appear only when a reviewed policy, explicit service mapping and sufficient fresh history exist. Unknown is not healthy.
        </p>
      </section>

      <section :if={@live_action == :sources} id="source-health">
        <h2>Source coverage and query use</h2>
        <p :if={@sources == []}>No configured sources for this company.</p>
        <article :for={s <- @sources} id={"health-#{s["id"]}"}>
          {s["name"]}: {s["freshness"]}; {s["error"] || "no recorded error"}; requests {s["requests"] ||
            0}, bytes received {s[
            "bytes"
          ] || 0}. Last success: {s["last_success_at"] || "never"}.
        </article>
      </section>

      <section :if={@live_action == :investigations} id="investigations">
        <h2>Local notices — no upstream acknowledgment or silence</h2>
        <p :if={@groups_count == 0}>No retained findings.</p>
        <div id="issue-groups" phx-update="stream">
          <article :for={{dom_id, g} <- @streams.groups} id={dom_id}>
            <h3>{g["severity"]}: {g["data"]["template"]}</h3>
            <p>
              {g["status"]}; owner {g["owner"] || "unassigned"}; snoozed until {g["snoozed_until"] ||
                "not snoozed"}; revision {g[
                "revision"
              ]}.
            </p>
            <p>
              first {g["first_seen"]}; last {g["last_seen"]}; {g["distinct_runs"]} distinct runs; {g[
                "occurrences"
              ]} occurrences ({g["data"]["count_basis"]}).
            </p>
            <p>
              Scope: {g["data"]["scope"] || "unresolved"}. {g["data"]["reason"]}. Missing: {g["data"][
                "missing"
              ]}
            </p>
            <.form
              for={g.owner_form}
              id={"assign-#{g["id"]}"}
              phx-submit="assign"
              phx-value-id={g["id"]}
            >
              <.input
                field={g.owner_form[:owner]}
                id={"owner-#{g["id"]}"}
                label="Local owner (blank to unassign)"
                maxlength="100"
              />
              <button type="submit">Save local owner</button>
            </.form>
            <button phx-click="evidence" phx-value-id={g["id"]}>Evidence</button>
            <button phx-click="snooze" phx-value-id={g["id"]}>Snooze locally for 1 hour</button>
            <button phx-click="review" phx-value-id={g["id"]} phx-value-status="locally_acknowledged">Acknowledge locally</button>
            <button phx-click="review" phx-value-id={g["id"]} phx-value-status="closed_by_reviewer">Close by review</button>
          </article>
        </div>
      </section>

      <section :if={@selected_evidence} id="evidence">
        <h3>Evidence for {@selected_evidence.group_id}</h3>
        <h4>Local notification state</h4>
        <p :if={@selected_evidence.notifications == []}>No local notification records.</p>
        <article :for={n <- @selected_evidence.notifications} id={"notice-#{n["id"]}"}>
          {n["destination"]}: {n["status"]} (attempts {n["attempts"]}); next {n["next_at"] || "—"}.
          Ambiguous sends are not retried automatically.
        </article>
        <h4>Evidence revisions</h4>
        <p :if={@selected_evidence.revisions == []}>No revision history retained.</p>
        <table :if={@selected_evidence.revisions != []} id="evidence-revisions">
          <tr :for={e <- @selected_evidence.revisions}>
            <td>{e["revision"]}</td>
            <td>{e["kind"]}</td>
            <td>{e["reason"]}</td>
            <td>{if(e["current"], do: "current", else: "historical")}</td>
            <td>{e["occurred_at"]} / received {e["received_at"]}</td>
            <td>{e["data"]["status"] || "retained"}</td>
          </tr>
        </table>
        <h4>Retained evidence and investigation candidates</h4>
        <p>
          At most 20 occurrence samples, 5 correlation/recovery records, 50 revisions and 20 local notification records. Counts are not full-history totals.
        </p>
        <article :for={e <- @selected_evidence.items} class="evidence-item">
          <h5>{e["kind"]} — {e["id"]}</h5>
          <p>Occurred {e["occurred_at"]}; received {e["received_at"]}; expires {e["expires_at"]}.</p>
          <p :if={e["data"]["status"] == "expired"}>Evidence expired; exact replay unavailable.</p>
          <div
            :if={e["kind"] == "correlation" && e["data"]["result"]}
            class="investigation-candidates"
          >
            <p>Missing: {e["data"]["result"]["missing"]}</p>
            <p :if={e["data"]["result"]["candidates"] == []}>
              No supported candidate from retained evidence.
            </p>
            <article :for={candidate <- e["data"]["result"]["candidates"] || []}>
              <p>
                {candidate["relation"]}. Change evidence {candidate["change_evidence_id"]}; symptom evidence {candidate[
                  "symptom_evidence_id"
                ]}; separation {candidate["elapsed_seconds"]} seconds.
              </p>
              <p :for={counter <- candidate["counterevidence"] || []}>Counterevidence: {counter}</p>
            </article>
          </div>
          <details>
            <summary>Sanitized diagnostic JSON</summary>
            <pre>{Jason.encode!(e, pretty: true)}</pre>
          </details>
        </article>
      </section>

      <button id="refresh-operations" phx-click="refresh">Refresh authorized data</button>
    </Layouts.app>
    """
  end
end
