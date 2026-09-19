defmodule OpsBrain.Redactor do
  @moduledoc "Bound and redact before persistence. Normalization is a separate operation."
  def clean(text, max_bytes \\ 4000)

  def clean(text, max_bytes) when is_binary(text) do
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
    |> String.replace(
      ~r/(?i)(password|passwd|secret|token|api[_-]?key|sig)\s*[=:]\s*([^\s&,;]+|"[^"]*")/,
      "\\1=[REDACTED]"
    )
    |> String.replace(~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, "[REDACTED]")
    |> String.replace(~r{https?://[^\s/@]+:[^\s/@]+@}, "https://[REDACTED]@")
    |> String.replace(~r{(https?://[^\s?]+)\?[^\s]+}, "\\1?[REDACTED]")
    |> bounded(max_bytes)
  end

  def clean(_, _), do: "[invalid text]"

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
