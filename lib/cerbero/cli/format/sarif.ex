defmodule Cerbero.CLI.Format.SARIF do
  @moduledoc """
  SARIF 2.1.0 output: a mechanical adapter over the findings list for
  GitHub code-scanning annotations. Global findings (no file) anchor to
  the committed snapshot artifact — the file they are actually about.
  """

  alias Cerbero.Finding
  alias Cerbero.Snapshot.Canonical

  @schema "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json"
  @information_uri "https://github.com/milmazz/cerbero"

  # One line per check id; unknown (third-party) ids fall back to the id.
  @rule_descriptions %{
    "column_default_rewrite" =>
      "Adding a column with a default that forces a full-table rewrite under an exclusive lock",
    "column_type_change" =>
      "Column type change that rewrites the table or rebuilds indexes at production scale",
    "concurrent_index_requires_attributes" =>
      "concurrently: true requires @disable_ddl_transaction and @disable_migration_lock",
    "crdb_transactional_ddl" => "DDL that CockroachDB rejects or restricts inside a transaction",
    "dml_in_migration" => "Data-modifying statement inside a schema migration",
    "fk_missing_index" => "Foreign key whose referencing column has no covering index",
    "fk_validation_scan" =>
      "ADD FOREIGN KEY scans the referencing table while blocking writes on the referenced table",
    "meta_findings" => "Operation cerbero cannot fully judge; warned, never silenced",
    "not_null_on_populated_table" =>
      "SET NOT NULL scans a populated table under an exclusive lock unless a validated CHECK proves it",
    "raw_ddl_safety" => "Raw DDL judged by lock mode and cost class against production scale",
    "snapshot_health" =>
      "The snapshot itself is degraded: stale, divergent, invalid indexes, or standby stats",
    "unclassified_sql" => "Raw SQL the classifier cannot classify; judged conservatively",
    "unknown_operation" => "Migration operation the parser does not recognize",
    "unmapped_operation" => "Classified SQL with no lock-table entry; judged conservatively",
    "unsafe_index_creation" =>
      "Non-concurrent index creation takes a SHARE lock that blocks writes for a full-table scan"
  }

  @spec render([Finding.t()], map(), String.t() | nil) :: String.t()
  def render(findings, summary, snapshot_path) do
    findings =
      Enum.sort_by(findings, &{&1.file || "", &1.line || 0, Atom.to_string(&1.check)})

    rule_ids =
      findings |> Enum.map(&Atom.to_string(&1.check)) |> Enum.uniq() |> Enum.sort()

    rule_index = rule_ids |> Enum.with_index() |> Map.new()

    %{
      "$schema" => @schema,
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{"driver" => driver(rule_ids)},
          "results" => Enum.map(findings, &result(&1, rule_index, snapshot_path)),
          "properties" => %{"summary" => summary}
        }
      ]
    }
    |> Canonical.encode()
  end

  defp driver(rule_ids) do
    %{
      "informationUri" => @information_uri,
      "name" => "cerbero",
      "rules" => Enum.map(rule_ids, &rule/1),
      "semanticVersion" => version(),
      "version" => version()
    }
  end

  defp rule(id) do
    %{
      "id" => id,
      "name" => id,
      "shortDescription" => %{"text" => Map.get(@rule_descriptions, id, id)}
    }
  end

  defp version, do: :cerbero |> Application.spec(:vsn) |> to_string()

  defp result(%Finding{} = f, rule_index, snapshot_path) do
    id = Atom.to_string(f.check)

    base = %{
      "ruleId" => id,
      "ruleIndex" => Map.fetch!(rule_index, id),
      "level" => level(f.severity),
      "message" => %{"text" => f.message},
      "properties" => properties(f)
    }

    case location(f, snapshot_path) do
      nil -> base
      loc -> Map.put(base, "locations", [loc])
    end
  end

  defp level(:error), do: "error"
  defp level(:warning), do: "warning"
  defp level(:info), do: "note"

  defp properties(%Finding{relations: relations, engine: nil}),
    do: %{"relations" => relations}

  defp properties(%Finding{relations: relations, engine: engine}),
    do: %{"engine" => Atom.to_string(engine), "relations" => relations}

  defp location(%Finding{file: nil}, nil), do: nil
  defp location(%Finding{file: nil}, snapshot_path), do: physical(snapshot_path, 1)
  defp location(%Finding{file: file, line: line}, _snapshot_path), do: physical(file, line)

  defp physical(uri, line) do
    location = %{"artifactLocation" => %{"uri" => uri, "uriBaseId" => "%SRCROOT%"}}
    region = if line, do: %{"region" => %{"startLine" => line}}, else: %{}
    %{"physicalLocation" => Map.merge(location, region)}
  end
end
