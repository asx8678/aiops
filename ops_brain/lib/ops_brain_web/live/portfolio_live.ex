defmodule OpsBrainWeb.PortfolioLive do
  @moduledoc """
  Workspace landing: a resolved workspace goes straight to the command
  center. Only the workspace-error state renders here (misconfigured or
  ambiguous membership, or a revoked workspace), never a company chooser —
  configuration selects a home, never grants access. Every event still
  rechecks the session through the OperatorAuth hooks.
  """
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Accounts, Workspace}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: load(socket)

  @impl true
  def handle_event("refresh", _params, socket), do: load(socket)

  defp load(socket) do
    token = socket.assigns.session_token

    case Workspace.resolve(token) do
      {:ok, scope} ->
        {:noreply, redirect(socket, to: ~p"/companies/#{scope.company_id}/command")}

      {:error, reason} ->
        if Accounts.operator_for_session(token) do
          {:noreply, assign(socket, current_scope: nil, company: nil, workspace_error: reason)}
        else
          {:noreply, redirect(socket, to: ~p"/sign-in")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title="Home"
      company={@company && @company.name}
    >
      <UI.page_header
        eyebrow="YOUR COMMAND CENTER"
        title="A clearer view of operations."
        description="One workspace. Three environments. The evidence that connects it all."
      >
        <:actions>
          <button class="btn" id="refresh" phx-click="refresh" phx-disable-with="Refreshing…"><.icon name="hero-arrow-path" />Refresh</button>
        </:actions>
      </UI.page_header>
      <div class="portfolio-intro">
        <div>
          <p class="eyebrow">CONTEXT, NOT MORE NOISE</p><h2>Every signal. The right context.</h2><p>
            Follow the thread from a deployment to a symptom. Bring your services, observations, and investigation evidence into one clear picture.
          </p>
        </div><div class="intro-art" aria-hidden="true"><UI.brand_logo /></div>
      </div>
      <section :if={@workspace_error} id="workspace-unavailable" class="panel">
        <UI.empty
          title="Your workspace needs attention"
          description="An administrator must configure this deployment’s workspace and grant your operator access. No company is selected automatically when membership is ambiguous."
        />
        <p class="panel-note">
          Set OPS_BRAIN_WORKSPACE_COMPANY_ID to the approved company UUID. No data from another workspace is shown.
        </p>
      </section>
    </Layouts.app>
    """
  end
end
