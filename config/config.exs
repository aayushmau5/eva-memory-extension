import Config

# Where memories and the raw log live. This is the node's own disk — on the machine
# that hosts it, not the session's.
config :eva_memory, :dir, Path.expand("~/.eva-memory")

# The model that distills transcripts into memories. This runs off the critical path,
# after a turn is already over, so latency does not matter — quality does.
config :eva_memory, :distiller,
  base_url: "https://opencode.ai/zen/go/v1",
  api_key: {:system, "OPENCODE_API_KEY"},
  model: "deepseek-v4-pro",
  timeout_ms: 120_000

# Retrieval backend:
#
#   :hybrid   — vector + lexical, fused. The default and the best of the three.
#   :lexical  — term matching only. Needs nothing running; the automatic fallback
#               whenever the embedding endpoint is missing or slow.
#   :embedding — vector only. Rarely what you want; hybrid strictly dominates it.
#
# Hybrid degrades to lexical on its own if embeddings are unavailable, so this is safe
# to leave on before you have pulled a model.
config :eva_memory, :retrieval,
  backend: :hybrid,
  limit: 6,
  min_score: 0.15,
  # How much the vector half contributes when both halves are available.
  vector_weight: 0.6

# Embeddings come from a local model, not from the distiller's provider — opencode go
# is a chat-completions proxy and 404s on /embeddings.
#
#   ollama pull nomic-embed-text
#
# Ollama then serves this OpenAI-compatible endpoint on :11434 with no further setup.
# LMStudio on :1234 works identically if you would rather use that.
config :eva_memory, :embedding,
  base_url: "http://localhost:11434/v1",
  api_key: nil,
  model: "nomic-embed-text",
  dimensions: 768,
  # Below this cosine, a memory is not a match. Cosine has no natural zero — unrelated
  # text scores ~0.4 with this model, related text ~0.67 — so without a floor the
  # nearest memory is always "retrieved" no matter how irrelevant.
  #
  # This number belongs to the model. Recalibrate if you change models.
  min_cosine: 0.55,
  # Short on purpose: this runs inside a hook. On timeout we fall back to lexical
  # rather than making a turn wait.
  timeout_ms: 1_500

import_config "#{config_env()}.exs"
