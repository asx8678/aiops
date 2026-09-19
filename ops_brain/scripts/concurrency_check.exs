# MIX_ENV=test mix run --no-start scripts/concurrency_check.exs --disposable
# Destructive synthetic benchmark: requires explicit opt-in and isolated test database URLs.
if System.argv() != ["--disposable"] or System.get_env("OPS_BRAIN_DISPOSABLE_TEST") != "true",
  do: raise("Requires --disposable and OPS_BRAIN_DISPOSABLE_TEST=true; truncates test tables")

for name <- ["DATABASE_URL", "MIGRATION_DATABASE_URL"] do
  uri = System.fetch_env!(name) |> URI.parse()
  unless String.starts_with?(uri.path || "", "/ops_brain_test"), do: raise("Dedicated test database required")
end

cfg = Application.fetch_env!(:ops_brain, OpsBrain.Repo)
Application.put_env(:ops_brain, OpsBrain.Repo, Keyword.put(cfg, :pool_size, 4))
{:ok, _} = Application.ensure_all_started(:ops_brain)
{:ok, _} = OpsBrain.TestAdminRepo.start_link(Application.fetch_env!(:ops_brain, OpsBrain.TestAdminRepo))
import ExUnit.Assertions
alias OpsBrain.{Repo, Store, Tenancy, Evidence, Issues, SourceConfig, Budgets}
OpsBrain.Fixtures.clean!()
f = OpsBrain.Fixtures.fixture()
a = OpsBrain.SourceFixtures.config(f, :a, %{requests_per_minute: 1})
b = OpsBrain.SourceFixtures.config(f, :b, %{requests_per_minute: 10})
now = DateTime.utc_now()

try do
  # A saturated source cannot reserve B's budget. No upstream network is contacted.
  assert {:ok,{:reserved,reservation}} = Budgets.reserve(a.id,now)
  assert {:error,:source_budget_exhausted} = Budgets.reserve(a.id,now)
  assert {:ok,{:reserved,_}} = Budgets.reserve(b.id,now)
  Budgets.finish(a.id,reservation,{:ok,%{bytes: 0,headers: %{},status: 200}},now)

  work = Enum.map(1..200,&{a,f.scope_a,&1}) ++ Enum.map(1..40,&{b,f.scope_b,&1})
  # Interleave companies deterministically without random success/latency selection.
  work = Enum.sort_by(work,fn {c,_,n} -> {n,c.id} end)
  started = System.monotonic_time(:microsecond)
  results = Task.async_stream(work,fn {c,scope,n} ->
    {us,result} = :timer.tc(fn ->
      SourceConfig.transaction(c.id,fn trusted ->
        Evidence.failure(trusted,"concurrent:#{n}",%{"issues" => ["HTTP 401"],"tool" => "synthetic","attempt" => 1},n,now)
      end)
    end)
    assert {:ok,_} = result
    assert {:ok,%{company: company}} = Tenancy.overview(scope)
    assert company.id == c.company_id
    %{rows: [[context,pid]]} = Repo.query!("SELECT current_setting('ops_brain.company_id',true),pg_backend_pid()")
    assert context in [nil, ""]
    {c.company_id,us,pid}
  end,max_concurrency: 8,timeout: 30_000,ordered: false) |> Enum.map(fn {:ok,r} -> r end)
  elapsed = System.monotonic_time(:microsecond)-started
  assert {:ok,[%{"occurrences" => 200,"distinct_runs" => 200}]} = Issues.list(f.scope_a)
  assert {:ok,[%{"occurrences" => 40,"distinct_runs" => 40}]} = Issues.list(f.scope_b)
  assert {:ok,%{"n" => 0}} = Tenancy.with_scope(f.scope_b,fn -> Store.one("SELECT count(*)::integer AS n FROM issue_groups WHERE company_id=$1::text::uuid",[f.a.id]) end)
  pids = Enum.map(results,&elem(&1,2)) |> Enum.uniq()
  assert length(pids) > 1
  measurements = Map.new([a.company_id,b.company_id],fn id ->
    times = Enum.filter(results,&(elem(&1,0)==id)) |> Enum.map(&elem(&1,1)) |> Enum.sort()
    percentile = fn q -> Enum.at(times,ceil(length(times)*q)-1)/1000 end
    {id,%{transactions: length(times),p50_ms: percentile.(0.5),p95_ms: percentile.(0.95),p99_ms: percentile.(0.99)}}
  end)
  IO.puts(Jason.encode!(%{synthetic: true,pool_size: 4,concurrency: 8,physical_connections_observed: length(pids),
    elapsed_ms: elapsed/1000,companies: measurements,method: "nearest-rank transaction latency; local DB and grouping only, not upstream production load"},pretty: true))
after
  OpsBrain.SourceFixtures.cleanup()
  OpsBrain.Fixtures.clean!()
end
