defmodule OpsBrain.TenancyTest do
  use OpsBrain.DataCase, async: false
  alias OpsBrain.Tenancy.{Environment, Membership, Scope, Source}

  setup do
    fixture()
  end

  test "portfolio includes only current memberships, including explicit dual membership", f do
    assert {:ok, [company]} = Tenancy.list_companies(f.token_a)
    assert company.id == f.a.id
    assert {:ok, companies} = Tenancy.list_companies(f.token_dual)
    assert Enum.map(companies, & &1.id) == [f.a.id, f.b.id]
    assert {:error, :unauthorized} = Tenancy.list_companies(nil)
  end

  test "colliding display names do not grant access or merge sources", f do
    assert {:ok, own} = Tenancy.get_source(f.scope_a, f.source_a.id)
    assert own.name == f.source_b.name
    assert {:error, :not_found} = Tenancy.get_source(f.scope_a, f.source_b.id)
    assert {:error, :not_found} = Tenancy.get_source(f.scope_a, "malformed")
    assert {:error, :unauthorized} = Tenancy.authorize(f.token_a, f.b.id)
    assert {:error, :unauthorized} = Tenancy.overview(nil)

    assert {:error, :unauthorized} =
             Tenancy.overview(%Scope{session_token: f.token_a, company_id: f.b.id})
  end

  test "caller fields cannot override trusted source or environment company binding", f do
    {:ok, source} =
      Tenancy.create_source(f.scope_a, %{name: "forged", company_id: f.b.id, id: f.source_b.id})

    assert source.company_id == f.a.id
    refute source.id == f.source_b.id
    b_env = Enum.find(f.envs, &(&1.company_id == f.b.id))

    assert {:error, changeset} =
             Tenancy.create_source(f.scope_a, %{name: "wrong-target", environment_id: b_env.id})

    assert Keyword.has_key?(changeset.errors, :environment_id)
    assert {:error, _} = Tenancy.create_environment(f.scope_a, %{name: "unknown"})
    assert {:error, _} = Tenancy.create_source(f.scope_a, %{name: "delivery"})
    {:ok, data} = Tenancy.overview(f.scope_a)
    assert Enum.sort(Enum.map(data.environments, & &1.name)) == [:dev, :prod, :staging]
    assert is_nil(f.source_a.environment_id)
  end

  test "database RLS denies unscoped reads and writes and filters a raw cross-company query", f do
    assert Repo.all(Source) == []
    assert Repo.all(Environment) == []
    assert {:ok, sources} = Tenancy.with_scope(f.scope_a, fn -> Repo.all(Source) end)
    assert Enum.map(sources, & &1.id) == [f.source_a.id]

    assert_raise Postgrex.Error, fn ->
      Repo.insert!(%Source{company_id: f.a.id, name: "unsafe"})
    end

    assert_raise Postgrex.Error, fn ->
      Tenancy.with_scope(f.scope_a, fn ->
        Repo.insert!(%Source{company_id: f.b.id, name: "unsafe"})
      end)
    end

    assert Repo.all(Source) == []
  end

  test "one pooled connection resets company setting on commit, rollback and exception", f do
    id = connection_id()
    assert {:ok, _} = Tenancy.overview(f.scope_a)
    assert connection_id() == id
    assert Repo.all(Source) == []
    assert {:error, :probe} = Tenancy.with_scope(f.scope_a, fn -> Repo.rollback(:probe) end)
    assert connection_id() == id
    assert Repo.all(Source) == []

    assert_raise RuntimeError, "probe", fn ->
      Tenancy.with_scope(f.scope_a, fn -> raise "probe" end)
    end

    assert connection_id() == id
    assert Repo.all(Source) == []
    assert {:ok, data} = Tenancy.overview(f.scope_b)
    assert Enum.map(data.sources, & &1.id) == [f.source_b.id]
  end

  test "nested scopes fail closed", f do
    assert {:error, :nested_scope} =
             Tenancy.with_scope(f.scope_a, fn -> Tenancy.overview(f.scope_b) end)

    assert Repo.all(Source) == []
  end

  test "revoked memberships invalidate previously constructed scopes", f do
    TestAdminRepo.delete_all(from m in Membership, where: m.operator_id == ^f.alice.id)
    assert {:error, :unauthorized} = Tenancy.overview(f.scope_a)
    assert {:ok, []} = Tenancy.list_companies(f.token_a)
  end

  test "runtime role is not table owner, cannot bypass RLS or administer identities" do
    assert :ok = OpsBrain.DatabaseSafety.verify!()
    assert_raise Postgrex.Error, fn -> Repo.query!("UPDATE operators SET enabled = false") end

    assert_raise Postgrex.Error, fn ->
      Repo.query!("INSERT INTO memberships SELECT operator_id, company_id FROM memberships")
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!("ALTER TABLE sources DISABLE ROW LEVEL SECURITY")
    end
  end
end
