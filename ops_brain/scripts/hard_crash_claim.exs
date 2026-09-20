# Invoked only by the disposable hard-crash shell harness.
{:ok, _} = Application.ensure_all_started(:ops_brain)
{:ok, _} = OpsBrain.TestAdminRepo.start_link()
OpsBrain.Fixtures.clean!()
f = OpsBrain.Fixtures.fixture()
c = OpsBrain.SourceFixtures.config(f)
now = DateTime.utc_now()
{:ok, {:claimed, state}} = OpsBrain.Collection.claim(c.id, now)
# Persist synthetic configuration and the actual BEAM PID for the separate verifier.
File.write!(
  System.fetch_env!("OPS_BRAIN_MARKER"),
  :erlang.term_to_binary({c, state, now, System.pid()})
)

File.write!(System.fetch_env!("OPS_BRAIN_MARKER") <> ".pid", System.pid())
Process.sleep(:infinity)
