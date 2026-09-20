defmodule OpsBrainWeb.Router do
  use OpsBrainWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpsBrainWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :no_cache
    plug OpsBrainWeb.LoginLimiter
    plug OpsBrainWeb.OperatorAuth, :fetch
  end

  defp no_cache(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  pipeline :authenticated do
    plug OpsBrainWeb.OperatorAuth, :require
  end

  scope "/", OpsBrainWeb do
    pipe_through :browser
    get "/sign-in", SessionController, :new
    post "/sign-in", SessionController, :create
    post "/auth/oidc", OIDCController, :start, log: false
    get "/auth/oidc/callback", OIDCController, :callback, log: false
    delete "/sign-out", SessionController, :delete
  end

  scope "/", OpsBrainWeb do
    pipe_through [:browser, :authenticated]

    live_session :operators, on_mount: [{OpsBrainWeb.OperatorAuth, :require}] do
      live "/", PortfolioLive, :index
      live "/companies/:company_id", CompanyLive, :show
      live "/companies/:company_id/demo", DemoLive, :index
      live "/companies/:company_id/pipelines", OperationsLive, :pipelines
      live "/companies/:company_id/services", OperationsLive, :services
      live "/companies/:company_id/investigations", OperationsLive, :investigations
      live "/companies/:company_id/capacity", OperationsLive, :capacity
      live "/companies/:company_id/source-health", OperationsLive, :sources
      live "/companies/:company_id/sources/:id", CompanyLive, :source
    end
  end
end
