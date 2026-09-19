defmodule OpsBrain.Tenancy.Scope do
  @moduledoc "A company selection backed by a session. Revalidated on every data transaction."
  @enforce_keys [:session_token, :company_id]
  @derive {Inspect, except: [:session_token]}
  defstruct [:session_token, :company_id]
end
