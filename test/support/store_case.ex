defmodule Eva.Extension.Memory.StoreCase do
  @moduledoc """
  Starts a `Store` against a directory of its own, wiped per test.

  The store is a named singleton, so tests that share one leak memories into each
  other's retrieval results — which is exactly the bug this layer would be worst at
  having, and the hardest to see in a test that passes for the wrong reason.
  """

  use ExUnit.CaseTemplate

  alias Eva.Extension.Memory.Store

  using do
    quote do
      alias Eva.Extension.Memory.Store
      import Eva.Extension.Memory.StoreCase
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "eva-memory-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    start_supervised!({Store, dir: dir})
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  @doc """
  Gives every stored memory a vector, and the query a vector at exactly `cosine` to it.

  Two dimensions is enough: any target cosine is reachable by rotating the query vector
  off the shared memory vector by `acos(cosine)`. That makes the embedding floor
  testable at an exact similarity, with no model and no network.
  """
  def embed_all_at(cosine) do
    Enum.each(Store.all(), fn memory ->
      Store.put(Map.put(memory, "vector", [1.0, 0.0]))
    end)

    angle = :math.acos(cosine)
    query_vector = [:math.cos(angle), :math.sin(angle)]

    Application.put_env(:eva_memory, :embedder, fn _query -> {:ok, [query_vector]} end)
  end

  @doc "Stores a memory with sensible defaults, returning its id."
  def put!(attrs) do
    {_status, id} =
      Store.put(
        Map.merge(
          %{"fact" => "a fact", "kind" => "fact", "project" => "demo"},
          attrs
        )
      )

    id
  end
end
