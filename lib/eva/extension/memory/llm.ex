defmodule Eva.Extension.Memory.LLM do
  @moduledoc """
  This node's own provider client.

  Eva's `Eva.AI.OpenAICompatibleProvider` lives in the host application, not in
  `eva_core`, so an extension cannot call it — `ctx.provider_config` arrives as data
  with no client attached. That is fine, because this node does not want what that
  client does: it needs one blocking request/response, not a streamed turn wired into
  a harness.

  Two calls, both OpenAI-compatible:

    * `complete/2` — chat completions, non-streaming. Used by the distiller.
    * `embed/2` — embeddings. Used only when the `:embedding` retrieval backend is on.

  Credentials resolve the same way Eva's `Eva.AI.Auth` resolves them: config first,
  and a `{:system, "VAR"}` tuple reads the environment at call time rather than at
  compile time, so a release picks up the key from wherever it actually runs.
  """

  @type message :: %{role: String.t(), content: String.t()}

  @doc """
  Sends a non-streaming chat completion and returns the assistant's text.

  `opts` overrides anything in the `:distiller` config — `:model`, `:base_url`,
  `:api_key`, `:timeout_ms`, `:temperature`, `:system`.
  """
  @spec complete([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    conf = config(:distiller, opts)

    body =
      %{
        model: conf.model,
        messages: prepend_system(messages, opts[:system]),
        stream: false
      }
      |> maybe_put(:temperature, opts[:temperature])

    case post(conf, "/chat/completions", body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Embeds one or more strings.

  Returns a list of vectors in the same order as the input. Note that the default
  `:distiller` provider (opencode go) does **not** serve this endpoint — it 404s. This
  exists for whatever you point `:embedding` at once you have something that does.
  """
  @spec embed([String.t()] | String.t(), keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(input, opts \\ [])
  def embed(input, opts) when is_binary(input), do: embed([input], opts)

  def embed(inputs, opts) when is_list(inputs) do
    conf = config(:embedding, opts)

    case post(conf, "/embeddings", %{model: conf.model, input: inputs}) do
      {:ok, %{"data" => data}} when is_list(data) ->
        vectors =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        if Enum.all?(vectors, &is_list/1),
          do: {:ok, vectors},
          else: {:error, {:unexpected_response, data}}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Private --

  defp post(conf, path, body) do
    url = String.trim_trailing(conf.base_url, "/") <> path

    Req.post(url,
      json: body,
      headers: headers(conf.api_key),
      receive_timeout: conf.timeout_ms,
      retry: conf.retry,
      max_retries: conf.max_retries
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        # A 404 here is the interesting one: it usually means the endpoint is not
        # served at all (opencode go and /embeddings), not that a model is missing.
        {:error, {:http_error, status, truncate(body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp headers(nil), do: [{"content-type", "application/json"}]

  defp headers(api_key) when is_binary(api_key) do
    case String.trim(api_key) do
      "" -> headers(nil)
      key -> [{"content-type", "application/json"}, {"authorization", "Bearer " <> key}]
    end
  end

  defp config(key, opts) do
    base = Application.get_env(:eva_memory, key, [])

    %{
      base_url: opts[:base_url] || base[:base_url] || raise("no base_url for #{key}"),
      api_key: resolve_key(opts[:api_key] || base[:api_key]),
      model: opts[:model] || base[:model] || raise("no model for #{key}"),
      timeout_ms: opts[:timeout_ms] || base[:timeout_ms] || 60_000,
      retry: Keyword.get(opts, :retry, Keyword.get(base, :retry, :transient)),
      max_retries: Keyword.get(opts, :max_retries, Keyword.get(base, :max_retries, 2))
    }
  end

  # Read the environment when the call happens, not when the config was compiled.
  defp resolve_key({:system, var}), do: System.get_env(var)
  defp resolve_key(other), do: other

  defp prepend_system(messages, nil), do: messages
  defp prepend_system(messages, system), do: [%{role: "system", content: system} | messages]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp truncate(body), do: body |> inspect() |> String.slice(0, 200)
end
