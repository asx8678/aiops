defmodule OpsBrain.Notifications do
  @moduledoc "Separately approved fixed destinations only. Dashboard remains functional without delivery. Ambiguous outcomes are not silently retried."
  alias OpsBrain.{Store, Repo, SourceConfig}
  def sinks, do: Application.get_env(:ops_brain, :notification_sinks, %{})

  def prepare(c, group_id, now) do
    g =
      Store.one("SELECT revision,severity FROM issue_groups WHERE id=$1::text::uuid", [group_id])

    for {destination, sink} <- sinks(), approved?(sink, c.company_id) do
      last =
        Store.one(
          "SELECT updated_at FROM notification_outbox WHERE group_id=$1::text::uuid AND destination=$2 AND status='delivered' ORDER BY updated_at DESC LIMIT 1",
          [group_id, destination]
        )

      at = if g["severity"] == "critical", do: now, else: due(now, last, sink)

      pending =
        Store.one(
          "SELECT id::text,next_at,attempts FROM notification_outbox WHERE group_id=$1::text::uuid AND destination=$2 AND status='pending' ORDER BY next_at LIMIT 1 FOR UPDATE",
          [group_id, destination]
        )

      {pending, at} =
        if pending && pending["attempts"] >= 3 do
          Repo.query!(
            "UPDATE notification_outbox SET status='retry_exhausted' WHERE id=$1::text::uuid",
            [pending["id"]]
          )

          {nil, Enum.max_by([at, pending["next_at"]], &DateTime.to_unix/1)}
        else
          {pending, at}
        end

      if pending do
        # Keep provider Retry-After once a send has been attempted; otherwise keep the first digest deadline through a continuous burst; update payload revision, not the delivery identity.
        at =
          if pending["attempts"] > 0,
            do: pending["next_at"],
            else: Enum.min_by([pending["next_at"], at], &DateTime.to_unix/1)

        Repo.query!(
          "UPDATE notification_outbox SET revision=$2,next_at=$3,updated_at=$4 WHERE id=$1::text::uuid",
          [pending["id"], g["revision"], at, now]
        )

        Repo.query!(
          "UPDATE oban_jobs SET scheduled_at=LEAST(scheduled_at,$2) WHERE worker='OpsBrain.NotificationWorker' AND args->>'id'=$1 AND state IN ('scheduled','available','retryable')",
          [pending["id"], at]
        )
      end

      row =
        if pending,
          do: nil,
          else:
            Store.one(
              "INSERT INTO notification_outbox(id,company_id,source_id,group_id,revision,destination,next_at,updated_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6,$7,$8) ON CONFLICT DO NOTHING RETURNING id::text",
              [
                Ecto.UUID.generate(),
                c.company_id,
                c.id,
                group_id,
                g["revision"],
                destination,
                at,
                now
              ]
            )

      if row do
        %{source_id: c.id, id: row["id"]}
        |> OpsBrain.NotificationWorker.new(scheduled_at: at)
        |> Oban.insert!()
      end
    end
  end

  def approved?(sink, company),
    do:
      sink[:approved] == true and sink[:enabled] == true and sink[:company_id] == company and
        is_binary(sink[:url]) and is_binary(sink[:credential_env]) and
        not Enum.any?(SourceConfig.all(), fn {_, source} ->
          source[:credential_env] == sink[:credential_env]
        end) and
        length(Map.get(sink, :quiet_utc_hours, [])) < 24 and
        Enum.all?(Map.get(sink, :quiet_utc_hours, []), &(&1 in 0..23)) and
        Map.get(sink, :cooldown_seconds, 300) in 0..86400 and
        Map.get(sink, :digest_seconds, 60) in 0..86400

  def due(now, last, sink) do
    candidate =
      if last,
        do:
          Enum.max_by(
            [now, DateTime.add(last["updated_at"], Map.get(sink, :cooldown_seconds, 300))],
            &DateTime.to_unix/1
          ),
        else: DateTime.add(now, Map.get(sink, :digest_seconds, 60))

    quiet = Map.get(sink, :quiet_utc_hours, [])

    Enum.reduce_while(0..24, candidate, fn _, t ->
      if t.hour in quiet, do: {:cont, DateTime.add(t, 3600)}, else: {:halt, t}
    end)
  end

  def deliver(source, id, now \\ Store.now()) do
    with true <- Application.get_env(:ops_brain, :delivery_enabled, false),
         {:ok, {%{} = row, %{} = sink}} <-
           SourceConfig.transaction(source, fn c -> claim(c, id, now) end) do
      result = send_message(row, sink)

      case result do
        {:retry, delay} ->
          case SourceConfig.transaction(source, fn _ ->
                 Repo.query!(
                   "UPDATE notification_outbox SET status='pending',next_at=$2,updated_at=$3 WHERE id=$1::text::uuid AND status='delivering'",
                   [id, DateTime.add(Store.now(), delay), Store.now()]
                 )
               end) do
            {:ok, _} -> {:snooze, delay}
            error -> error
          end

        status ->
          SourceConfig.transaction(source, fn _ ->
            Repo.query!(
              "UPDATE notification_outbox SET status=$2,updated_at=$3 WHERE id=$1::text::uuid AND status='delivering'",
              [id, to_string(status), Store.now()]
            )
          end)
      end
    else
      false -> {:error, :delivery_disabled}
      error -> error
    end
  end

  defp claim(c, id, now) do
    row =
      Store.one(
        "SELECT o.id::text,o.group_id::text,o.revision,o.destination,o.status,o.attempts,o.next_at,g.revision AS current_revision,g.severity,g.data,g.status AS group_status,g.snoozed_until FROM notification_outbox o JOIN issue_groups g ON g.id=o.group_id AND g.company_id=o.company_id WHERE o.id=$1::text::uuid AND o.source_id=$2::text::uuid FOR UPDATE OF o",
        [id, c.id]
      )

    if row == nil, do: Repo.rollback(:not_found)
    sink = Map.get(sinks(), row["destination"], %{})

    cond do
      not approved?(sink, c.company_id) ->
        Repo.rollback(:destination_not_approved)

      row["status"] == "delivering" ->
        Repo.query!(
          "UPDATE notification_outbox SET status='ambiguous',updated_at=$2 WHERE id=$1::text::uuid",
          [id, now]
        )

        {:skip, :ambiguous_previous_attempt}

      row["attempts"] >= 3 and row["status"] == "pending" ->
        Repo.query!(
          "UPDATE notification_outbox SET status='retry_exhausted' WHERE id=$1::text::uuid",
          [id]
        )

        {:skip, :retry_exhausted}

      row["status"] != "pending" ->
        Repo.rollback(:not_pending)

      row["revision"] < row["current_revision"] ->
        Repo.query!(
          "UPDATE notification_outbox SET status='coalesced',updated_at=$2 WHERE id=$1::text::uuid",
          [id, now]
        )

        {:skip, :coalesced}

      row["snoozed_until"] != nil and DateTime.compare(row["snoozed_until"], now) == :gt ->
        Repo.rollback(:not_due)

      DateTime.compare(row["next_at"], now) == :gt ->
        Repo.rollback(:not_due)

      true ->
        Repo.query!(
          "UPDATE notification_outbox SET status='delivering',attempts=attempts+1,updated_at=$2 WHERE id=$1::text::uuid",
          [id, now]
        )

        {row, sink}
    end
  end

  @doc "Scoped local notification state for a finding. Never exposes global Oban arguments."
  def status(scope, group_id) do
    with {:ok, _} <- Ecto.UUID.cast(group_id) do
      OpsBrain.Tenancy.with_scope(scope, fn ->
        Store.rows(
          "SELECT id::text,destination,status,attempts,next_at,updated_at FROM notification_outbox WHERE group_id=$1::text::uuid ORDER BY updated_at DESC,id DESC LIMIT 20",
          [group_id]
        )
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp send_message(row, sink) do
    uri = URI.parse(sink.url)

    with true <-
           uri.scheme == "https" and uri.userinfo == nil and uri.query == nil and
             uri.fragment == nil,
         true <- sink.url in Map.get(sink, :approved_urls, []),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(sink[:approved_ip] || "")),
         token when is_binary(token) <- System.get_env(sink.credential_env) do
      pinned = %{uri | host: ip |> :inet.ntoa() |> to_string()}

      headers = [
        {"host", uri.host},
        {"authorization", "Bearer " <> token},
        {"idempotency-key", row["id"]}
      ]

      # No source text controls the URL, recipient, headers or executable behavior.
      options = [
        url: URI.to_string(pinned),
        headers: headers,
        connect_options: [hostname: uri.host, timeout: 5_000],
        receive_timeout: 10_000,
        request_timeout: 15_000,
        retry: false,
        redirect: false,
        json: %{
          notice_id: row["group_id"],
          revision: row["revision"],
          severity: row["severity"],
          status: row["group_status"],
          text: OpsBrain.Redactor.clean(row["data"]["template"], 1000)
        },
        into: fn {:data, _}, {req, resp} -> {:halt, {req, resp}} end
      ]

      options =
        case Application.get_env(:ops_brain, :notification_plug) do
          nil -> options
          plug -> Keyword.put(options, :plug, plug)
        end

      case Req.post(options) do
        {:ok, %{status: status}} when status in 200..299 ->
          :delivered

        {:ok, %{status: 429, headers: headers}} ->
          {:retry, max(30, OpsBrain.Transport.retry_seconds(headers, Store.now()))}

        {:ok, %{status: status}} when status in [400, 401, 403, 404] ->
          :rejected

        _ ->
          :ambiguous
      end
    else
      _ -> :rejected
    end
  end
end
