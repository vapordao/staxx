defmodule Staxx.Metrix.MixProject do
  use Mix.Project

  def project do
    [
      app: :metrix,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Staxx.Metrix.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry_poller, "~> 0.4"},
      {:telemetry_metrics_prometheus, "~> 0.3.1"}
    ]
  end
end