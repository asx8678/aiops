defmodule OpsBrain.RedactorTest do
  use ExUnit.Case, async: true

  alias OpsBrain.Redactor

  # Every token here is a synthetic marker. Acceptance is that no marked
  # fragment survives, not merely that the placeholder appears.
  @assignment_cases [
    {~s(password="CANARY_A1 alpha beta"), ["CANARY_A1", "alpha", "beta"]},
    {~s(token="CANARY_B1 alpha,CANARY_B2 beta"), ["CANARY_B1", "CANARY_B2"]},
    {~s(secret='CANARY_C1 alpha;CANARY_C2 beta'), ["CANARY_C1", "CANARY_C2"]},
    {~S(api_key="CANARY_D1 escaped\"quote CANARY_D2 tail"), ["CANARY_D1", "CANARY_D2"]},
    {~s(password="CANARY_E1 multiline CANARY_E2\nsecond line CANARY_E3"),
     ["CANARY_E1", "CANARY_E2", "CANARY_E3"]},
    {~s(password="CANARY_F1 unterminated CANARY_F2 tail), ["CANARY_F1", "CANARY_F2"]}
  ]

  test "the whole quoted assignment value is redacted, not only its first fragment" do
    for {text, fragments} <- @assignment_cases do
      clean = Redactor.clean(text)

      for fragment <- fragments do
        refute clean =~ fragment,
               "leaked #{inspect(fragment)} from #{inspect(text)} as #{inspect(clean)}"
      end

      assert clean =~ "[REDACTED]"
    end
  end

  test "dangling escapes and escaped newlines cannot leak malformed quoted values" do
    for quote <- ["\"", "'"] do
      for tail <- ["\\", "\\\nCANARY_AFTER_NEWLINE", "\\\r\nCANARY_AFTER_CRLF"] do
        input = "password=" <> quote <> "CANARY_BEFORE_ESCAPE " <> tail
        refute Redactor.clean(input) =~ "CANARY_"
      end
    end
  end

  test "mixed case, multiple secrets and quote styles are all redacted" do
    text =
      ~s(PaSsWoRd="CANARY_M1 alpha CANARY_M2" token='CANARY_M3 beta' api_key=plain_CANARY_M4)

    clean = Redactor.clean(text)
    refute clean =~ "CANARY_M"
    assert clean =~ "PaSsWoRd=[REDACTED]"
    assert clean =~ "token=[REDACTED]"
    assert clean =~ "api_key=[REDACTED]"
  end

  test "redaction is idempotent and leaves benign text untouched" do
    clean = Redactor.clean(~s(password="CANARY_IDEMPOTENT alpha"))

    assert Redactor.clean(clean) == clean

    benign = "disk usage 91% on node-7; retry in 30s"
    assert Redactor.clean(benign) == benign
  end

  test "empty, nonbinary and malformed input are bounded safely" do
    assert Redactor.clean("") == ""
    assert Redactor.clean(<<255>>) == "[invalid UTF-8]"
    assert Redactor.clean(nil) == "[invalid text]"
    assert byte_size(Redactor.clean(String.duplicate("é", 5000), 99)) <= 99
  end

  test "output limits include error markers and oversized input is rejected without truncating secrets" do
    for input <- [nil, <<255>>, String.duplicate("é", 600_000)], cap <- [0, 1, 9, 99] do
      output = Redactor.clean(input, cap)
      assert String.valid?(output)
      assert byte_size(output) <= cap
    end

    assert Redactor.clean(String.duplicate("a", 1_048_577)) == "[input too large]"
    assert Redactor.clean("benign", -1) == ""
    assert Redactor.clean("benign", nil) == ""
  end

  test "existing authorization JSON private-key URL JWT email and ANSI safeguards remain" do
    for input <- [
          ~s({"token":"CANARY_JSON tail"}),
          "Authorization: Bearer CANARY_AUTH",
          "-----BEGIN PRIVATE KEY-----\nCANARY_KEY\n-----END PRIVATE KEY-----",
          "https://user:CANARY_PASSWORD@example.test/path",
          "https://example.test/path?credential=CANARY_QUERY",
          "CANARY_EMAIL@example.test"
        ] do
      refute Redactor.clean(input) =~ "CANARY_"
    end

    refute Redactor.clean("eyJabc.abcdef.ghijkl") =~ "eyJabc"
    assert Redactor.clean("\e[31mHTTP 403\e[0m") == "HTTP 403"
  end

  test "an unterminated quoted value cannot leak into later fields of the same line" do
    clean = Redactor.clean(~s(password="CANARY_TAIL then unrelated=ok))
    refute clean =~ "CANARY_TAIL"
    refute clean =~ "unrelated=ok"
  end
end
