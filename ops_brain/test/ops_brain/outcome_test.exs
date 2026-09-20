defmodule OpsBrain.OutcomeTest do
  use ExUnit.Case, async: true
  alias OpsBrain.Outcome

  test "a committed source failure is not reported as a successful collection" do
    assert Outcome.normalize({:ok, {:error, :access_denied}}) == {:source_failure, :access_denied}
    assert Outcome.normalize({:ok, {:error, :boom}}) == {:retryable, :boom}
  end

  test "worker mapping is deliberate for every branch" do
    assert Outcome.to_oban(Outcome.normalize({:ok, :persisted})) == :ok
    assert Outcome.to_oban(Outcome.normalize({:snooze, 30})) == {:snooze, 30}
    assert Outcome.to_oban(Outcome.normalize({:error, :source_disabled_or_invalid})) == :discard
    assert Outcome.to_oban(Outcome.normalize({:error, :stale_lease})) == {:snooze, 5}
    assert Outcome.to_oban(Outcome.normalize({:ok, {:error, :access_denied}})) == :ok

    assert Outcome.to_oban(Outcome.normalize({:error, :some_internal})) ==
             {:error, :some_internal}
  end
end
