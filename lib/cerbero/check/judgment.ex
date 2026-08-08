defmodule Cerbero.Check.Judgment do
  @moduledoc """
  The shared judgment spine every scale-gated rule walks:
  born-silence -> scale/traffic -> `Cerbero.Severity.assess/6` -> finding
  assembly (default relations, judged-lock metadata).

  Rules parameterize the spine with their target selection and message
  text and keep their own wording; the spine owns the invariant mechanics,
  so a rule cannot accidentally skip born-silencing or forget to declare
  the lock it judged. Extracted from what `Cerbero.Check.RawDDLSafety`'s
  private generic judge already was (issue #4 item 8).

  Options:

    * `:message` (required) — zero-arity fun producing the finding message;
      lazy so suppressed verdicts never build strings.
    * `:severity` — post-processes the assessed severity; return `:suppress`
      to emit nothing. Default suppresses `:none` and keeps the rest.
      Rules use it for floors (TRUNCATE's unconditional `:error`) and
      stricter gates (`strict_concurrent_index`, fk's error/warning-only).
    * `:also_assess` — additional tables assessed with the same lock/cost
      (and the target's traffic); the most severe verdict wins. `nil`
      entries are ignored (unknown referenced table). Born-silencing
      applies to the target only — an FK onto a born table still scans
      the populated referenced side.
    * `:relations` — override the default `[qualified_target]`.
    * `:engine` — engine tag on the finding (default `nil`).
  """

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Config
  alias Cerbero.DDL.Effect
  alias Cerbero.Finding
  alias Cerbero.Migration
  alias Cerbero.Severity

  @type params :: %{
          table: String.t() | nil,
          lock: Effect.lock(),
          cost: Effect.cost(),
          line: integer() | nil
        }

  @spec judge(module(), params(), Migration.t(), Catalog.t(), Config.t(), keyword()) ::
          [Finding.t()]
  def judge(check_module, params, migration, catalog, config, opts) do
    %{table: table, lock: lock, cost: cost, line: line} = params

    cond do
      table == nil ->
        []

      Catalog.born_empty?(catalog, table) ->
        []

      true ->
        traffic = Catalog.traffic(catalog, table, config)

        assessed =
          [table | Keyword.get(opts, :also_assess, [])]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn t ->
            Severity.assess(lock, cost, Catalog.scale(catalog, t), traffic, config, catalog.multiplier)
          end)
          |> Finding.most_severe()

        case severity_fn(opts).(assessed) do
          :suppress ->
            []

          severity ->
            qualified = Catalog.qualify(table)
            message = Keyword.fetch!(opts, :message)

            [
              Helpers.finding(
                check_module,
                severity,
                message.(),
                migration,
                line,
                relations: Keyword.get(opts, :relations, [qualified]),
                engine: Keyword.get(opts, :engine),
                metadata: %{lock: lock}
              )
            ]
        end
    end
  end

  defp severity_fn(opts) do
    Keyword.get(opts, :severity, fn
      :none -> :suppress
      severity -> severity
    end)
  end
end
