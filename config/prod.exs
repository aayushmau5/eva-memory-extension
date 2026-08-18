import Config

# --- Remote exposure --------------------------------------------------------
#
# This node is the shared memory for the cluster and is served to other machines
# over the tailnet. `:port` is the whole of "another machine may dial me":
# without it Eva.Core.Extension.Node listens on loopback and names itself
# eva_ext_memory@127.0.0.1. With it, the node names itself eva_ext_memory@<this
# machine's tailnet address> and listens on exactly this port, bound to the
# tailnet interface.
#
# `serve` is the node-side veto over which Evas get an answer. Being dialable
# means anything reaching the cookie can ask this node to instantiate a memory
# session; this names the Evas that get one. `:any` is right for a node whose
# only reachable peers are already you (your own tailnet).
config :eva_memory, port: 9001
config :eva_memory, serve: :any

