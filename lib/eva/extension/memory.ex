defmodule Eva.Extension.Memory do
  @moduledoc """
  A memory layer for Eva, and the session-facing half of the memory node.

  One instance of this module exists per session. It holds no memory itself — the
  `Store` and `Distiller` singletons in `Eva.Extension.Memory.Application` do, and they
  outlive every session that talks to them. That is what makes this a layer rather than
  a cache: what one session learns, the next one retrieves, on any machine that dials
  this node.

  ## The two halves, and why they are split

  **Retrieval** rides the `:context` hook. It has a five second budget, so it does
  nothing but score what is already in memory and splice a block into the messages. It
  fails neutral by design: a memory layer having a bad day must never be able to stop a
  turn from happening.

  **Formation** rides `AgentEnd`, which has no budget at all. The transcript goes to
  the raw log immediately, and to the distiller's queue for a full LLM extraction pass.
  The turn is already over; the user is not waiting; the session's provider is not
  billed. This is the half worth putting on its own machine.

  ## What is deliberately absent

  There is no tool for the model to write a memory as it goes. Models are enthusiastic
  memoirists and will record their own narration given the chance ("the user asked me
  to refactor the store"). Formation is left to the distiller, which sees the whole
  session at once and is prompted to be sceptical. `remember` exists for the *user* to
  pin something explicitly, which is a different act.
  """

  use Eva.Core.Extension

  require Logger

  alias Eva.Core.Agent.Events
  alias Eva.Core.Extension.Context
  alias Eva.Extension.Memory.{Distiller, Retrieval, Store}

  # Retrieval keys off the current turn, not the whole conversation. Older messages
  # describe what the session has already dealt with and pull recall off-topic.
  # Injecting on every request would restate the same block each turn, wasting context
  # and teaching the model to ignore it. The query is therefore re-derived per request
  # and retrieval only re-runs when the user has actually said something new.
  @query_messages 2

  @impl true
  def setup(ctx) do
    {:ok,
     %Spec{
       tools: [recall_tool(ctx), history_tool(ctx), remember_tool(ctx)],
       commands: [
         %Spec.Command{name: "memory", description: "What this node remembers", arg_hint: ""},
         %Spec.Command{
           name: "forget",
           description: "Drop a memory by id",
           arg_hint: "<id>"
         }
       ],
       hooks: [:context],
       event_classes: [:lifecycle],
       guidelines: [
         "A <memory> block in the conversation holds notes recalled from earlier sessions. " <>
           "Treat them as leads worth checking, not as verified facts about the current code.",
         "Use `recall` when you suspect this project has established a convention or hit a " <>
           "problem before, and `history` to search past sessions for an error you are seeing now."
       ]
     }}
  end

  @impl true
  def init(ctx) do
    {:ok,
     %{
       ctx: ctx,
       project: project_key(ctx),
       last_query: nil,
       injected: 0
     }}
  end

  # -- Retrieval: the budgeted half --

  @impl true
  def handle_hook(:context, messages, state) do
    case query_from(messages) do
      # Nothing new said since the last injection — leave the messages untouched
      # rather than restating the same block.
      query when query == state.last_query ->
        {{:ok, messages}, state}

      nil ->
        {{:ok, messages}, state}

      query ->
        inject(messages, query, state)
    end
  rescue
    # A raise here would pass messages through anyway (`:context` fails neutral), but
    # being explicit keeps the reason visible instead of silently doing nothing.
    error ->
      Logger.warning("[memory] retrieval failed: #{inspect(error)}")
      {{:ok, messages}, state}
  end

  defp inject(messages, query, state) do
    hits = Retrieval.search(query, project: state.project)

    case Retrieval.render(hits) do
      nil ->
        {{:ok, messages}, %{state | last_query: query}}

      block ->
        Store.touch(Enum.map(hits, & &1.memory["id"]))

        {{:ok, splice(messages, block)},
         %{state | last_query: query, injected: state.injected + length(hits)}}
    end
  end

  # The block goes immediately before the final user message: close enough to the
  # question to be read as relevant to it, and never in front of the system prompt.
  #
  # The result is not persisted — Eva recomputes context per request — so this cannot
  # accumulate across turns.
  defp splice(messages, block) do
    memory_message = %Eva.Core.Agent.Messages.UserMessage{content: block}

    case Enum.reverse(messages) do
      [%Eva.Core.Agent.Messages.UserMessage{} = last | rest] ->
        Enum.reverse(rest) ++ [memory_message, last]

      _ ->
        messages ++ [memory_message]
    end
  end

  defp query_from(messages) do
    messages
    |> Enum.reverse()
    |> Enum.filter(&match?(%Eva.Core.Agent.Messages.UserMessage{}, &1))
    |> Enum.take(@query_messages)
    |> Enum.map(&Eva.Core.Agent.Messages.UserMessage.text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reverse()
    |> Enum.join("\n")
    |> case do
      "" -> nil
      # Our own injected block must never become the query on the next pass.
      text -> if String.contains?(text, "<memory>"), do: nil, else: text
    end
  end

  # -- Formation: the unbudgeted half --

  @impl true
  def handle_event(%Events.AgentEnd{messages: messages}, state) when messages != [] do
    session = %{
      session: session_id(state),
      project: state.project,
      machine: state.ctx.machine,
      messages: messages
    }

    Store.record_session(%{
      "session" => session.session,
      "project" => session.project,
      "machine" => session.machine,
      "text" => Eva.Extension.Memory.Transcript.render(messages, limit: 200_000)
    })

    Distiller.distill(session)

    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  # -- Tools --

  defp recall_tool(ctx) do
    %Tools.AgentTool{
      name: "recall",
      description: """
      Search durable memories distilled from earlier sessions — decisions, conventions,
      constraints, and gotchas recorded after previous work on this and other projects.
      Use when you suspect something has been established or discovered before, rather
      than re-deriving it. Returns short facts, not code.
      """,
      prompt_snippet: "Search memories from earlier sessions",
      prompt_guidelines: [
        "Call `recall` before re-deriving a convention or re-diagnosing a familiar problem.",
        "Memories are leads, not proof — verify against the code before relying on one."
      ],
      input_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description:
              "What you want to know. Phrase it as the question you are actually asking, " <>
                "e.g. 'how are distributed tests run' rather than 'tests'."
          },
          scope: %{
            type: "string",
            enum: ["project", "all"],
            description:
              "'project' (default) limits to this project's memories; 'all' searches every project."
          }
        },
        required: ["query"]
      },
      executor: fn args, _exec_ctx ->
        query = fetch_string!(args, "query")
        scope = Map.get(args, "scope", "project")
        project = if scope == "all", do: nil, else: project_key(ctx)

        hits = Retrieval.search(query, project: project, limit: 12, min_score: 0.1)
        Store.touch(Enum.map(hits, & &1.memory["id"]))

        %Tools.AgentToolResult{
          content: [%Messages.TextContent{text: format_hits(hits)}],
          details: %{count: length(hits), scope: scope}
        }
      end
    }
  end

  defp history_tool(ctx) do
    %Tools.AgentTool{
      name: "history",
      description: """
      Search the full text of past sessions — every transcript this node has recorded,
      across projects and machines. Use for questions memories cannot answer because
      they were never worth distilling: an exact error string you are seeing now, when
      a file was last touched and why, what was tried before. Slower than `recall` and
      returns excerpts rather than facts.
      """,
      prompt_snippet: "Search the full text of past sessions",
      prompt_guidelines: [
        "Reach for `history` when you hit an error that feels familiar — paste the error text.",
        "Prefer `recall` first; `history` is the fallback when no distilled memory covers it."
      ],
      input_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description:
              "Text to search for. Exact strings work best — error messages, identifiers, paths."
          }
        },
        required: ["query"]
      },
      executor: fn args, _exec_ctx ->
        query = fetch_string!(args, "query")
        results = Store.search_raw(query, limit: 8)

        text =
          case results do
            [] ->
              "No past session mentions that."

            results ->
              Enum.map_join(results, "\n\n", fn result ->
                "## #{result.project || "unknown"} — #{format_time(result.recorded_at)}\n" <>
                  String.trim(result.excerpt)
              end)
          end

        %Tools.AgentToolResult{
          content: [%Messages.TextContent{text: text}],
          details: %{count: length(results), machine: ctx.machine}
        }
      end
    }
  end

  defp remember_tool(ctx) do
    %Tools.AgentTool{
      name: "remember",
      description: """
      Record a fact the user has explicitly asked to be remembered for future sessions.
      Only call this when the user actually says to remember something — routine
      findings are distilled automatically at the end of a session, and recording your
      own narration pollutes what future sessions see.
      """,
      prompt_snippet: "Store a fact the user asked you to remember",
      prompt_guidelines: [
        "Only call `remember` on an explicit request from the user to remember something.",
        "Write the fact self-contained — a future session sees it without this conversation."
      ],
      input_schema: %{
        type: "object",
        properties: %{
          fact: %{
            type: "string",
            description:
              "One self-contained sentence, readable with no knowledge of this conversation."
          },
          kind: %{
            type: "string",
            enum: ["decision", "constraint", "convention", "preference", "gotcha", "location"],
            description: "What sort of fact this is."
          },
          scope: %{
            type: "string",
            enum: ["project", "global"],
            description:
              "'project' (default) ties it to this project; 'global' applies it everywhere."
          }
        },
        required: ["fact"]
      },
      executor: fn args, _exec_ctx ->
        fact = fetch_string!(args, "fact")
        scope = Map.get(args, "scope", "project")

        {status, id} =
          Store.put(%{
            "fact" => fact,
            "kind" => Map.get(args, "kind", "preference"),
            "keywords" => Store.tokenize(fact),
            "project" => if(scope == "global", do: nil, else: project_key(ctx)),
            "machine" => ctx.machine,
            "source" => "explicit"
          })

        verb = if status == :new, do: "Remembered", else: "Updated an existing memory"

        %Tools.AgentToolResult{
          content: [%Messages.TextContent{text: "#{verb} (#{id}): #{fact}"}],
          details: %{id: id, status: status, scope: scope}
        }
      end
    }
  end

  # -- Commands --

  @impl true
  def handle_command("memory", _args, state) do
    stats = Store.stats()
    distiller = Distiller.status()

    kinds =
      stats.by_kind
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.map_join(", ", fn {kind, count} -> "#{kind} #{count}" end)

    text = """
    #{stats.total} memories#{if kinds == "", do: "", else: " (#{kinds})"}
    #{map_size(stats.by_project)} projects · #{stats.raw_sessions} sessions archived (#{format_bytes(stats.raw_bytes)})
    #{distiller.queued} queued for distillation#{if distiller.running, do: ", one running", else: ""}
    #{state.injected} memories injected this session
    #{stats.dir}
    """

    {String.trim(text), state}
  end

  def handle_command("forget", args, state) do
    case String.trim(args) do
      "" ->
        {{:error, "give me a memory id — `/memory` does not list them, `recall` shows them"},
         state}

      id ->
        case Store.forget(id) do
          :ok -> {"Forgotten.", state}
          {:error, :not_found} -> {{:error, "no memory with id #{id}"}, state}
        end
    end
  end

  # -- Helpers --

  # Memories are scoped by project, and the session's cwd is the only honest name for
  # one. Note this is the *session's* path, which on a remote node is a path that does
  # not exist here — it is used purely as a key, never opened.
  defp project_key(%Context{cwd: nil}), do: nil
  defp project_key(%Context{cwd: cwd}), do: Path.basename(cwd)

  defp session_id(state) do
    "#{state.project}-#{:erlang.phash2(state.ctx.session_pid)}"
  end

  defp format_hits([]), do: "No memories match that."

  defp format_hits(hits) do
    Enum.map_join(hits, "\n", fn %{memory: memory, score: score} ->
      scope = memory["project"] || "global"

      "- [#{memory["id"]}] (#{memory["kind"]}, #{scope}, #{Float.round(score, 2)}) #{memory["fact"]}"
    end)
  end

  defp fetch_string!(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> raise "#{key} cannot be empty"
          trimmed -> trimmed
        end

      _ ->
        raise "#{key} is required and must be a string"
    end
  end

  defp format_time(nil), do: "unknown"

  defp format_time(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1024)}KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"
end
