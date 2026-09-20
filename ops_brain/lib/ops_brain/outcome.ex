defmodule OpsBrain.Outcome do
  @moduledoc """
  Explicit collection outcome contract. Database transactions are normalized
  once here so a committed source failure is never reported to a worker as a
  successful collection. Only genuinely retryable internal failures raise a
  job error; a recorded source failure completes and is re-attempted by the
  periodic source cadence.
  """

  @type t ::
          {:collected, term()}
          | {:deferred, atom(), pos_integer()}
          | {:source_failure, term()}
          | {:invalid, term()}
          | {:retryable, term()}

  @spec normalize(term()) :: t()
  def normalize({:source_failure, reason}), do: {:source_failure, reason}
  def normalize({:ok, {:ok, value}}), do: {:collected, value}
  def normalize({:ok, {:error, reason}}), do: classify(reason)
  def normalize({:ok, :persisted}), do: {:collected, :persisted}
  def normalize({:ok, :ok}), do: {:collected, :ok}
  def normalize({:ok, value}), do: {:collected, value}

  def normalize({:snooze, seconds}) when is_integer(seconds) and seconds > 0,
    do: {:deferred, :busy, seconds}

  def normalize({:snooze, reason, seconds}) when is_integer(seconds) and seconds > 0,
    do: {:deferred, reason, seconds}

  def normalize({:error, reason}), do: classify(reason)
  def normalize(_other), do: {:retryable, :unexpected_outcome}

  @spec to_oban(t()) :: :ok | :discard | {:snooze, pos_integer()} | {:error, term()}
  def to_oban({:collected, _}), do: :ok

  def to_oban({:deferred, _reason, seconds}) when is_integer(seconds) and seconds > 0,
    do: {:snooze, seconds}

  def to_oban({:source_failure, _reason}), do: :ok
  def to_oban({:invalid, _reason}), do: :discard
  def to_oban({:retryable, reason}), do: {:error, reason}

  defp classify(:source_disabled_or_invalid), do: {:invalid, :source_disabled_or_invalid}
  defp classify(:invalid_source_configuration), do: {:invalid, :invalid_source_configuration}
  defp classify(:stale_lease), do: {:deferred, :stale_lease, 5}
  defp classify(:busy), do: {:deferred, :busy, 30}
  defp classify(:source_budget_exhausted), do: {:deferred, :source_budget_exhausted, 30}

  defp classify(reason)
       when reason in [
              :access_denied,
              :invalid_or_unavailable_response,
              :repeated_cursor,
              :invalid_run
            ],
       do: {:source_failure, reason}

  defp classify(reason), do: {:retryable, reason}
end
