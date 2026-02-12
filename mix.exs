defmodule LoggerIntuitivoBackend.MixProject do
  use Mix.Project

  def project do
    [
      app: :logger_intuitivo_backend,
      name: "logger_intuitivo_backend",
      version: "1.0.0",
      elixir: "~> 1.9",
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp description do
    """
    Logger backend that sends logs through the firmware Socket (e.g. to CloudWatch).
    Supports verbose mode, buffering, throttling of repeated messages, and configurable filters.
    """
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README*", "LICENSE*", "PLAN_*"],
      maintainers: ["Intuitivo"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/intuitivo-ai/logger_intuitivo_backend"}
    ]
  end
end
