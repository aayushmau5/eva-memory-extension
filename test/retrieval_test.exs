defmodule Eva.Extension.Memory.RetrievalTest do
  use Eva.Extension.Memory.StoreCase, async: false

  alias Eva.Extension.Memory.Retrieval

  setup do
    # Pin the backend: the default is :hybrid, which would try to reach an embedding
    # endpoint. These tests are about the lexical half and must not touch the network.
    previous = Application.get_env(:eva_memory, :retrieval)
    Application.put_env(:eva_memory, :retrieval, backend: :lexical, limit: 6, min_score: 0.15)
    on_exit(fn -> Application.put_env(:eva_memory, :retrieval, previous) end)
    :ok
  end

  describe "aliases carry recall across paraphrase" do
    test "a question sharing no words with the fact still finds it" do
      put!(%{
        "fact" => "The test suite needs a named VM for distributed tests",
        "kind" => "gotcha",
        "aliases" => [
          "why do the distributed tests get skipped",
          "distributed tests blow up when I run them"
        ],
        "keywords" => ["mix test.dist", "epmd"]
      })

      put!(%{"fact" => "The project uses Finch for HTTP", "keywords" => ["finch"]})

      assert [%{memory: memory}] = Retrieval.search("why do my distributed tests get skipped?")
      assert memory["fact"] =~ "named VM"
    end

    test "an exact identifier outranks a topical near-miss" do
      put!(%{
        "fact" => "Run distributed tests with mix test.dist",
        "keywords" => ["mix test.dist"]
      })

      put!(%{
        "fact" => "Tests generally live under test/ and run with mix test",
        "keywords" => ["mix test"]
      })

      assert [%{memory: top} | _] = Retrieval.search("mix test.dist")
      assert top["fact"] =~ "test.dist"
    end
  end

  describe "scoping" do
    test "a project search excludes other projects but keeps global memories" do
      put!(%{"fact" => "eva uses Finch", "project" => "eva", "keywords" => ["finch"]})
      put!(%{"fact" => "other uses Finch", "project" => "other", "keywords" => ["finch"]})
      put!(%{"fact" => "prefers short commits", "project" => nil, "keywords" => ["commits"]})

      facts =
        "finch commits"
        |> Retrieval.search(project: "eva")
        |> Enum.map(& &1.memory["fact"])

      assert "eva uses Finch" in facts
      assert "prefers short commits" in facts
      refute "other uses Finch" in facts
    end
  end

  describe "thresholds" do
    test "an unrelated query retrieves nothing rather than the least-bad match" do
      put!(%{"fact" => "The project uses Finch for HTTP", "keywords" => ["finch"]})

      assert Retrieval.search("what is the weather in Delhi") == []
    end

    test "an empty query retrieves nothing" do
      put!(%{"fact" => "The project uses Finch for HTTP"})

      assert Retrieval.search("") == []
      assert Retrieval.search("   ") == []
    end
  end

  describe "hybrid fusion" do
    setup do
      previous = Application.get_env(:eva_memory, :retrieval)
      Application.put_env(:eva_memory, :retrieval, backend: :hybrid, limit: 6, min_score: 0.15)

      on_exit(fn ->
        Application.put_env(:eva_memory, :retrieval, previous)
        Application.delete_env(:eva_memory, :embedder)
      end)

      :ok
    end

    test "an unrelated query retrieves nothing even when every memory has a vector" do
      # Regression. Reciprocal rank fusion keeps only ordering, and normalizing the top
      # hit to 1.0 made every query look like a confident match. Dense vectors never
      # say "no match" on their own — 0.4-ish cosine against unrelated text is normal —
      # so with the floors removed this query retrieved a memory about HTTP clients and
      # presented it at score 1.0.
      put!(%{"fact" => "The project uses Finch for HTTP", "keywords" => ["finch"]})
      put!(%{"fact" => "Distributed tests need a named VM", "keywords" => ["test.dist"]})

      # Every stored memory sits at the background similarity an unrelated query
      # produces: nothing matches, but nothing scores zero either.
      embed_all_at(0.4)

      assert Retrieval.search("what is the capital of France") == []
    end

    test "a genuine vector match is retrieved even with no shared words" do
      put!(%{"fact" => "Distributed tests need a named VM", "keywords" => ["test.dist"]})

      embed_all_at(0.7)

      assert [%{memory: memory}] = Retrieval.search("why does the suite skip those cases")
      assert memory["fact"] =~ "named VM"
    end

    test "falls back to lexical when nothing has a vector" do
      put!(%{"fact" => "The project uses Finch for HTTP", "keywords" => ["finch"]})
      Application.put_env(:eva_memory, :embedder, fn _query -> {:error, :unreachable} end)

      assert [%{memory: memory}] = Retrieval.search("finch")
      assert memory["fact"] =~ "Finch"
    end

    test "does not retry query embeddings inside the context hook" do
      put!(%{
        "fact" => "The project uses Finch for HTTP",
        "keywords" => ["finch"],
        "vector" => [1.0, 0.0]
      })

      owner = self()

      Application.put_env(:eva_memory, :embedder, fn query, opts ->
        send(owner, {:embedding_request, query, opts})
        {:error, :unreachable}
      end)

      assert [%{memory: memory}] = Retrieval.search("finch")
      assert memory["fact"] =~ "Finch"
      assert_received {:embedding_request, "finch", [retry: false, max_retries: 0]}
    end
  end

  describe "render/1" do
    test "returns nil when there is nothing to inject" do
      assert Retrieval.render([]) == nil
    end

    test "frames memories as leads rather than facts" do
      put!(%{"fact" => "The project uses Finch for HTTP", "keywords" => ["finch"]})

      block = "finch" |> Retrieval.search() |> Retrieval.render()

      assert block =~ "<memory>"
      assert block =~ "Finch"
      # The framing is load-bearing: without it the model treats stale recall as fact.
      assert block =~ "trust what you can see"
    end
  end
end
