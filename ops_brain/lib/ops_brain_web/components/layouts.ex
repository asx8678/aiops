defmodule OpsBrainWeb.Layouts do
  use OpsBrainWeb, :html
  embed_templates "layouts/*"
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header><a href="/">Ops Brain v2</a> · Read-only operations</header>
    <main>{render_slot(@inner_block)}</main>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
