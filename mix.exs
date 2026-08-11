defmodule Cerbero.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/milmazz/cerbero"

  def project do
    [
      app: :cerbero,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r{^test/fixtures/}],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  # `mix precommit` mirrors CI's unit+lint leg so a push is never the first
  # place a gate fails. Runs in :test (see cli/0) — the same MIX_ENV CI uses
  # for every step.
  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "credo --strict",
        "compile --force --warnings-as-errors",
        "test",
        "docs --warnings-as-errors"
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Offline safety checks for Ecto migrations, judged against a committed " <>
      "snapshot of production database catalog metadata (PostgreSQL and CockroachDB)."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md LICENSE NOTICE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md"],
      # In MIX_ENV=test (the CI docs gate), test/support helpers are
      # compiled too — keep them out of the doc set in every environment.
      filter_modules: fn mod, _meta ->
        not String.starts_with?(inspect(mod), "Cerbero.Test")
      end
    ]
  end
end
