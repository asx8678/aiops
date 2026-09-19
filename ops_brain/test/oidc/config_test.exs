Code.require_file("fixture_helper.exs", __DIR__)

defmodule OpsBrain.OIDC.ConfigTest do
  use ExUnit.Case, async: false
  alias OpsBrain.OIDC.{Config, TestFixtures}

  test "disabled by default, explicit review and every required environment reference fail closed" do
    refs = TestFixtures.configure(TestFixtures.config())
    assert {:ok, config} = Config.load()
    assert config.subjects == TestFixtures.config().subjects
    assert Config.available?()
    settings = Application.get_env(:ops_brain, :oidc)
    Application.put_env(:ops_brain, :oidc, Keyword.delete(settings, :enabled))
    assert {:error, :disabled} = Config.load()
    Application.put_env(:ops_brain, :oidc, settings)

    for key <- [
          :reviewed,
          :issuer,
          :authorization_endpoint,
          :token_endpoint,
          :jwks_uri,
          :redirect_uri,
          :client_id,
          :subjects,
          :auth_method
        ] do
      name = refs[key]
      value = System.fetch_env!(name)
      System.delete_env(name)
      assert {:error, :unconfigured} = Config.load()
      System.put_env(name, value)
    end

    System.put_env(refs[:reviewed], "false")
    refute Config.available?()
  end

  test "no discovered or user-chosen URLs; only canonical exact HTTPS endpoints on port 443" do
    assert Config.https_endpoint?("https://id.example.test/tenant/v2.0")

    for url <- [
          nil,
          "",
          "http://id.example.test",
          "//id.example.test",
          "https://id.example.test:8443",
          "https://id.example.test:443/token",
          "https://ID.example.test/token",
          "https://user@id.example.test",
          "https://id.example.test/token?x=1",
          "https://id.example.test/token#x",
          "https://id.example.test/%2e%2e/token",
          "https://id.example.test/../token",
          "https://id.example.test\\evil",
          "https://id.example.test/\ntoken"
        ] do
      refute Config.https_endpoint?(url), inspect(url)
    end
  end

  test "mapping is explicit subject-to-UUID, never email or group auto-enrollment; secret auth is explicit" do
    refs = TestFixtures.configure(TestFixtures.config())

    for bad <- [
          "{}",
          "[]",
          "bad",
          ~s({"approved-subject":"admin@example.test"}),
          ~s({"":"00000000-0000-4000-8000-000000000001"})
        ] do
      System.put_env(refs[:subjects], bad)
      assert {:error, :unconfigured} = Config.load()
    end

    System.put_env(refs[:subjects], Jason.encode!(TestFixtures.config().subjects))
    System.put_env(refs[:auth_method], "client_secret_post")
    assert {:error, :unconfigured} = Config.load()
    System.put_env(refs[:client_secret], "synthetic-secret")
    assert {:ok, %{auth_method: "client_secret_post"}} = Config.load()
    System.put_env(refs[:redirect_uri], "https://ops.example.test/other-callback")
    assert {:error, :unconfigured} = Config.load()
  end
end
