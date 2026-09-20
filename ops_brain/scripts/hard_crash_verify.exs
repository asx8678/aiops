{:ok, _} = Application.ensure_all_started(:ops_brain)
{:ok, _} = OpsBrain.TestAdminRepo.start_link()
OpsBrain.Fixtures.verify_disposable!()

{c, stale, now, _pid} =
  File.read!(System.fetch_env!("OPS_BRAIN_MARKER")) |> :erlang.binary_to_term()

Application.put_env(:ops_brain, :sources, %{c.id => c})
Application.put_env(:ops_brain, :collection_enabled, true)
import ExUnit.Assertions
alias OpsBrain.Collection
assert {:ok, :busy} = Collection.claim(c.id, now)
later = DateTime.add(now, 46)
assert {:ok, {:claimed, fresh}} = Collection.claim(c.id, later)
assert fresh["fence"] > stale["fence"]
assert {:error, :stale_lease} = Collection.persist(c, stale, [], nil, 0, later, 30)
assert {:ok, :persisted} = Collection.persist(c, fresh, [], nil, 0, later, 30)
assert {:error, :stale_lease} = Collection.persist(c, fresh, [], nil, 0, later, 30)
OpsBrain.Fixtures.clean!()

IO.puts(
  "CRASH_VERIFY_OK: busy before expiry; takeover; stale rejection; fresh commit; duplicate rejection"
)
