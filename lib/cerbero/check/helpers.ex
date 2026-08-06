defmodule Cerbero.Check.Helpers do
  @moduledoc "Message construction shared by rules: scale, stats dates, finding assembly."

  alias Cerbero.{Catalog, Finding, Migration}

  @spec human_rows(non_neg_integer()) :: String.t()
  def human_rows(n) when n >= 1_000_000, do: trim_num(n / 1_000_000) <> "M"
  def human_rows(n) when n >= 1_000, do: trim_num(n / 1_000) <> "k"
  def human_rows(n), do: Integer.to_string(n)

  defp trim_num(f) do
    rounded = Float.round(f, 1)

    if rounded == Float.round(rounded, 0),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  @spec stats_date(Catalog.t(), String.t()) :: String.t() | nil
  def stats_date(catalog, table) do
    case Catalog.table(catalog, table) do
      nil ->
        nil

      t ->
        case t.last_autoanalyze || t.last_analyze do
          nil -> nil
          %DateTime{} = dt -> dt |> DateTime.to_date() |> Date.to_iso8601()
        end
    end
  end

  @spec describe_scale(Catalog.t(), String.t()) :: String.t()
  def describe_scale(catalog, table) do
    case Catalog.scale(catalog, table) do
      {:rows, rows, _bytes} ->
        case stats_date(catalog, table) do
          nil -> "~#{human_rows(rows)} rows"
          date -> "~#{human_rows(rows)} rows, stats #{date}"
        end

      :zero ->
        "created in this deploy, empty by construction"

      :unknown ->
        "scale unknown — treated as unbounded"
    end
  end

  @spec finding(
          module(),
          Finding.severity(),
          String.t(),
          Migration.t(),
          integer() | nil,
          keyword()
        ) :: Finding.t()
  def finding(check_module, severity, message, %Migration{} = migration, line, opts \\ []) do
    %Finding{
      check: check_module.id(),
      severity: severity,
      message: message,
      file: migration.file,
      line: line,
      relations: Keyword.get(opts, :relations, []),
      engine: Keyword.get(opts, :engine),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
