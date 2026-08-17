import Config

# Tests get their own directory, wiped per run, and never reach the network.
config :eva_memory, :dir, Path.expand("../tmp/test-store", __DIR__)

# Each test case starts its own Store; the app-level singletons would collide with it.
config :eva_memory, :start_singletons, false
config :eva_memory, :distiller, model: "test-model", base_url: "http://localhost:0/v1"
config :eva_memory, :retrieval, backend: :lexical, limit: 6, min_score: 0.15
