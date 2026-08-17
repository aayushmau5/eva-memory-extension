# eva-memory

`eva-memory` is a persistent memory extension for Eva. It runs as a separate BEAM node,
keeps useful facts from completed sessions, and recalls relevant facts in later sessions.
One memory node can serve multiple Eva instances.

## How it works

1. Before an Eva request, the extension searches stored memories using lexical matching
   and, when available, vector similarity. Relevant results are added to the request as a
   clearly marked `<memory>` block.
2. When a session ends, its transcript is archived and queued for distillation.
3. The configured chat model extracts a small set of durable facts: decisions,
   conventions, constraints, preferences, and gotchas.
4. Facts are kept in ETS for fast retrieval and appended to JSONL on disk so they survive
   restarts.

Retrieval is synchronous and designed to fail open: if embeddings are unavailable, it
falls back to lexical search. Distillation happens after the session and is processed one
session at a time.

Eva sessions receive three tools:

- `recall` searches distilled memories.
- `history` searches archived session text.
- `remember` stores a fact when the user explicitly asks for it.

The `/memory` command shows store status, and `/forget <id>` removes a memory.

## Storage and privacy

Data lives under `~/.eva-memory/` by default:

- `memories.jsonl` is the append-only memory log, replayed into ETS at startup.
- `raw/` contains archived session transcripts grouped by day.

Back up this directory if the memory is important. It is not encrypted. Transcript text is
also sent to the configured distillation provider, so use a provider you trust and avoid
putting secrets in recorded sessions.

This implementation is intended for a personal-scale corpus. Retrieval scans memories in
memory, and `history` scans the raw archive on disk; it is not designed for hundreds of
thousands of memories without an index and log compaction.

## Retrieval modes

For the lowest resource use, select lexical retrieval:

```elixir
config :eva_memory, :retrieval, backend: :lexical
```

For hybrid retrieval, install Ollama and pull the embedding model:

```bash
ollama pull nomic-embed-text
```

Hybrid mode falls back to lexical search whenever Ollama is unavailable.

## Setup

The project fetches `eva_core` from the `core/` directory of the Eva repository using a
sparse Git dependency:

```bash
mix deps.get
```

Set the API key for the distillation provider configured in `config/config.exs`:

```bash
export OPENCODE_API_KEY=...
```

To run the extension on the same machine as Eva:

```bash
cd /path/to/eva
mix eva.ext.add /path/to/eva-memory
mix eva.ext.start memory
```

To run it on another machine, configure a listener in `config/prod.exs`:

```elixir
config :eva_memory,
  port: 9001,
  serve: [:"your_eva_node@host"]
```

The memory host and Eva must share the Eva cluster cookie and be able to reach each other
over a trusted network. Start the memory node on its host:

```bash
OPENCODE_API_KEY=... \
MIX_ENV=prod mix run --no-halt
```

Then register it from the Eva machine:

```bash
mix eva.ext.remote memory <memory-host>:9001 --machine memory-host
```

See Eva's cluster documentation for cookie exchange and distribution boot flags.
