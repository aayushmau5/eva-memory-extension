defmodule Eva.Extension.Memory.Store do
  @moduledoc """
  Everything the node remembers, and the disk it survives on.

  Two tiers, deliberately different in shape:

    * **Memories** — small, distilled, durable. A fact plus the paraphrases and
      keywords the distiller generated for it. Held in ETS for synchronous reads,
      because retrieval happens inside a hook with a five second budget.

    * **The raw log** — whole transcripts, appended and never read on the hot path.
      This is the archaeology substrate: "have I hit this error before", answered from
      eight months of your own history. Disk is cheap and this node has plenty.

  Persistence is an append-only JSONL file replayed at boot, not a database. A memory
  edited or forgotten writes a new line that supersedes the old one, so a crash mid-write
  costs at most the line being written, and the file stays greppable by hand — which
  matters for something you are trusting to shape what a model sees.
  """

  use GenServer

  require Logger

  @table :eva_memory_records
  @memories_file "memories.jsonl"
  @raw_dir "raw"

  # Two facts this close in wording are the same fact. The distiller re-derives
  # standing facts every session, so without this the store fills with near-duplicates.
  @dedup_threshold 0.82

  @type memory :: map()

  # -- Client --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The configured root directory for this node's data."
  @spec dir() :: String.t()
  def dir do
    Application.get_env(:eva_memory, :dir) || Path.expand("~/.eva-memory")
  end

  @doc """
  The directory the running store actually opened.

  Not the same as `dir/0` whenever the store was started with an explicit `:dir` —
  which is every test. Read from `:persistent_term` rather than by calling the store,
  so `search_raw/2` can stay out of the store's process entirely.
  """
  @spec active_dir() :: String.t()
  def active_dir do
    :persistent_term.get({__MODULE__, :dir}, dir())
  end

  @doc """
  Records a memory, or merges it into an existing near-identical one.

  Returns `{:new, id}` or `{:merged, id}` so the caller can tell the difference —
  the distiller reports it, and it is the quickest way to see whether distillation is
  actually learning anything or just restating what it already knew.
  """
  @spec put(map()) :: {:new, String.t()} | {:merged, String.t()}
  def put(attrs), do: GenServer.call(__MODULE__, {:put, attrs})

  @doc "Every memory currently held, newest first."
  @spec all(keyword()) :: [memory()]
  def all(opts \\ []), do: GenServer.call(__MODULE__, {:all, opts})

  @doc """
  Marks memories as having been used, for recency-weighted ranking and for pruning.

  Fire-and-forget: this runs right after a retrieval that is already inside a hook
  budget, and a bookkeeping write must never be what makes a turn slow.
  """
  @spec touch([String.t()]) :: :ok
  def touch(ids), do: GenServer.cast(__MODULE__, {:touch, ids})

  @doc "Removes a memory. Returns whether there was one to remove."
  @spec forget(String.t()) :: :ok | {:error, :not_found}
  def forget(id), do: GenServer.call(__MODULE__, {:forget, id})

  @doc "Counts, per project and per kind, plus the raw log's size on disk."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Appends a finished session's transcript to the raw log.

  Cast, not call: this happens on `AgentEnd`, and nothing about the session should
  wait for a write to the archive.
  """
  @spec record_session(map()) :: :ok
  def record_session(record), do: GenServer.cast(__MODULE__, {:record_session, record})

  @doc """
  Searches the raw log — the archaeology query.

  Runs in the caller's process, not the store's: it may read a lot of disk, and it is
  always reached from a tool executor, which has no deadline. Blocking the store here
  would stall retrieval for every other session on this node.
  """
  @spec search_raw(String.t(), keyword()) :: [map()]
  def search_raw(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    terms = tokenize(query)

    if terms == [] do
      []
    else
      raw_path()
      |> list_log_files()
      |> Stream.flat_map(&stream_lines/1)
      |> Stream.map(&score_raw(&1, terms))
      |> Stream.reject(&is_nil/1)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
    end
  end

  @doc "Splits text into the normalized terms used for lexical matching."
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_.\/-]+/u, trim: true)
    |> Enum.reject(&stopword?/1)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  def tokenize(_), do: []

  # -- Server --

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, dir())
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, @raw_dir))
    :persistent_term.put({__MODULE__, :dir}, dir)

    table = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    loaded = replay(Path.join(dir, @memories_file), table)

    Logger.info("[memory] #{loaded} memories loaded from #{dir}")

    {:ok, %{dir: dir, table: table}}
  end

  @impl true
  def handle_call({:put, attrs}, _from, state) do
    memory = normalize(attrs)

    case find_duplicate(memory) do
      nil ->
        :ets.insert(@table, {memory["id"], memory})
        append_memory(state, memory)
        {:reply, {:new, memory["id"]}, state}

      existing ->
        merged = merge(existing, memory)
        :ets.insert(@table, {merged["id"], merged})
        append_memory(state, merged)
        {:reply, {:merged, merged["id"]}, state}
    end
  end

  def handle_call({:all, opts}, _from, state) do
    project = Keyword.get(opts, :project)

    memories =
      @table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> filter_project(project)
      |> Enum.sort_by(& &1["created_at"], :desc)

    {:reply, memories, state}
  end

  def handle_call({:forget, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, _memory}] ->
        :ets.delete(@table, id)
        append_line(state, @memories_file, %{"id" => id, "deleted" => true})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    memories = @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

    {:reply,
     %{
       total: length(memories),
       by_kind: Enum.frequencies_by(memories, & &1["kind"]),
       by_project: Enum.frequencies_by(memories, & &1["project"]),
       raw_sessions: state |> raw_files() |> Enum.map(&count_lines/1) |> Enum.sum(),
       raw_bytes: state |> raw_files() |> Enum.map(&file_size/1) |> Enum.sum(),
       dir: state.dir
     }, state}
  end

  @impl true
  def handle_cast({:touch, ids}, state) do
    now = System.system_time(:millisecond)

    Enum.each(ids, fn id ->
      case :ets.lookup(@table, id) do
        [{^id, memory}] ->
          updated =
            memory
            |> Map.put("last_used_at", now)
            |> Map.update("uses", 1, &(&1 + 1))

          :ets.insert(@table, {id, updated})

        [] ->
          :ok
      end
    end)

    # Usage counters are not worth a disk write each — they are rebuilt from the last
    # persisted value plus whatever this run saw, and losing a few is harmless.
    {:noreply, state}
  end

  def handle_cast({:record_session, record}, state) do
    file = Path.join([state.dir, @raw_dir, "#{Date.utc_today()}.jsonl"])
    append_json(file, Map.put(record, "recorded_at", System.system_time(:millisecond)))
    {:noreply, state}
  end

  # -- Memory shaping --

  defp normalize(attrs) do
    now = System.system_time(:millisecond)

    %{
      "id" => attrs["id"] || generate_id(),
      "fact" => String.trim(attrs["fact"] || ""),
      "kind" => attrs["kind"] || "fact",
      "keywords" => normalize_list(attrs["keywords"]),
      "aliases" => normalize_list(attrs["aliases"]),
      "project" => attrs["project"],
      "machine" => attrs["machine"],
      "source" => attrs["source"] || "distilled",
      "created_at" => attrs["created_at"] || now,
      "last_used_at" => attrs["last_used_at"] || now,
      "uses" => attrs["uses"] || 0,
      "vector" => attrs["vector"]
    }
  end

  defp normalize_list(nil), do: []

  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_list(_), do: []

  # A duplicate is scoped to its project: the same sentence can be a different fact in
  # a different repo ("the test command is `mix test`" is not global truth).
  defp find_duplicate(%{"fact" => fact, "project" => project}) do
    terms = MapSet.new(tokenize(fact))

    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1["project"] == project))
    |> Enum.find(fn existing ->
      jaccard(terms, MapSet.new(tokenize(existing["fact"]))) >= @dedup_threshold
    end)
  end

  # Keep the older memory's identity and creation date — it is the same knowledge,
  # re-observed — but take the newer wording and union the retrieval surface, since a
  # second observation usually phrases it differently and that is exactly what we want
  # to be able to match on later.
  defp merge(existing, new) do
    Map.merge(existing, %{
      "fact" => new["fact"],
      "keywords" => Enum.uniq(existing["keywords"] ++ new["keywords"]),
      "aliases" => Enum.uniq(existing["aliases"] ++ new["aliases"]),
      "last_used_at" => System.system_time(:millisecond),
      "uses" => (existing["uses"] || 0) + 1,
      "vector" => new["vector"] || existing["vector"]
    })
  end

  defp jaccard(a, b) do
    union = MapSet.union(a, b) |> MapSet.size()
    if union == 0, do: 0.0, else: MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(union)
  end

  defp filter_project(memories, nil), do: memories

  defp filter_project(memories, project) do
    Enum.filter(memories, &(&1["project"] == project or is_nil(&1["project"])))
  end

  # -- Persistence --

  # Later lines supersede earlier ones for the same id, so a straight fold over the
  # file in order lands on the current state — including tombstones.
  defp replay(path, table) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        case decode_line(line) do
          {:ok, %{"deleted" => true, "id" => id}} -> :ets.delete(table, id)
          {:ok, %{"id" => id} = memory} -> :ets.insert(table, {id, memory})
          _ -> :ok
        end
      end)

      :ets.info(table, :size)
    else
      0
    end
  end

  defp decode_line(line) do
    case line |> String.trim() |> JSON.decode() do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp append_memory(state, memory), do: append_line(state, @memories_file, memory)

  defp append_line(state, file, data) do
    append_json(Path.join(state.dir, file), data)
  end

  defp append_json(path, data) do
    File.write(path, JSON.encode!(data) <> "\n", [:append])
  rescue
    # Encoding or the write itself. Neither is worth taking the store down for: the
    # in-memory copy is already correct, and the cost is one lost line on next boot.
    error ->
      Logger.warning("[memory] could not write #{path}: #{inspect(error)}")
      :ok
  end

  # -- Raw log --

  defp raw_path, do: Path.join(active_dir(), @raw_dir)
  defp raw_files(state), do: state.dir |> Path.join(@raw_dir) |> list_log_files()

  defp list_log_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort(:desc)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp stream_lines(path) do
    path
    |> File.stream!()
    |> Stream.map(&decode_line/1)
    |> Stream.filter(&match?({:ok, _}, &1))
    |> Stream.map(fn {:ok, record} -> record end)
  end

  # Scores a raw record on how many distinct query terms it contains. Term *coverage*,
  # not frequency: a transcript that mentions every word of the query once is a better
  # hit than one that repeats a single word forty times.
  defp score_raw(record, terms) do
    haystack = record |> raw_text() |> String.downcase()

    matched = Enum.count(terms, &String.contains?(haystack, &1))

    if matched == 0 do
      nil
    else
      %{
        score: matched / length(terms),
        matched: matched,
        session: record["session"],
        project: record["project"],
        recorded_at: record["recorded_at"],
        summary: record["summary"],
        excerpt: excerpt(haystack, terms)
      }
    end
  end

  defp raw_text(record) do
    [record["summary"], record["text"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp excerpt(text, terms) do
    case Enum.find_value(terms, fn term ->
           case :binary.match(text, term) do
             {pos, _len} -> pos
             :nomatch -> nil
           end
         end) do
      nil ->
        String.slice(text, 0, 200)

      pos ->
        start = max(pos - 120, 0)
        text |> String.slice(start, 320) |> String.trim()
    end
  end

  defp count_lines(path) do
    path |> File.stream!() |> Enum.count()
  rescue
    _ -> 0
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @stopwords ~w(
    a an the and or but if then than that this these those is are was were be been being
    do does did doing have has had having i you he she it we they me him her them my your
    it's its of in on at to for with from by as so not no yes can will just should would
    could there here what when where which who how why all any each some
  )
  defp stopword?(word), do: word in @stopwords
end
