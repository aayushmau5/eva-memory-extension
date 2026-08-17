defmodule Eva.Extension.Memory.MixProject do
  use Mix.Project

  def project do
    [
      app: :eva_memory,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Eva.Extension.Memory.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:eva_core, git: "https://github.com/aayushmau5/eva.git", sparse: "core"},
      {:req, "~> 0.5"},
      {:typedstruct, "~> 0.5"}
    ]
  end
end
