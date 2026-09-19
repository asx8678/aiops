defmodule OpsBrain.AccountsTest do
  use OpsBrain.DataCase, async: false
  alias OpsBrain.Accounts.{Operator, Token}

  setup do
    fixture()
  end

  test "login tokens are hashed, single-use and exchanged for revocable sessions", f do
    raw = login_token(f.alice)
    refute Enum.any?(Repo.all(Token), &(&1.token_hash == raw))
    assert {:ok, session} = Accounts.exchange_login_token(raw)
    assert Accounts.operator_for_session(session).id == f.alice.id
    assert {:error, :unauthorized} = Accounts.exchange_login_token(raw)
    assert :ok = Accounts.revoke_session(session)
    assert is_nil(Accounts.operator_for_session(session))
  end

  test "expired, malformed, missing and disabled operator tokens fail closed", f do
    expired = login_token(f.alice, DateTime.add(DateTime.utc_now(), -1, :second))

    for raw <- [expired, nil, "", "invalid", String.duplicate("a", 50_000)] do
      assert {:error, :unauthorized} = Accounts.exchange_login_token(raw)
    end

    raw = login_token(f.alice)

    TestAdminRepo.update_all(from(o in Operator, where: o.id == ^f.alice.id),
      set: [enabled: false]
    )

    assert {:error, :unauthorized} = Accounts.exchange_login_token(raw)
    assert is_nil(Accounts.operator_for_session(f.token_a))
  end

  test "session expiration uses server time and session tokens cannot be used as login tokens",
       f do
    assert {:error, :unauthorized} = Accounts.exchange_login_token(f.token_a)

    assert is_nil(
             Accounts.operator_for_session(f.token_a, DateTime.add(DateTime.utc_now(), 2, :hour))
           )
  end
end
