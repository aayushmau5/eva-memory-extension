defmodule Eva.Extension.Memory.Retrieval do
  @moduledoc """
  Picks which memories a turn should see.

  Runs inside the `:context` hook, which has a **five second budget** measured from
  Eva's side and spent partly on the network if this node is remote. The vector half
  therefore gets a short timeout and a fallback rather than a retry.

  ## Why hybrid rather than pure vector

  The two halves fail in different places, and the places barely overlap:

    * **Vectors** handle paraphrase. "why do the distributed tests blow up" finds a
      memory recorded as "the test suite needs a named VM" with no shared words.

    * **Lexical** handles identifiers. `mix test.dist`, `EPMD`, `hpax`, a error code —
      embeddings smear these into their neighbourhoods, and an exact token match is
      both more precise and free.

  Fusing them beats either alone, which is why `:hybrid` is the default. The distiller
  feeds both: it writes each fact with paraphrases and keywords, so the lexical half is
  matching an expanded surface rather than one original wording.

  Scores from the two halves are not comparable as raw numbers, so they are combined by
  **reciprocal rank fusion** on their orderings rather than by adding the scores.
  """

  alias Eva.Extension.Memory.{Retrieval, Store}

  @type hit :: %{memory: map(), score: float()}

  @callback search(query :: String.t(), memories :: [map()], opts :: keyword()) :: [hit()]

  # RRF's smoothing constant. 60 is the value from the original paper and is not worth
  # tuning: it only controls how sharply the top of each list is favoured.
  @rrf_k 60

  @doc """
  Returns the memories worth showing for this query, best first.

  Capped at `:limit`. An empty list is a normal and frequent answer — most turns have
  no relevant memory — and means nothing gets injected.

  **Relevance is decided by each backend, not here.** That is not an accident of
  layering: only the backend can see its own scores on their own scale, and a shared
  threshold applied after fusion cannot tell a strong match from the best of a bad lot.
  See `hybrid/4`.
  """
  @spec search(String.t(), keyword()) :: [hit()]
  def search(query, opts \\ []) do
    conf = Application.get_env(:eva_memory, :retrieval, [])
    limit = opts[:limit] || conf[:limit] || 6
    memories = Store.all(project: opts[:project])

    case backend(conf) do
      :hybrid -> hybrid(query, memories, opts, conf)
      module -> module.search(query, memories, opts)
    end
    |> Enum.take(limit)
  end

  @doc """
  Renders hits as the block spliced into the conversation.

  Deliberately plain and clearly delimited. The model is told where this came from and
  that it may be stale — memories are recalled by similarity, not by being true, and a
  model that treats them as established fact is worse than one with no memory at all.
  """
  @spec render([hit()]) :: String.t() | nil
  def render([]), do: nil

  def render(hits) do
    lines =
      Enum.map_join(hits, "\n", fn %{memory: memory} ->
        "- (#{memory["kind"]}) #{memory["fact"]}"
      end)

    """
    <memory>
    Recalled from earlier sessions, by similarity to the current turn. These are notes
    from past work, not verified facts about the code as it is now. Use them as leads:
    if one contradicts what you can see in the project, trust what you can see.

    #{lines}
    </memory>
    """
  end

  # -- Hybrid --

  # Both halves run over the same candidates; only the ordering differs. Lexical is
  # computed first and unconditionally, so a vector timeout costs nothing beyond the
  # wait — the answer is already there.
  #
  # Each half has already dropped everything below its own floor before we get here,
  # and that ordering is load-bearing. Fusion ranks; it cannot judge. Reciprocal rank
  # fusion discards absolute scores by construction, so a query with no good match
  # anywhere would still produce a confident-looking top hit if the halves handed up
  # their weak matches. Dense embeddings never say "no match" on their own — unrelated
  # text still scores around 0.4 cosine — so without the floors, "what is the capital
  # of France" retrieves whatever is least unrelated and injects it as a memory.
  defp hybrid(query, memories, opts, conf) do
    lexical = Retrieval.Lexical.search(query, memories, opts)
    vector = Retrieval.Embedding.rank(query, memories)

    case {lexical, vector} do
      {[], []} -> []
      {lexical, []} -> lexical
      {[], vector} -> vector
      {lexical, vector} -> fuse(lexical, vector, conf[:vector_weight] || 0.6)
    end
  end

  defp fuse(lexical, vector, vector_weight) do
    lexical_weight = 1.0 - vector_weight

    contributions =
      rrf(lexical, lexical_weight) ++ rrf(vector, vector_weight)

    contributions
    |> Enum.group_by(fn {id, _score, _memory} -> id end)
    |> Enum.map(fn {_id, entries} ->
      {_id, _score, memory} = hd(entries)
      combined = entries |> Enum.map(fn {_id, score, _memory} -> score end) |> Enum.sum()
      %{memory: memory, score: combined}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> normalize()
  end

  defp rrf(hits, weight) do
    hits
    |> Enum.with_index(1)
    |> Enum.map(fn {%{memory: memory}, rank} ->
      {memory["id"], weight * (1.0 / (@rrf_k + rank)), memory}
    end)
  end

  # RRF scores are tiny and have no natural scale. Rescaling so the best hit is 1.0
  # makes them readable in `recall` output — it is presentation only, and deliberately
  # not a relevance signal: everything here already passed its backend's floor.
  defp normalize([]), do: []

  defp normalize([%{score: top} | _] = hits) when top > 0 do
    Enum.map(hits, fn hit -> %{hit | score: hit.score / top} end)
  end

  defp normalize(hits), do: hits

  defp backend(conf) do
    case conf[:backend] do
      :embedding -> Retrieval.Embedding
      :lexical -> Retrieval.Lexical
      _ -> :hybrid
    end
  end
end
