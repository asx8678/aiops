# No application/Repo startup, test_helper, database safety probe, or live HTTP.
ExUnit.start()

for app <- [:req, :jose, :phoenix] do
  {:ok, _} = Application.ensure_all_started(app)
end

for file <- ["oidc_test.exs", "http_test.exs", "config_test.exs", "controller_offline_test.exs"] do
  Code.require_file(file, __DIR__)
end
