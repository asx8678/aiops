defmodule OpsBrain.Fixtures do
  @moduledoc "Synthetic fixtures only. Never seed a real company or source. Tests run serially on a disposable database."
  alias OpsBrain.{Accounts, Repo, Tenancy, TestAdminRepo}
  alias OpsBrain.Accounts.Operator
  alias OpsBrain.Tenancy.{Company, Membership}

  def clean! do
    TestAdminRepo.query!(
      "TRUNCATE oban_jobs, operator_tokens, memberships, sources, environments, companies, operators CASCADE"
    )
  end

  def fixture do
    a =
      TestAdminRepo.insert!(%Company{
        id: "00000000-0000-4000-8000-000000000001",
        name: "Synthetic A",
        slug: "synthetic-a"
      })

    b =
      TestAdminRepo.insert!(%Company{
        id: "00000000-0000-4000-8000-000000000002",
        name: "Synthetic B",
        slug: "synthetic-b"
      })

    alice = TestAdminRepo.insert!(%Operator{name: "synthetic-alice"})
    bob = TestAdminRepo.insert!(%Operator{name: "synthetic-bob"})
    dual = TestAdminRepo.insert!(%Operator{name: "synthetic-dual"})

    for {operator, company} <- [{alice, a}, {bob, b}, {dual, a}, {dual, b}] do
      TestAdminRepo.insert!(%Membership{operator_id: operator.id, company_id: company.id})
    end

    token_a =
      Accounts.issue_token(alice.id, "session", DateTime.add(DateTime.utc_now(), 1, :hour))

    token_b = Accounts.issue_token(bob.id, "session", DateTime.add(DateTime.utc_now(), 1, :hour))

    token_dual =
      Accounts.issue_token(dual.id, "session", DateTime.add(DateTime.utc_now(), 1, :hour))

    {:ok, scope_a} = Tenancy.authorize(token_a, a.id)
    {:ok, scope_b} = Tenancy.authorize(token_b, b.id)

    envs =
      for scope <- [scope_a, scope_b], name <- [:dev, :staging, :prod] do
        {:ok, env} = Tenancy.create_environment(scope, %{name: name})
        env
      end

    {:ok, source_a} = Tenancy.create_source(scope_a, %{name: "delivery"})
    {:ok, source_b} = Tenancy.create_source(scope_b, %{name: "delivery"})

    %{
      a: a,
      b: b,
      alice: alice,
      bob: bob,
      dual: dual,
      token_a: token_a,
      token_b: token_b,
      token_dual: token_dual,
      scope_a: scope_a,
      scope_b: scope_b,
      envs: envs,
      source_a: source_a,
      source_b: source_b
    }
  end

  def login_token(operator, expires_at \\ DateTime.add(DateTime.utc_now(), 15, :minute)) do
    Accounts.issue_token(operator.id, "login", expires_at)
  end

  def connection_id do
    %{rows: [[id]]} = Repo.query!("SELECT pg_backend_pid()")
    id
  end
end
