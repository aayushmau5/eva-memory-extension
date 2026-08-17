defmodule Eva.Extension.Memory.Distiller do
  @moduledoc """
  Turns finished sessions into memories, off the critical path.

  This is the half that justifies putting the node on its own machine. It runs after
  `AgentEnd` — the turn is over, the user has their answer, nobody is waiting — so it
  can spend a hundred seconds and a full LLM call on getting the extraction right. None
  of that cost lands on the session, and none of it uses the session's tokens.

  Work is serialized through this one process on purpose. Several sessions finishing at
  once should queue, not run concurrently: they are competing for the same provider,
  and a burst of parallel distillation is how you get rate limited by your own memory
  layer.

  ## What it extracts, and what it refuses to

  The prompt is built around one distinction that decides whether this layer is useful
  or actively harmful: **durable** versus **momentary**. "The project uses Finch, not
  Req" is worth carrying to every future session. "I am currently editing store.ex" is
  worth nothing five minutes later and, injected into a future turn, is a lie. Most of
  the prompt is spent on that line.

  Each fact is written with paraphrases and keywords — the ways the same thing might be
  asked about later. That is what the lexical half of retrieval matches against, and it
  is why retrieval works well without a vector model even being present.
  """

  use GenServer

  require Logger

  alias Eva.Extension.Memory.{LLM, Store, Transcript}

  # Enough transcript for conclusions to be visible without paying for the whole session.
  @transcript_limit 24_000

  # A session too short to have concluded anything rarely yields a durable fact, and
  # asking anyway costs a request per trivial exchange.
  @min_transcript_bytes 400

  @system_prompt """
  You extract durable memories from a coding session's transcript.

  These memories will be injected into FUTURE sessions, on possibly different machines,
  weeks or months from now. The reader will not have this transcript. That single fact
  determines everything about what you should and should not record.

  ## Record only what stays true

  Record a fact if a competent engineer returning to this project in three months would
  be glad someone had written it down:

  - decisions and the reasoning behind them ("chose Finch over Req because the harness
    already supervises a Finch pool")
  - constraints and gotchas discovered the hard way ("distributed tests need a named
    VM; `mix test` alone silently skips them")
  - stable conventions of the project ("extensions are namespaced Eva.Extension.<Name>
    and the module name must match the filename")
  - the user's standing preferences ("prefers short commit messages, no co-author
    trailer")
  - where things live, when it was non-obvious to find ("the provider client is in the
    host app, not eva_core")

  ## Refuse everything momentary

  Do NOT record:

  - what was being worked on right now, or the state of an in-progress edit
  - anything already obvious from reading the code, the README, or git history
  - restatements of what a tool returned ("the test suite passed")
  - narration of the session itself ("the user asked me to refactor the store")
  - facts with no lasting consequence, however true

  When in doubt, leave it out. An empty result is a perfectly good answer and much
  better than a plausible-sounding one. Most sessions should yield zero to three
  memories. A session that yields ten is almost certainly padded.

  ## Write each fact to be read cold

  Self-contained, one sentence, no pronouns referring to the transcript. "It broke
  because of the cookie" is useless later; "Extension nodes must be restarted after
  joining a cluster because the cookie is read once at startup" is not.

  ## Aliases and keywords

  For each fact, also give the ways someone might later refer to the same thing.

  - `aliases`: 2-4 natural-language paraphrases, phrased as a person would ask about
    it. These are what a future question gets matched against, so write questions and
    restatements, not synonyms of individual words.
  - `keywords`: 3-8 exact identifiers, filenames, commands, error strings, module
    names. Verbatim, as they appear in code. These carry the most retrieval weight —
    do not paraphrase them.

  ## Output

  Return ONLY a JSON array, no prose and no code fence:

  [
    {
      "fact": "one self-contained sentence",
      "kind": "decision" | "constraint" | "convention" | "preference" | "gotcha" | "location",
      "aliases": ["how someone might ask about this", "another phrasing"],
      "keywords": ["exact_identifier", "path/to/file.ex", "mix some.task"]
    }
  ]

  An empty array is `[]`.
  """

  # -- Client --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queues a finished session for distillation.

  Cast, and deliberately so: this is called from the extension's `AgentEnd` handler,
  and nothing about ending a turn should wait on the memory layer.
  """
  @spec distill(map()) :: :ok
  def distill(session), do: GenServer.cast(__MODULE__, {:distill, session})

  @doc """
  Embeds every memory that has no vector yet.

  Run this after pointing `:embedding` at a model for the first time, or after changing
  embedding models — vectors from different models are not comparable, and retrieval
  skips any whose dimensions do not match the query's.
  """
  @spec backfill_vectors() :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill_vectors, do: GenServer.call(__MODULE__, :backfill, :timer.minutes(30))

  @doc "How many sessions are waiting, and whether one is being distilled now."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  # -- Server --

  @impl true
  def init(_opts), do: {:ok, %{queue: :queue.new(), running: nil, distilled: 0}}

  @impl true
  def handle_cast({:distill, session}, state) do
    {:noreply, state |> enqueue(session) |> maybe_run()}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       queued: :queue.len(state.queue),
       running: state.running != nil,
       distilled: state.distilled
     }, state}
  end

  def handle_call(:backfill, _from, state) do
    {:reply, do_backfill(), state}
  end

  @impl true
  def handle_info({ref, result}, %{running: {ref, session}} = state) do
    Process.demonitor(ref, [:flush])
    report(result, session)

    state = %{state | running: nil, distilled: state.distilled + count_new(result)}
    {:noreply, maybe_run(state)}
  end

  # The task died. A lost distillation is not worth crashing the node over — the
  # transcript is already in the raw log, so nothing is actually gone.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: {ref, session}} = state) do
    Logger.warning("[memory] distillation of #{session[:session]} died: #{inspect(reason)}")
    {:noreply, maybe_run(%{state | running: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Queue --

  defp enqueue(state, session), do: %{state | queue: :queue.in(session, state.queue)}

  defp maybe_run(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, session}, queue} ->
        task = Task.async(fn -> run(session) end)
        %{state | queue: queue, running: {task.ref, session}}

      {:empty, _queue} ->
        state
    end
  end

  defp maybe_run(state), do: state

  # -- The work --

  defp run(session) do
    text = Transcript.render(session.messages, limit: @transcript_limit)

    if byte_size(text) < @min_transcript_bytes do
      {:ok, []}
    else
      with {:ok, response} <- ask(text, session),
           {:ok, facts} <- parse(response) do
        {:ok, Enum.map(facts, &store(&1, session))}
      end
    end
  end

  defp ask(text, session) do
    user_prompt = """
    Project: #{session[:project] || "unknown"}

    Transcript:

    #{text}
    """

    LLM.complete([%{role: "user", content: user_prompt}],
      system: @system_prompt,
      temperature: 0.2
    )
  end

  defp store(fact, session) do
    vector = embed_fact(fact)

    Store.put(%{
      "fact" => fact["fact"],
      "kind" => fact["kind"],
      "aliases" => fact["aliases"],
      "keywords" => fact["keywords"],
      "project" => session[:project],
      "machine" => session[:machine],
      "source" => "distilled",
      "vector" => vector
    })
  end

  # Embed the fact together with its aliases: the stored vector should sit near the
  # questions that ought to retrieve it, not only near its own original wording.
  defp embed_fact(fact) do
    text = Enum.join([fact["fact"] | List.wrap(fact["aliases"])], " ")

    case LLM.embed(text, timeout_ms: 30_000) do
      {:ok, [vector | _]} -> vector
      {:error, _reason} -> nil
    end
  end

  defp do_backfill do
    missing = Enum.reject(Store.all(), &is_list(&1["vector"]))

    Enum.reduce_while(missing, {:ok, 0}, fn memory, {:ok, count} ->
      text = Enum.join([memory["fact"] | List.wrap(memory["aliases"])], " ")

      case LLM.embed(text, timeout_ms: 30_000) do
        {:ok, [vector | _]} ->
          Store.put(Map.put(memory, "vector", vector))
          {:cont, {:ok, count + 1}}

        {:error, reason} ->
          {:halt, if(count == 0, do: {:error, reason}, else: {:ok, count})}
      end
    end)
  end

  # -- Parsing --

  @doc """
  Extracts the fact array from a model response.

  Public because it is the part most likely to break when the distilling model
  changes, and the cheapest to pin down with tests.
  """
  # Models wrap JSON in fences and preambles no matter how firmly asked not to, so take
  # the outermost array rather than trusting the whole response to be clean.
  @spec parse(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse(response) do
    with {:ok, json} <- extract_array(response),
         {:ok, list} when is_list(list) <- JSON.decode(json) do
      {:ok, Enum.filter(list, &valid_fact?/1)}
    else
      _ -> {:error, {:unparseable, String.slice(response, 0, 200)}}
    end
  end

  defp extract_array(response) do
    case :binary.match(response, "[") do
      :nomatch ->
        :error

      {start, _} ->
        case find_last(response, "]") do
          nil -> :error
          finish when finish > start -> {:ok, binary_part(response, start, finish - start + 1)}
          _ -> :error
        end
    end
  end

  defp find_last(text, pattern) do
    case :binary.matches(text, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp valid_fact?(%{"fact" => fact}) when is_binary(fact), do: String.trim(fact) != ""
  defp valid_fact?(_), do: false

  defp report({:ok, []}, session) do
    Logger.debug("[memory] nothing durable in #{session[:session]}")
  end

  defp report({:ok, results}, session) do
    new = Enum.count(results, &match?({:new, _}, &1))
    merged = length(results) - new
    Logger.info("[memory] #{session[:project]}: #{new} new, #{merged} reinforced")
  end

  defp report({:error, reason}, session) do
    Logger.warning("[memory] could not distill #{session[:session]}: #{inspect(reason)}")
  end

  defp count_new({:ok, results}), do: Enum.count(results, &match?({:new, _}, &1))
  defp count_new(_), do: 0
end
