defmodule Eva.Extension.Memory.Application do
  @moduledoc """
  The memory node.

  Two lifetimes live in this supervision tree, and keeping them apart is the whole
  design:

    * `Store` and `Distiller` are **singletons of the node**. They are started once,
      here, and outlive every session — including the Eva that happened to be running
      when a memory was formed. Several sessions, on several machines, share them.

    * The extension itself (`Eva.Extension.Memory`) is instantiated **per session** by
      `Eva.Core.Extension.Node`. Those processes come and go; they hold no memory of
      their own and talk to the singletons above by name.

  That split is what makes this a memory *layer* rather than a per-session cache: what
  one session learns, the next one — on any machine — retrieves.
  """

  use Application

  alias Eva.Extension.Memory.{Distiller, Store}

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  # Tests start their own `Store` per case, against a directory of their own, so the
  # singletons must not already be running — a shared store would leak memories between
  # tests and let retrieval assertions pass for the wrong reason.
  defp children do
    if Application.get_env(:eva_memory, :start_singletons, true) do
      [
        {Store, dir: Store.dir()},
        Distiller,
        {Eva.Core.Extension.Node, node_opts()}
      ]
    else
      []
    end
  end

  # Loopback-only until a port is configured. Adding `:port` (and `:serve`) is the
  # single change that moves this node to another machine — see README.
  defp node_opts do
    base = [name: "memory", module: Eva.Extension.Memory]

    case Application.get_env(:eva_memory, :port) do
      nil -> base
      port -> base ++ [port: port, serve: Application.get_env(:eva_memory, :serve, :any)]
    end
  end
end
