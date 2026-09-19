defmodule OpsBrain.Fingerprints do
  @moduledoc "Reviewed exact matching v1; similarity is never causal proof."
  alias OpsBrain.{Redactor, Store}
  @version 1
  def version, do: @version

  def classify(text) do
    text = Redactor.clean(text)

    cond do
      Regex.match?(~r/\b(?:HTTP|status|response)\s*[:=]?\s*401\b/i, text) ->
        "authentication_rejection"

      Regex.match?(~r/\b(?:HTTP|status|response)\s*[:=]?\s*403\b/i, text) ->
        "authorization_denial"

      Regex.match?(~r/\b(?:ENOTFOUND|EAI_AGAIN|NXDOMAIN)\b/, text) ->
        "dns_resolution"

      Regex.match?(~r/\b(?:ETIMEDOUT|ECONNREFUSED)\b/, text) ->
        "connection_failure"

      Regex.match?(~r/\b(?:ENOSPC|No space left on device)\b/, text) ->
        "disk_space"

      Regex.match?(~r/\b(?:CS\d{4}|TS\d{4}|NU\d{4})\b/, text) ->
        "tool_error"

      Regex.match?(~r/\bSQLSTATE\s*[:=]?\s*[A-Z0-9]{5}\b/, text) ->
        "database_error"

      true ->
        "unclassified"
    end
  end

  def normalize(text) do
    text
    |> Redactor.clean()
    |> String.replace(
      ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i,
      "<id>"
    )
    |> String.replace(~r/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b/, "<time>")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def identify(company, scope, tool, text) do
    normalized = normalize(text)

    %{
      fingerprint: Store.digest({company, scope, tool, classify(text), normalized, @version}),
      parser_version: @version,
      template: normalized,
      classification: classify(text),
      reason: "exact normalized template, tool and scope; not confirmed common cause"
    }
  end
end
