defmodule OpsBrainWeb.UI do
  @moduledoc "Presentation primitives. Status labels describe stored facts, never inferred health."
  use Phoenix.Component
  import OpsBrainWeb.CoreComponents, only: [icon: 1]

  @logo_path Path.expand("../../../priv/static/images/constellation.svg", __DIR__)
  @external_resource @logo_path
  @logo_svg File.read!(@logo_path)

  attr :class, :string, default: nil

  def brand_logo(assigns) do
    assigns = assign(assigns, :svg, @logo_svg)

    ~H"""
    <span class={["constellation-logo", @class]} aria-hidden="true">{Phoenix.HTML.raw(@svg)}</span>
    """
  end

  def areas do
    [
      {:show, "Configuration", "", "hero-squares-2x2",
       "Environment identities and source configuration"},
      {:pipelines, "Pipelines", "/pipelines", "hero-command-line",
       "Build results and delivery evidence"},
      {:services, "Services", "/services", "hero-server-stack",
       "Explicit targets and observed conditions"},
      {:investigations, "Investigations", "/investigations", "hero-magnifying-glass",
       "Findings, context, and local review"},
      {:capacity, "Capacity", "/capacity", "hero-chart-bar",
       "Stored evaluations and conditional forecasts"},
      {:sources, "Source health", "/source-health", "hero-signal",
       "Collection coverage and freshness"}
    ]
  end

  def area(action), do: Enum.find(areas(), &(elem(&1, 0) == action)) || hd(areas())
  def title(action), do: elem(area(action), 1)
  def description(action), do: elem(area(action), 4)

  def dev_auto_login?, do: OpsBrainWeb.DevAutoLogin.enabled?()

  attr :eyebrow, :string, default: "WORKSPACE"
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="page-heading">
      <div>
        <p class="eyebrow">{@eyebrow}</p><h1>{@title}</h1><p class="page-description">
          {@description}
        </p>
      </div>
      <div :if={@actions != []} class="heading-actions">{render_slot(@actions)}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, required: true
  attr :icon, :string, default: "hero-squares-2x2"

  def stat(assigns) do
    ~H"""
    <div class="stat-card">
      <div class="stat-label">{@label}<.icon name={@icon} /></div><div class="stat-value">
        {@value}
      </div><p>{@hint}</p>
    </div>
    """
  end

  attr :value, :any, default: nil
  attr :label, :string, default: nil

  def badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{tone(@value)}"]}><span class="status-dot" aria-hidden="true"></span>{@label ||
      humanize(@value)}</span>
    """
  end

  attr :icon, :string, default: "hero-signal"
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :action

  def empty(assigns) do
    ~H"""
    <div class="empty-state">
      <div class="empty-symbol"><.icon name={@icon} /></div><h3>{@title}</h3><p>{@description}</p><div
        :if={@action != []}
        class="empty-action"
      >
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  # Counts describe the bounded retained set before search, not rates or live health.
  def summaries(:pipelines, runs) do
    [
      {"Retained runs", length(runs), "Up to 100 · before search", "hero-command-line"},
      {"Reported failed", Enum.count(runs, &(&1["result"] == "failed")),
       "Within loaded runs · not runtime incidents", "hero-exclamation-circle"},
      {"Reported succeeded", Enum.count(runs, &(&1["result"] == "succeeded")),
       "Within loaded runs · not runtime health", "hero-check"},
      {"Unresolved targets", Enum.count(runs, &(&1["targets"] == [])),
       "No retained explicit deployment mapping", "hero-server-stack"}
    ]
  end

  def summaries(:investigations, groups) do
    [
      {"Retained findings", length(groups), "Up to 100 · before search", "hero-magnifying-glass"},
      {"Critical severity", Enum.count(groups, &(&1["severity"] == "critical")),
       "Within loaded findings, all review states", "hero-exclamation-circle"},
      {"Unassigned", Enum.count(groups, &is_nil(&1["owner"])),
       "Within loaded findings, all review states", "hero-building-office-2"},
      {"Acknowledged locally", Enum.count(groups, &(&1["status"] == "locally_acknowledged")),
       "Within loaded findings · no upstream action", "hero-check"}
    ]
  end

  def summaries(:sources, sources) do
    [
      {"Source identities", length(sources), "Up to 100 · before search", "hero-signal"},
      {"Stale sources", Enum.count(sources, &(&1["freshness"] == "stale")),
       "Within loaded sources · inspect coverage", "hero-clock"},
      {"Never observed", Enum.count(sources, &is_nil(&1["last_success_at"])),
       "No recorded successful collection", "hero-magnifying-glass"},
      {"Recorded errors", Enum.count(sources, &(&1["error"] not in [nil, ""])),
       "Sources with an error in the loaded set", "hero-exclamation-circle"}
    ]
  end

  def summaries(action, {services, windows}) when action in [:services, :capacity] do
    [
      {"Mapped targets", length(services), "Up to 100 · identities, not healthy services",
       "hero-server-stack"},
      {"Retained windows", length(windows), "Up to 100 · before search", "hero-chart-bar"},
      {"Warning / critical",
       Enum.count(windows, &(&1["data"]["condition"] in ["warning", "critical"])),
       "Stored evaluations · not current incidents", "hero-exclamation-circle"},
      {"Unknown condition", Enum.count(windows, &(&1["data"]["condition"] in [nil, "unknown"])),
       "Within loaded windows · not normal", "hero-magnifying-glass"}
    ]
  end

  def humanize("partiallySucceeded"), do: "Partially succeeded"
  def humanize("inProgress"), do: "In progress"
  def humanize(nil), do: "Unknown"
  def humanize(""), do: "Unknown"
  def humanize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  def tone(value) when value in ["critical", "failed", "error"], do: "danger"

  def tone(value)
      when value in ["warning", "watch", "partial", "stale", "ambiguous", "partiallySucceeded"],
      do: "warning"

  def tone(value) when value in ["normal", "succeeded", "complete", "recovered"], do: "success"

  def tone(value) when value in ["active", "new", "inProgress", "locally_acknowledged"],
    do: "info"

  def tone(_), do: "neutral"

  def timestamp(nil), do: "Not observed"
  def timestamp(%DateTime{} = time), do: Calendar.strftime(time, "%d %b %Y, %H:%M UTC")
  def timestamp(%NaiveDateTime{} = time), do: Calendar.strftime(time, "%d %b %Y, %H:%M UTC")
  def timestamp(time), do: to_string(time)
  def initial(name), do: name |> String.trim() |> String.first() |> to_string() |> String.upcase()
end
