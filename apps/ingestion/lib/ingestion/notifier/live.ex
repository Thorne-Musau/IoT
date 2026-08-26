defmodule Ingestion.Notifier.Live do
  @moduledoc """
  Real outbound delivery via Microsoft Graph (Outlook) and a Power Automate
  Workflow webhook (Teams).

  **This module is never exercised in dev or test.** `config/dev.exs` and
  `config/test.exs` pin `Ingestion.Notifier.Local`, and
  `Ingestion.Notifier.impl/0` refuses to return this module under
  `Mix.env() in [:dev, :test]` even if config says otherwise. It is
  selected only by `NOTIFIER=live` in a production release.

  ## Outlook — Microsoft Graph `sendMail`

  OAuth 2.0 **client credentials** flow against
  `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token` with scope
  `https://graph.microsoft.com/.default`, then
  `POST /v1.0/users/{sender}/sendMail`. This needs the **`Mail.Send`
  application permission** (not delegated) with tenant admin consent, and
  sends from a configured shared mailbox.

  Tokens are cached in a small Agent until shortly before expiry — Graph
  issues app tokens with roughly a one-hour lifetime and re-requesting one
  per alert would be both slow and rate-limit-prone.

  ## Teams — Power Automate Workflow webhook

  A plain `POST` of an **Adaptive Card** to the Workflow URL. The legacy
  Office 365 Incoming Webhook connector (`MessageCard` format) is retired
  and is deliberately not implemented.

  HTTP uses OTP's built-in `:httpc` rather than adding an HTTP client
  dependency for a code path the test suite never runs.
  """

  @behaviour Ingestion.Notifier

  alias Ingestion.Notifier.Alert

  @token_agent __MODULE__.TokenCache
  @graph_host "https://graph.microsoft.com"
  @login_host "https://login.microsoftonline.com"
  @token_skew_seconds 120
  @request_timeout_ms 15_000

  @impl true
  def deliver(:outlook, %Alert{} = alert) do
    with {:ok, token} <- access_token(),
         {:ok, sender} <- graph_config(:sender_mailbox),
         {:ok, recipients} <- recipients() do
      body =
        %{
          "message" => %{
            "subject" => alert.subject,
            "body" => %{"contentType" => "HTML", "content" => Alert.to_html(alert)},
            "toRecipients" =>
              Enum.map(recipients, fn address ->
                %{"emailAddress" => %{"address" => address}}
              end)
          },
          "saveToSentItems" => true
        }

      url = "#{@graph_host}/v1.0/users/#{URI.encode(sender)}/sendMail"

      case post_json(url, body, [{~c"authorization", ~c"Bearer #{token}"}]) do
        {:ok, status, _} when status in 200..299 -> :ok
        {:ok, status, response} -> {:error, {:graph_send_failed, status, response}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def deliver(:teams, %Alert{} = alert) do
    with {:ok, webhook_url} <- teams_config(:workflow_webhook_url) do
      case post_json(webhook_url, Alert.to_adaptive_card(alert), []) do
        {:ok, status, _} when status in 200..299 -> :ok
        {:ok, status, response} -> {:error, {:teams_post_failed, status, response}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  ## Graph token handling

  @doc false
  def child_spec(_opts) do
    %{
      id: @token_agent,
      start: {Agent, :start_link, [fn -> nil end, [name: @token_agent]]}
    }
  end

  defp access_token do
    case cached_token() do
      nil -> fetch_and_cache_token()
      token -> {:ok, token}
    end
  end

  defp cached_token do
    if Process.whereis(@token_agent) do
      Agent.get(@token_agent, fn
        %{token: token, expires_at: expires_at} ->
          if DateTime.compare(DateTime.utc_now(), expires_at) == :lt, do: token

        _ ->
          nil
      end)
    end
  end

  defp fetch_and_cache_token do
    with {:ok, tenant_id} <- graph_config(:tenant_id),
         {:ok, client_id} <- graph_config(:client_id),
         {:ok, client_secret} <- graph_config(:client_secret) do
      form =
        URI.encode_query(%{
          "client_id" => client_id,
          "client_secret" => client_secret,
          "scope" => "#{@graph_host}/.default",
          "grant_type" => "client_credentials"
        })

      url = "#{@login_host}/#{URI.encode(tenant_id)}/oauth2/v2.0/token"

      request =
        {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded",
         String.to_charlist(form)}

      case :httpc.request(:post, request, http_opts(), body_format: :binary) do
        {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
          decoded = Jason.decode!(body)
          token = Map.fetch!(decoded, "access_token")
          expires_in = Map.get(decoded, "expires_in", 3600)

          cache_token(token, expires_in)
          {:ok, token}

        {:ok, {{_, status, _}, _headers, body}} ->
          {:error, {:graph_token_failed, status, body}}

        {:error, reason} ->
          {:error, {:graph_token_request_failed, reason}}
      end
    end
  end

  defp cache_token(token, expires_in) do
    if Process.whereis(@token_agent) do
      expires_at = DateTime.add(DateTime.utc_now(), expires_in - @token_skew_seconds, :second)
      Agent.update(@token_agent, fn _ -> %{token: token, expires_at: expires_at} end)
    end
  end

  ## HTTP

  defp post_json(url, body, extra_headers) do
    request =
      {String.to_charlist(url), extra_headers, ~c"application/json",
       body |> Jason.encode!() |> String.to_charlist()}

    case :httpc.request(:post, request, http_opts(), body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, {:http_request_failed, reason}}
    end
  end

  defp http_opts do
    [
      timeout: @request_timeout_ms,
      connect_timeout: @request_timeout_ms,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  ## Config

  defp graph_config(key) do
    case Application.get_env(:ingestion, :graph, []) |> Keyword.get(key) do
      nil -> {:error, {:missing_config, :graph, key}}
      value -> {:ok, value}
    end
  end

  defp teams_config(key) do
    case Application.get_env(:ingestion, :teams, []) |> Keyword.get(key) do
      nil -> {:error, {:missing_config, :teams, key}}
      value -> {:ok, value}
    end
  end

  defp recipients do
    case Application.get_env(:ingestion, :graph, []) |> Keyword.get(:recipients, []) do
      [] -> {:error, {:missing_config, :graph, :recipients}}
      list -> {:ok, list}
    end
  end
end
