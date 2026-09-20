defmodule OpsBrain.Redactor do
  @moduledoc "Bound and redact before persistence. Normalization is a separate operation."

  # Assignment-style secrets are matched quoted-first so an entire quoted value
  # (including spaces, delimiters and escaped quotes) is consumed rather than
  # only the first whitespace-delimited fragment. Unterminated quotes redact
  # conservatively to the end of the input; a leaked tail is worse than
  # over-redacting malformed input. Unquoted values stop at whitespace or a
  # delimiter and never absorb a quote character.
  @assignment ~r/(?i)\b(password|passwd|secret|token|api[_-]?key|sig)\s*[=:]\s*("(?:[^"\\]|\\[\s\S])*+(?:"|\\?\z)|'(?:[^'\\]|\\[\s\S])*+(?:'|\\?\z)|[^\s&,;"']+)/
  @max_input_bytes 1_048_576

  def clean(text, max_bytes \\ 4000)

  def clean(text, max_bytes) when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 do
    cond do
      byte_size(text) > @max_input_bytes -> bounded("[input too large]", max_bytes)
      not String.valid?(text) -> bounded("[invalid UTF-8]", max_bytes)
      true -> redact(text, max_bytes)
    end
  end

  def clean(_, max_bytes) when is_integer(max_bytes) and max_bytes >= 0,
    do: bounded("[invalid text]", max_bytes)

  def clean(_, _), do: ""

  defp redact(text, max_bytes) do
    text
    |> String.replace(~r/\e\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(
      ~r/(?i)("(?:password|passwd|secret|token|api[_-]?key|authorization)"\s*:\s*)"(?:[^"\\]|\\.)*"/,
      "\\1\"[REDACTED]\""
    )
    |> String.replace(
      ~r/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)/,
      "[REDACTED PRIVATE KEY]"
    )
    |> String.replace(~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "[REDACTED EMAIL]")
    |> String.replace(
      ~r/(?i)(authorization\s*[:=]\s*(?:(?:bearer|basic)\s+)?|bearer\s+|basic\s+)[^\s,;]+/,
      "[REDACTED]"
    )
    |> String.replace(@assignment, "\\1=[REDACTED]")
    |> String.replace(~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, "[REDACTED]")
    |> String.replace(~r{https?://[^\s/@]+:[^\s/@]+@}, "https://[REDACTED]@")
    |> String.replace(~r{(https?://[^\s?]+)\?[^\s]+}, "\\1?[REDACTED]")
    |> bounded(max_bytes)
  end

  defp bounded(text, max_bytes) do
    # Avoid invalid UTF-8 boundaries, and bound malformed input without persisting it.
    if String.valid?(text) do
      text
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn ch, {acc, n} ->
        if n + byte_size(ch) <= max_bytes,
          do: {:cont, {[ch | acc], n + byte_size(ch)}},
          else: {:halt, {acc, n}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    else
      "[invalid UTF-8]"
    end
  end
end
