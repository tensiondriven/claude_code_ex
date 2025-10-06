defmodule ClaudeCodeEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tensiondriven/claude_code_ex"

  def project do
    [
      app: :claude_code_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ClaudeCodeEx",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ClaudeCodeEx.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir wrapper for the Claude Code SDK (npm package).
    Provides Port-based communication with Node.js to access Claude AI capabilities.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "ClaudeCodeEx",
      extras: ["README.md"]
    ]
  end
end
