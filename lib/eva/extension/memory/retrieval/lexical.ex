defmodule Eva.Extension.Memory.Retrieval.Lexical do
  @moduledoc """
  Scores memories by term overlap against their expanded surface.

  The surface is the fact *plus* the aliases and keywords the distiller generated for
  it, which is what makes this hold up against paraphrase. A memory recorded as
  "the test suite needs a named VM for distributed tests" carries aliases like
  "why do distributed tests fail" and keywords like "epmd", "node", "mix test.dist" —
  so a later turn phrased nothing like the original still finds it.

  Scoring is IDF-weighted term coverage with two adjustments:

    * **Field weighting.** A hit on the fact counts more than a hit on a keyword, so a
      memory that is genuinely about the query outranks one that merely lists the word.

    * **Recency.** A gentle decay, not a cliff — old memories are usually the valuable
      ones (that is the point of the layer), so this only breaks ties.
  """

  @behaviour Eva.Extension.Memory.Retrieval

  alias Eva.Extension.Memory.Store

  @fact_weight 1.0
  @alias_weight 0.7
  @keyword_weight 0.5

  # Recency contributes at most this much of the final score, so a fresh irrelevant
  # memory can never outrank an old relevant one.
  @recency_weight 0.1
  @half_life_days 45

  @impl true
  def search(query, memories, opts) do
    terms = query |> Store.tokenize() |> Enum.uniq()

    if terms == [] or memories == [] do
      []
    else
      idf = idf_table(memories, terms)
      floor = min_score(opts)

      memories
      |> Enum.map(fn memory -> %{memory: memory, score: score(memory, terms, idf)} end)
      |> Enum.filter(&(&1.score >= floor))
      |> Enum.sort_by(& &1.score, :desc)
    end
  end

  # Applied here rather than after fusion: a weak lexical match must not be promoted
  # into a confident result just by being the best of what this half found.
  defp min_score(opts) do
    opts[:min_score] || Application.get_env(:eva_memory, :retrieval, [])[:min_score] || 0.15
  end

  # A term matching almost every memory tells us nothing; one matching a handful is
  # most of the signal. Standard smoothed IDF over this node's own corpus.
  defp idf_table(memories, terms) do
    total = length(memories)

    surfaces = Enum.map(memories, &MapSet.new(surface_terms(&1)))

    Map.new(terms, fn term ->
      containing = Enum.count(surfaces, &MapSet.member?(&1, term))
      {term, :math.log((total + 1) / (containing + 1)) + 1.0}
    end)
  end

  defp score(memory, terms, idf) do
    fields = [
      {@fact_weight, MapSet.new(Store.tokenize(memory["fact"]))},
      {@alias_weight, memory |> list_terms("aliases") |> MapSet.new()},
      {@keyword_weight, memory |> list_terms("keywords") |> MapSet.new()}
    ]

    {matched, possible} =
      Enum.reduce(terms, {0.0, 0.0}, fn term, {matched, possible} ->
        weight = idf[term] || 1.0

        best =
          Enum.reduce(fields, 0.0, fn {field_weight, field_terms}, acc ->
            if MapSet.member?(field_terms, term), do: max(acc, field_weight), else: acc
          end)

        {matched + best * weight, possible + weight}
      end)

    if possible == 0.0 or matched == 0.0 do
      0.0
    else
      base = matched / possible
      base * (1.0 - @recency_weight) + recency(memory) * @recency_weight
    end
  end

  defp list_terms(memory, key) do
    memory
    |> Map.get(key, [])
    |> Enum.flat_map(&Store.tokenize/1)
  end

  # Every term a memory can be matched on, across all three fields. Used for document
  # frequency, where which field a term appeared in does not matter.
  defp surface_terms(memory) do
    Store.tokenize(memory["fact"]) ++
      list_terms(memory, "aliases") ++
      list_terms(memory, "keywords")
  end

  defp recency(memory) do
    last = memory["last_used_at"] || memory["created_at"] || 0
    age_days = (System.system_time(:millisecond) - last) / 86_400_000
    :math.pow(0.5, age_days / @half_life_days)
  end
end
