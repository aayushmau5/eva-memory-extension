defmodule Eva.Extension.Memory.Retrieval.Embedding do
  @moduledoc """
  Cosine similarity over stored vectors.

  Usable as a backend on its own (`backend: :embedding`), but `:hybrid` is the default
  and strictly better — see `Eva.Extension.Memory.Retrieval`.

  Vectors come from a local embedding model, not from the distiller's provider:

      ollama pull nomic-embed-text

  Two things to know:

    * **Memories written while no embedding endpoint was reachable have no vector** and
      are invisible to this backend. `Distiller.backfill_vectors/0` embeds them in one
      pass, and hybrid retrieval finds them lexically in the meantime.

    * **The query embedding is a network call inside a hook.** On timeout or error this
      returns `[]` rather than raising, which hybrid reads as "lexical only". A turn
      with slightly worse memories beats a turn that stalled.
  """

  @behaviour Eva.Extension.Memory.Retrieval

  require Logger

  alias Eva.Extension.Memory.LLM

  @impl true
  def search(query, memories, _opts), do: rank(query, memories)

  @doc """
  Ranks memories against the query by cosine similarity, above the floor.

  Returns `[]` — never raises — when the endpoint is unavailable, nothing has a vector
  yet, or nothing clears `:min_cosine`. Callers treat all three as "no vector signal".
  """
  @spec rank(String.t(), [map()]) :: [Eva.Extension.Memory.Retrieval.hit()]
  def rank(query, memories) do
    embedded = Enum.filter(memories, &is_list(&1["vector"]))

    if embedded == [] do
      []
    else
      case embed_query(query) do
        {:ok, [vector | _]} ->
          score_all(vector, embedded)

        {:error, reason} ->
          Logger.debug("[memory] no vector signal this turn: #{inspect(reason)}")
          []
      end
    end
  end

  # A seam for tests, which need the vector path to run without a live endpoint —
  # otherwise the floor below can only be verified by hand against a running Ollama.
  defp embed_query(query) do
    opts = [retry: false, max_retries: 0]

    case Application.get_env(:eva_memory, :embedder) do
      fun when is_function(fun, 2) -> fun.(query, opts)
      fun when is_function(fun, 1) -> fun.(query)
      # This runs inside Eva's context-hook deadline. One quick attempt is enough;
      # hybrid retrieval already has a lexical result ready when it fails.
      _ -> LLM.embed(query, opts)
    end
  end

  defp score_all(query_vector, memories) do
    case norm(query_vector) do
      query_norm when query_norm == 0.0 ->
        []

      query_norm ->
        floor = min_cosine()

        memories
        |> Enum.map(fn memory ->
          %{memory: memory, score: cosine(query_vector, memory["vector"], query_norm)}
        end)
        |> Enum.filter(&(&1.score >= floor))
        |> Enum.sort_by(& &1.score, :desc)
    end
  end

  # The floor is the whole difference between a memory layer and a random-fact
  # generator, because cosine similarity has no zero: unrelated text does not score 0,
  # it scores whatever the model's background similarity happens to be.
  #
  # Measured on nomic-embed-text against this corpus: genuinely related queries land at
  # 0.65-0.68, unrelated ones ("what is the capital of France") at 0.36-0.41. 0.55 sits
  # in the gap with room either side. **Recalibrate after changing embedding models** —
  # the number is a property of the model, not of the code.
  defp min_cosine do
    Application.get_env(:eva_memory, :embedding, [])[:min_cosine] || 0.55
  end

  # Guards against a stored vector from a different embedding model — dimensions that
  # do not match are not comparable, and zipping them would silently score garbage.
  defp cosine(a, b, a_norm) when length(a) == length(b) do
    case norm(b) do
      b_norm when b_norm == 0.0 ->
        0.0

      b_norm ->
        a
        |> Enum.zip(b)
        |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
        |> Kernel./(a_norm * b_norm)
    end
  end

  defp cosine(_a, _b, _a_norm), do: 0.0

  defp norm(vector) do
    vector
    |> Enum.reduce(0.0, fn value, acc -> acc + value * value end)
    |> :math.sqrt()
  end
end
