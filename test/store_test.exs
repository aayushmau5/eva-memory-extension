defmodule Eva.Extension.Memory.StoreTest do
  use Eva.Extension.Memory.StoreCase, async: false

  describe "put/1" do
    test "records a new memory" do
      assert {:new, id} = Store.put(%{"fact" => "Finch is the HTTP client", "project" => "eva"})
      assert [%{"id" => ^id, "fact" => "Finch is the HTTP client"}] = Store.all()
    end

    test "merges a re-observed fact instead of duplicating it" do
      {:new, id} =
        Store.put(%{
          "fact" => "distributed tests need a named VM",
          "project" => "eva",
          "keywords" => ["mix test.dist"]
        })

      assert {:merged, ^id} =
               Store.put(%{
                 "fact" => "distributed tests need a named VM",
                 "project" => "eva",
                 "keywords" => ["epmd"]
               })

      assert [memory] = Store.all()
      # The retrieval surface is the union — a second observation usually phrases
      # things differently, and both phrasings should match later.
      assert "mix test.dist" in memory["keywords"]
      assert "epmd" in memory["keywords"]
    end

    test "keeps the same sentence apart across projects" do
      Store.put(%{"fact" => "the test command is mix test", "project" => "eva"})
      Store.put(%{"fact" => "the test command is mix test", "project" => "other"})

      assert length(Store.all()) == 2
    end
  end

  describe "persistence" do
    test "replays memories from disk, honouring tombstones", %{dir: dir} do
      keep = put!(%{"fact" => "keep this one"})
      drop = put!(%{"fact" => "drop this one"})
      :ok = Store.forget(drop)

      # Restart against the same directory: this is what a node reboot does.
      stop_supervised!(Store)
      start_supervised!({Store, dir: dir})

      assert [%{"id" => ^keep}] = Store.all()
    end

    test "survives a corrupt line in the log", %{dir: dir} do
      put!(%{"fact" => "written before the corruption"})
      File.write!(Path.join(dir, "memories.jsonl"), "{not json at all\n", [:append])

      stop_supervised!(Store)
      start_supervised!({Store, dir: dir})

      assert [%{"fact" => "written before the corruption"}] = Store.all()
    end
  end

  describe "search_raw/2" do
    test "finds a past session by exact error text" do
      Store.record_session(%{
        "session" => "s1",
        "project" => "eva",
        "text" => "TOOL FAILED (bash): ** (MatchError) no match of right hand side value"
      })

      # record_session is a cast; make sure it landed before reading.
      _ = Store.stats()

      assert [hit] = Store.search_raw("MatchError no match")
      assert hit.session == "s1"
      assert hit.excerpt =~ "matcherror"
    end

    test "returns nothing for an unrelated query" do
      Store.record_session(%{"session" => "s1", "project" => "eva", "text" => "hello world"})
      _ = Store.stats()

      assert Store.search_raw("kubernetes ingress") == []
    end
  end

  describe "tokenize/1" do
    test "keeps identifiers whole and drops stopwords" do
      assert Store.tokenize("the value of lib/eva/store.ex and mix test.dist") ==
               ["value", "lib/eva/store.ex", "mix", "test.dist"]
    end
  end
end
