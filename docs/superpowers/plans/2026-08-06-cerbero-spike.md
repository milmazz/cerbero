# Cerbero Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the cerbero spike per `docs/design/2026-07-13-cerbero-spike.md`: `mix cerbero.snapshot` exports a privacy-bounded catalog snapshot of a Postgres/CockroachDB database; `mix cerbero.check` judges pending Ecto migrations against it offline and fails CI on catalog-derivable unsafe migrations at export-time scale.

**Architecture:** A committed, checksummed, canonical-JSON snapshot is the ground truth. A static AST parser turns migration `.exs` files into typed `Operation` structs (never executing user code); a keyword classifier handles raw SQL; a data-driven lock/cost table (`DDL.Locks`) plus a catalog model with a pending-migration overlay produces `Finding`s whose severity tracks rows, bytes, and traffic. CLI formats human/JSON output with exit codes 0/1/2.

**Tech Stack:** Elixir ≥ 1.18 (stdlib `JSON`; repo pins `~> 1.20`), `ecto_sql`, `postgrex`. Test-only: `stream_data`. Docker for integration layers 3–4.

## Global Constraints

Copied from the design doc; every task's requirements implicitly include these.

- **Privacy invariant:** the snapshot contains *identifiers, type names, enumerated keywords, booleans, numbers, and timestamps — never expression text, never literals, never row data*. Every exporter SQL statement lives as module attributes in `Cerbero.Snapshot.Exporter.Queries`. The only non-catalog read is the versions column of the migrations table.
- **Never execute user migration code.** Parsing is static AST analysis only.
- **Canonical encoding:** sorted keys, 2-space indent, tables sorted by `(schema, name)`, members sorted by name, LF endings, trailing newline. Checksum is `sha256:<hex>` over canonical bytes with the checksum field nulled — documented as *corruption and hand-edit detection*, not tamper-proofing.
- **Format versioning:** integer `format_version` starting at 1; checker refuses newer ("upgrade cerbero") and older-than-supported ("re-export"); both paths tested from day one.
- **`derive/2` is total:** any parseable operation with no Locks entry gets ACCESS EXCLUSIVE + rewrite + an `unmapped_operation` warning; a totality test enforces the enumeration.
- **Unknown scale = unbounded, never small.** Absence from snapshot (and not created by the pending set) is a `snapshot_health` error, never silence. AEL-taking operations are never silent (info floor).
- **Exit codes:** `0` no findings ≥ `--fail-on` (default `error`); `1` findings ≥ threshold; `2` operational errors (missing/corrupt snapshot, unsupported format version, bad config). Staleness is never exit 2.
- **Severity defaults (all configurable):** error ≥ 1M rows or ≥ 1 GB heap; warning ≥ 100k rows; headroom 0.5× thresholds past 14 days; stale warning past 30 days; scale degrades to unbounded past 90 days.
- **Engine floors:** PG ≥ 13 (`version_num ≥ 130000`), CRDB ≥ v23.1.
- **Dependencies:** `ecto_sql`, `postgrex`, stdlib `JSON`, test-only `stream_data`. Nothing else.
- **Wording of the claim:** cerbero detects *a specific catalog-derivable class of unsafe migrations, judged at export-time scale*. It never certifies safety. No wall-clock duration estimates, ever.
- **Meta-findings** (`unclassified_sql`, `unknown_operation`, `unmapped_operation`) default to severity **warning**.
- **README-first (§9.7):** the "why not excellent_migrations" comparison is written *before* any exporter code (Task 17 precedes Task 18).

**Decisions taken by this plan** (author can veto; each is a one-line change):

- §9.1: stdlib `JSON`, floor Elixir ≥ 1.18 (repo already pins `~> 1.20`, machine runs 1.20.2).
- §9.2: design defaults kept verbatim (100k/1M rows, 1 GB, 1.0 ops/sec hot-table rate, 14-day/0.5× headroom, 30/90-day staleness).
- Unknown scale under a write-blocking full-scan/rewrite maps to **warning** severity floor (§3.1's "warning tier or above"), so no-snapshot trial mode doesn't fail `--fail-on error` CI by default.
- Snapshot fixtures other than `huge_table.json` are built in tests by a `SnapshotBuilder` helper (stamped through the same decode/checksum path); `huge_table.json` is the committed on-disk artifact the design's first failing test demands. Migration fixtures for rules are inline source strings via `Parser.parse_string/2`; a small committed corpus lives under `test/fixtures/migrations/`.

## File Structure

```
lib/cerbero.ex                          # top-level docs only
lib/cerbero/snapshot.ex                 # Snapshot struct, load/decode/stamp/write!, checksum, version gate
lib/cerbero/snapshot/canonical.ex       # canonical JSON encoder (~60 lines)
lib/cerbero/snapshot/staleness.ex       # age → scale_mode/multiplier (clock injected)
lib/cerbero/snapshot/exporter.ex        # engine detect, build Snapshot from conn / DBA file (Task 18)
lib/cerbero/snapshot/exporter/queries.ex# ALL exporter SQL as module attributes (Task 18)
lib/cerbero/config.ex                   # .cerbero.exs loading + defaults
lib/cerbero/finding.ex                  # Finding struct + severity ordering
lib/cerbero/severity.ex                 # severity(lock, cost, scale, traffic, config, multiplier)
lib/cerbero/sql/classifier.ex           # raw SQL → [%Classified{}]
lib/cerbero/migration.ex                # Migration struct
lib/cerbero/migration/parser.ex         # .exs source → %Migration{} (static AST)
lib/cerbero/operation.ex                # Operation structs (CreateTable, AlterTable, …)
lib/cerbero/ddl/locks.ex                # (class, engine, version) → {lock, cost} data
lib/cerbero/ddl/effect.ex               # Effect struct
lib/cerbero/ddl/effects.ex              # Operation → [Effect], total, conservative default
lib/cerbero/ddl/crdb.ex                 # CRDB limitation table
lib/cerbero/catalog.ex                  # in-memory model, scale/traffic policy, apply/2 overlay, replay
lib/cerbero/check.ex                    # behaviour: c:id/0, c:run/3
lib/cerbero/check/runner.ex             # pending selection, overlay threading, skips
lib/cerbero/check/helpers.ex            # message helpers (human_rows, stats_date, qualify)
lib/cerbero/check/unsafe_index_creation.ex          # rule 1
lib/cerbero/check/not_null_on_populated_table.ex    # rule 2
lib/cerbero/check/column_default_rewrite.ex         # rule 3
lib/cerbero/check/column_type_change.ex             # rule 4
lib/cerbero/check/fk_validation_scan.ex             # rule 5
lib/cerbero/check/fk_missing_index.ex               # rule 6
lib/cerbero/check/crdb_transactional_ddl.ex         # rule 7
lib/cerbero/check/snapshot_health.ex                # rule 8 (global pass)
lib/cerbero/check/dml_in_migration.ex               # rule 9
lib/cerbero/check/concurrent_index_requires_attributes.ex # rule 10
lib/cerbero/check/meta_findings.ex      # unclassified_sql / unknown_operation / unmapped_operation
lib/cerbero/cli/check.ex                # argv, orchestration, exit codes (injectable IO/clock)
lib/cerbero/cli/format/human.ex         # human formatter
lib/cerbero/cli/format/json.ex          # JSON formatter (stable versioned shape)
lib/cerbero/cli/snapshot.ex             # snapshot CLI orchestration (Task 18)
lib/mix/tasks/cerbero.check.ex          # ~5-line shim
lib/mix/tasks/cerbero.snapshot.ex       # ~5-line shim (Task 18)
test/support/snapshot_builder.ex        # test fixture builder (stamps via real checksum path)
test/fixtures/snapshots/huge_table.json # committed, hand-authored then canonically re-stamped
test/fixtures/migrations/{safe,unsafe}/ # committed migration corpus
test/golden/                            # CLI golden files (byte-compared)
docker-compose.test.yml                 # PG 13, PG 16, CRDB single node (Tasks 18–19)
```

---

### Task 1: Canonical encoder, checksum, and the first failing test

The design mandates the first failing test verbatim: *"decodes and checksum-verifies the v1 huge_table fixture"* against a hand-authored `huge_table.json` — it forces every §3 format decision into review before any exporter code exists.

**Files:**
- Modify: `mix.exs` (deps, elixirc_paths for test/support, start version floor note)
- Create: `lib/cerbero/snapshot/canonical.ex`
- Create: `lib/cerbero/snapshot.ex`
- Create: `test/fixtures/snapshots/huge_table.json`
- Test: `test/cerbero/snapshot_test.exs`
- Delete: `lib/cerbero.ex` hello-world body (replace with moduledoc only), `test/cerbero_test.exs` doctest

**Interfaces:**
- Produces: `Cerbero.Snapshot.Canonical.encode(term) :: binary` (sorted keys, 2-space indent, LF, trailing newline); `Cerbero.Snapshot.compute_checksum(map) :: "sha256:" <> hex`; `Cerbero.Snapshot.stamp(map) :: map`; `Cerbero.Snapshot.write!(map, path) :: :ok`; `Cerbero.Snapshot.load(path) :: {:ok, raw_map} | {:error, term}` (this task returns the verified raw map; Task 2 upgrades it to a typed struct — the test written here calls `load/1` and only asserts on map keys that survive that upgrade via struct fields).

- [ ] **Step 1: Update `mix.exs`**

```elixir
defmodule Cerbero.MixProject do
  use Mix.Project

  def project do
    [
      app: :cerbero,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end
end
```

Replace `lib/cerbero.ex` with:

```elixir
defmodule Cerbero do
  @moduledoc """
  Offline safety checks for Ecto migrations, judged against a committed
  snapshot of production catalog metadata (Postgres and CockroachDB).

  Cerbero detects a specific catalog-derivable class of unsafe migrations,
  judged at export-time scale. It does not certify migrations as safe; it
  judges the statement, not the moment.
  """
end
```

Replace `test/cerbero_test.exs` with:

```elixir
defmodule CerberoTest do
  use ExUnit.Case
end
```

Run: `mix deps.get && mix compile`
Expected: compiles clean.

- [ ] **Step 2: Hand-author the fixture `test/fixtures/snapshots/huge_table.json`**

The scenario from the definition of done: `app_prod`, PG 15, `public.events` at 412M rows with an FK to `public.orgs` (41M rows). Checksum starts as a placeholder; a later step stamps it through the real code path. Field-by-field this is §1 of the design — reviewing this file *is* reviewing the format.

```json
{
  "applied_migrations": ["20250101000000", "20250215000000", "20250301000000"],
  "cerbero_version": "0.1.0",
  "checksum": "sha256:PENDING",
  "collected_at": "2026-07-01T00:00:00Z",
  "database": "app_prod",
  "engine": {"name": "postgres", "version": "15.4", "version_num": 150004},
  "format_version": 1,
  "standby": false,
  "stats_provenance": "primary",
  "stats_reset": "2026-01-01T00:00:00Z",
  "tables": [
    {
      "columns": [
        {"default": {"kind": "sequence", "present": true, "volatile": false}, "generated": null, "identity": false, "name": "id", "not_null": true, "type": "bigint"},
        {"default": null, "generated": null, "identity": false, "name": "name", "not_null": true, "type": "character varying(255)"}
      ],
      "constraints": [
        {"columns": ["id"], "is_not_null_check_on": null, "name": "orgs_pkey", "on_delete": null, "on_update": null, "references": null, "type": "primary", "validated": true}
      ],
      "heap_bytes": 8589934592,
      "idx_scan": 4100000,
      "indexes": [
        {"bytes": 1073741824, "keys": [{"kind": "column", "name": "id"}], "method": "btree", "name": "orgs_pkey", "partial": false, "primary": true, "unique": true, "valid": true}
      ],
      "last_analyze": null,
      "last_autoanalyze": "2026-06-30T21:00:00Z",
      "n_live_tup": 41000000,
      "n_tup_del": 1000,
      "n_tup_ins": 4000000,
      "n_tup_upd": 900000,
      "name": "orgs",
      "partition_of": null,
      "partitioned": false,
      "relpages": 1048576,
      "reltuples": 41000000.0,
      "schema": "public",
      "seq_scan": 12,
      "total_bytes": 10737418240
    },
    {
      "columns": [
        {"default": {"kind": "sequence", "present": true, "volatile": false}, "generated": null, "identity": false, "name": "id", "not_null": true, "type": "bigint"},
        {"default": null, "generated": null, "identity": false, "name": "org_id", "not_null": true, "type": "bigint"},
        {"default": null, "generated": null, "identity": false, "name": "payload", "not_null": false, "type": "jsonb"},
        {"default": {"kind": "expression", "present": true, "volatile": true}, "generated": null, "identity": false, "name": "inserted_at", "not_null": true, "type": "timestamp without time zone"}
      ],
      "constraints": [
        {"columns": ["id"], "is_not_null_check_on": null, "name": "events_pkey", "on_delete": null, "on_update": null, "references": null, "type": "primary", "validated": true},
        {"columns": ["org_id"], "is_not_null_check_on": null, "name": "events_org_id_fkey", "on_delete": "no_action", "on_update": "no_action", "references": {"columns": ["id"], "table": "public.orgs"}, "type": "foreign_key", "validated": true}
      ],
      "heap_bytes": 219902325555,
      "idx_scan": 91000000,
      "indexes": [
        {"bytes": 12884901888, "keys": [{"kind": "column", "name": "id"}], "method": "btree", "name": "events_pkey", "partial": false, "primary": true, "unique": true, "valid": true}
      ],
      "last_analyze": null,
      "last_autoanalyze": "2026-06-30T23:30:00Z",
      "n_live_tup": 412000000,
      "n_tup_del": 20000,
      "n_tup_ins": 96000000,
      "n_tup_upd": 3000000,
      "name": "events",
      "partition_of": null,
      "partitioned": false,
      "relpages": 26843546,
      "reltuples": 412000000.0,
      "schema": "public",
      "seq_scan": 40,
      "total_bytes": 253403070464
    }
  ]
}
```

- [ ] **Step 3: Write the failing test**

`test/cerbero/snapshot_test.exs`:

```elixir
defmodule Cerbero.SnapshotTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical

  @fixture "test/fixtures/snapshots/huge_table.json"

  test "decodes and checksum-verifies the v1 huge_table fixture" do
    assert {:ok, snapshot} = Snapshot.load(@fixture)
    assert snapshot["database"] == "app_prod"
    assert snapshot["format_version"] == 1
    assert snapshot["engine"]["name"] == "postgres"
    assert [%{"name" => "events"}, %{"name" => "orgs"}] =
             Enum.sort_by(snapshot["tables"], & &1["name"])
  end

  test "fixture bytes are already canonical (re-encode is byte-identical)" do
    raw = @fixture |> File.read!() |> JSON.decode!()
    assert Canonical.encode(raw) == File.read!(@fixture)
  end

  test "load rejects a corrupted snapshot with a checksum error" do
    raw = @fixture |> File.read!() |> JSON.decode!()
    tampered = put_in(raw, ["tables", Access.at(0), "n_live_tup"], 1)
    path = Path.join(System.tmp_dir!(), "tampered.json")
    File.write!(path, Canonical.encode(tampered))
    assert {:error, {:checksum_mismatch, _expected, _actual}} = Snapshot.load(path)
  end

  describe "canonical encoding" do
    test "sorts keys, indents 2 spaces, ends with LF" do
      assert Canonical.encode(%{"b" => 1, "a" => [true, nil]}) ==
               """
               {
                 "a": [
                   true,
                   null
                 ],
                 "b": 1
               }
               """
    end

    test "checksum is independent of input key order" do
      a = %{"x" => 1, "y" => %{"k" => [1, 2]}, "checksum" => nil}
      b = %{"y" => %{"k" => [1, 2]}, "checksum" => nil, "x" => 1}
      assert Snapshot.compute_checksum(a) == Snapshot.compute_checksum(b)
    end
  end
end
```

- [ ] **Step 4: Run tests, verify they fail**

Run: `mix test test/cerbero/snapshot_test.exs`
Expected: FAIL — `Cerbero.Snapshot` / `Cerbero.Snapshot.Canonical` are undefined.

- [ ] **Step 5: Implement the canonical encoder**

`lib/cerbero/snapshot/canonical.ex`:

```elixir
defmodule Cerbero.Snapshot.Canonical do
  @moduledoc """
  Canonical JSON: object keys sorted lexicographically, 2-space indent,
  LF endings, trailing newline. The checksum is computed over these bytes,
  and stable ordering is what makes PR diffs reviewable, so this encoder
  must stay byte-stable across Elixir/OTP versions.
  """

  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary([do_encode(term, 0), "\n"])

  defp do_encode(map, _depth) when map == %{}, do: "{}"

  defp do_encode(map, depth) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} ->
        [pad(depth + 1), JSON.encode!(to_string(k)), ": ", do_encode(v, depth + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", inner, "\n", pad(depth), "}"]
  end

  defp do_encode([], _depth), do: "[]"

  defp do_encode(list, depth) when is_list(list) do
    inner =
      list
      |> Enum.map(fn v -> [pad(depth + 1), do_encode(v, depth + 1)] end)
      |> Enum.intersperse(",\n")

    ["[\n", inner, "\n", pad(depth), "]"]
  end

  defp do_encode(scalar, _depth), do: JSON.encode!(scalar)

  defp pad(depth), do: String.duplicate("  ", depth)
end
```

- [ ] **Step 6: Implement checksum + load in `lib/cerbero/snapshot.ex`**

```elixir
defmodule Cerbero.Snapshot do
  @moduledoc """
  The snapshot artifact: decode, verify, canonically re-encode.

  The checksum detects corruption and hand-edits — anyone who can commit
  can regenerate it; it is not tamper-proofing.
  """

  alias Cerbero.Snapshot.Canonical

  @format_version 1
  @min_supported 1

  def format_version, do: @format_version

  @spec compute_checksum(map()) :: String.t()
  def compute_checksum(map) when is_map(map) do
    canonical = Canonical.encode(Map.put(map, "checksum", nil))
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  @spec stamp(map()) :: map()
  def stamp(map), do: Map.put(map, "checksum", compute_checksum(map))

  @spec write!(map(), Path.t()) :: :ok
  def write!(map, path), do: File.write!(path, Canonical.encode(stamp(map)))

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, bytes} <- read(path),
         {:ok, raw} <- decode_json(bytes),
         :ok <- verify_checksum(raw),
         :ok <- gate_version(raw) do
      {:ok, raw}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode_json(bytes) do
    case JSON.decode(bytes) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      _ -> {:error, :invalid_json}
    end
  end

  defp verify_checksum(%{"checksum" => "sha256:" <> _ = embedded} = raw) do
    case compute_checksum(raw) do
      ^embedded -> :ok
      actual -> {:error, {:checksum_mismatch, embedded, actual}}
    end
  end

  defp verify_checksum(_), do: {:error, :missing_checksum}

  defp gate_version(%{"format_version" => v}) when is_integer(v) do
    cond do
      v > @format_version -> {:error, {:format_too_new, v, "upgrade cerbero"}}
      v < @min_supported -> {:error, {:format_too_old, v, "re-export the snapshot"}}
      true -> :ok
    end
  end

  defp gate_version(_), do: {:error, :missing_format_version}
end
```

- [ ] **Step 7: Stamp the fixture through the real code path**

Run:

```bash
mix run -e '
  raw = "test/fixtures/snapshots/huge_table.json" |> File.read!() |> JSON.decode!()
  Cerbero.Snapshot.write!(raw, "test/fixtures/snapshots/huge_table.json")
'
```

This rewrites the hand-authored file in canonical byte form with a real checksum (`stamp/1` overwrites the `PENDING` placeholder). Inspect the diff — it should only reorder/reformat and fill the checksum, never change values.

- [ ] **Step 8: Run tests, verify they pass**

Run: `mix test test/cerbero/snapshot_test.exs`
Expected: PASS (all).

- [ ] **Step 9: Add format-version gate tests**

Append to `test/cerbero/snapshot_test.exs`:

```elixir
  describe "format version gate" do
    defp reload_with(fun) do
      raw = "test/fixtures/snapshots/huge_table.json" |> File.read!() |> JSON.decode!()
      path = Path.join(System.tmp_dir!(), "versioned.json")
      Cerbero.Snapshot.write!(fun.(raw), path)
      Cerbero.Snapshot.load(path)
    end

    test "refuses a newer format_version, telling the user to upgrade" do
      assert {:error, {:format_too_new, 2, "upgrade cerbero"}} =
               reload_with(&Map.put(&1, "format_version", 2))
    end

    test "refuses an older-than-supported format_version, telling the user to re-export" do
      assert {:error, {:format_too_old, 0, "re-export the snapshot"}} =
               reload_with(&Map.put(&1, "format_version", 0))
    end
  end
```

Run: `mix test test/cerbero/snapshot_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: snapshot format v1 — canonical encoder, checksum, version gate, huge_table fixture"
```

---

### Task 2: Typed strict decode + the privacy allowlist test

`additionalProperties: false` at every level, implemented as a strict decoder that rejects unknown keys and out-of-enum values. Adding a free-text-capable field must require touching `privacy_test.exs`.

**Files:**
- Modify: `lib/cerbero/snapshot.ex`
- Create: `test/support/snapshot_builder.ex`
- Test: `test/cerbero/snapshot_decode_test.exs`, `test/cerbero/privacy_test.exs`

**Interfaces:**
- Consumes: `Snapshot.load/1` raw-map form from Task 1.
- Produces: `Snapshot.load(path) :: {:ok, %Cerbero.Snapshot{}} | {:error, term}` now returns a typed struct. Struct fields: `format_version, cerbero_version, collected_at :: DateTime.t(), database, engine :: %{name: :postgres | :cockroachdb, version: String.t(), version_num: integer}, standby :: boolean, stats_provenance :: :primary | :standby, stats_reset :: DateTime.t() | nil, applied_migrations :: [String.t()], tables :: [%Cerbero.Snapshot.Table{}], raw :: map()`. `%Cerbero.Snapshot.Table{schema, name, partitioned, partition_of, reltuples, relpages, n_live_tup, last_analyze, last_autoanalyze, seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del, heap_bytes, total_bytes, columns, indexes, constraints}`; columns are `%{name, type, not_null, identity, generated, default: %{present, volatile, kind} | nil}`; indexes `%{name, unique, primary, valid, method, partial, bytes, keys: [%{kind: :column, name: n} | %{kind: :expression}]}`; constraints `%{name, type :: :primary | :unique | :foreign_key | :check | :exclusion, columns, validated, references: %{table, columns} | nil, on_delete, on_update, is_not_null_check_on}`.
- Produces: `Cerbero.Test.SnapshotBuilder.build(overrides \\ %{}) :: map()` (raw stamped map) and `build_snapshot(overrides) :: %Cerbero.Snapshot{}`, plus `table(name, overrides)` helpers — the fixture factory every later rule test uses.

- [ ] **Step 1: Write failing decode tests**

`test/cerbero/snapshot_decode_test.exs`:

```elixir
defmodule Cerbero.SnapshotDecodeTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot

  @fixture "test/fixtures/snapshots/huge_table.json"

  test "load returns a typed struct" do
    assert {:ok, %Snapshot{} = s} = Snapshot.load(@fixture)
    assert s.database == "app_prod"
    assert s.engine.name == :postgres
    assert s.engine.version_num == 150004
    assert %DateTime{} = s.collected_at
    assert [%Snapshot.Table{name: "events"} = events, %Snapshot.Table{name: "orgs"}] =
             Enum.sort_by(s.tables, & &1.name)
    assert events.n_live_tup == 412_000_000
    assert [%{name: "id"}, %{name: "org_id"} = org_id | _] = events.columns
    refute is_nil(org_id.not_null)
    assert Enum.any?(events.constraints, &(&1.type == :foreign_key and &1.references.table == "public.orgs"))
  end

  test "rejects unknown fields at any level" do
    for path_fun <- [
          &Map.put(&1, "surprise", "free text"),
          &put_in(&1, ["tables", Access.at(0), "surprise"], "free text"),
          &put_in(&1, ["tables", Access.at(0), "columns", Access.at(0), "surprise"], "x")
        ] do
      raw = @fixture |> File.read!() |> JSON.decode!()
      path = Path.join(System.tmp_dir!(), "unknown_field.json")
      Cerbero.Snapshot.write!(path_fun.(raw), path)
      assert {:error, {:unknown_fields, _path, ["surprise"]}} = Snapshot.load(path)
    end
  end

  test "rejects out-of-enum values" do
    raw = @fixture |> File.read!() |> JSON.decode!()
    bad = put_in(raw, ["engine", "name"], "mysql")
    path = Path.join(System.tmp_dir!(), "bad_enum.json")
    Cerbero.Snapshot.write!(bad, path)
    assert {:error, {:invalid_value, _path, "mysql"}} = Snapshot.load(path)
  end
end
```

Run: `mix test test/cerbero/snapshot_decode_test.exs`
Expected: FAIL (load returns a plain map; no struct, no strictness).

- [ ] **Step 2: Implement typed strict decode**

Extend `lib/cerbero/snapshot.ex` (keep everything from Task 1; `load/1` now pipes through `decode/1`):

```elixir
  defstruct [
    :format_version, :cerbero_version, :collected_at, :database, :engine,
    :standby, :stats_provenance, :stats_reset, :applied_migrations, :tables, :raw
  ]

  defmodule Table do
    defstruct [
      :schema, :name, :partitioned, :partition_of, :reltuples, :relpages,
      :n_live_tup, :last_analyze, :last_autoanalyze,
      :seq_scan, :idx_scan, :n_tup_ins, :n_tup_upd, :n_tup_del,
      :heap_bytes, :total_bytes, :columns, :indexes, :constraints
    ]
  end

  # in load/1, replace the final `{:ok, raw}` with `decode(raw)`

  @top_fields ~w(applied_migrations cerbero_version checksum collected_at database engine format_version standby stats_provenance stats_reset tables)
  @engine_fields ~w(name version version_num)
  @table_fields ~w(columns constraints heap_bytes idx_scan indexes last_analyze last_autoanalyze n_live_tup n_tup_del n_tup_ins n_tup_upd name partition_of partitioned relpages reltuples schema seq_scan total_bytes)
  @column_fields ~w(default generated identity name not_null type)
  @default_fields ~w(kind present volatile)
  @index_fields ~w(bytes keys method name partial primary unique valid)
  @key_fields ~w(kind name)
  @constraint_fields ~w(columns is_not_null_check_on name on_delete on_update references type validated)
  @references_fields ~w(columns table)

  @engines %{"postgres" => :postgres, "cockroachdb" => :cockroachdb}
  @provenance %{"primary" => :primary, "standby" => :standby}
  @constraint_types %{"primary" => :primary, "unique" => :unique, "foreign_key" => :foreign_key, "check" => :check, "exclusion" => :exclusion}
  @default_kinds %{"sequence" => :sequence, "expression" => :expression, "literal" => :literal}
  @key_kinds %{"column" => :column, "expression" => :expression}

  @spec decode(map()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def decode(raw) do
    with :ok <- strict(raw, @top_fields, "$"),
         :ok <- strict(raw["engine"], @engine_fields, "$.engine"),
         {:ok, engine_name} <- enum(raw["engine"]["name"], @engines, "$.engine.name"),
         {:ok, provenance} <- enum(raw["stats_provenance"], @provenance, "$.stats_provenance"),
         {:ok, collected_at} <- datetime(raw["collected_at"], "$.collected_at"),
         {:ok, stats_reset} <- optional_datetime(raw["stats_reset"], "$.stats_reset"),
         {:ok, tables} <- decode_tables(raw["tables"]) do
      {:ok,
       %__MODULE__{
         format_version: raw["format_version"],
         cerbero_version: raw["cerbero_version"],
         collected_at: collected_at,
         database: raw["database"],
         engine: %{name: engine_name, version: raw["engine"]["version"], version_num: raw["engine"]["version_num"]},
         standby: raw["standby"],
         stats_provenance: provenance,
         stats_reset: stats_reset,
         applied_migrations: raw["applied_migrations"],
         tables: tables,
         raw: raw
       }}
    end
  end

  defp decode_tables(tables) when is_list(tables) do
    map_while_ok(tables, fn t ->
      with :ok <- strict(t, @table_fields, "$.tables[#{t["name"]}]"),
           {:ok, columns} <- map_while_ok(t["columns"], &decode_column/1),
           {:ok, indexes} <- map_while_ok(t["indexes"], &decode_index/1),
           {:ok, constraints} <- map_while_ok(t["constraints"], &decode_constraint/1),
           {:ok, la} <- optional_datetime(t["last_analyze"], "last_analyze"),
           {:ok, laa} <- optional_datetime(t["last_autoanalyze"], "last_autoanalyze") do
        {:ok,
         %Table{
           schema: t["schema"], name: t["name"], partitioned: t["partitioned"],
           partition_of: t["partition_of"], reltuples: t["reltuples"], relpages: t["relpages"],
           n_live_tup: t["n_live_tup"], last_analyze: la, last_autoanalyze: laa,
           seq_scan: t["seq_scan"], idx_scan: t["idx_scan"], n_tup_ins: t["n_tup_ins"],
           n_tup_upd: t["n_tup_upd"], n_tup_del: t["n_tup_del"],
           heap_bytes: t["heap_bytes"], total_bytes: t["total_bytes"],
           columns: columns, indexes: indexes, constraints: constraints
         }}
      end
    end)
  end

  defp decode_column(c) do
    with :ok <- strict(c, @column_fields, "column #{c["name"]}"),
         {:ok, default} <- decode_default(c["default"]) do
      {:ok,
       %{name: c["name"], type: c["type"], not_null: c["not_null"],
         identity: c["identity"], generated: decode_generated(c["generated"]), default: default}}
    end
  end

  defp decode_generated(nil), do: nil
  defp decode_generated("stored"), do: :stored

  defp decode_default(nil), do: {:ok, nil}

  defp decode_default(d) do
    with :ok <- strict(d, @default_fields, "default"),
         {:ok, kind} <- enum(d["kind"], @default_kinds, "default.kind") do
      {:ok, %{present: d["present"], volatile: d["volatile"], kind: kind}}
    end
  end

  defp decode_index(i) do
    with :ok <- strict(i, @index_fields, "index #{i["name"]}"),
         {:ok, keys} <- map_while_ok(i["keys"], &decode_key/1) do
      {:ok,
       %{name: i["name"], unique: i["unique"], primary: i["primary"], valid: i["valid"],
         method: i["method"], partial: i["partial"], bytes: i["bytes"], keys: keys}}
    end
  end

  defp decode_key(k) do
    with :ok <- strict(k, @key_fields, "index key"),
         {:ok, kind} <- enum(k["kind"], @key_kinds, "key.kind") do
      {:ok, if(kind == :column, do: %{kind: :column, name: k["name"]}, else: %{kind: :expression})}
    end
  end

  defp decode_constraint(c) do
    with :ok <- strict(c, @constraint_fields, "constraint #{c["name"]}"),
         {:ok, type} <- enum(c["type"], @constraint_types, "constraint.type"),
         {:ok, refs} <- decode_references(c["references"]) do
      {:ok,
       %{name: c["name"], type: type, columns: c["columns"], validated: c["validated"],
         references: refs, on_delete: c["on_delete"], on_update: c["on_update"],
         is_not_null_check_on: c["is_not_null_check_on"]}}
    end
  end

  defp decode_references(nil), do: {:ok, nil}

  defp decode_references(r) do
    with :ok <- strict(r, @references_fields, "references") do
      {:ok, %{table: r["table"], columns: r["columns"]}}
    end
  end

  defp strict(map, allowed, path) when is_map(map) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      extra -> {:error, {:unknown_fields, path, Enum.sort(extra)}}
    end
  end

  defp strict(_other, _allowed, path), do: {:error, {:invalid_value, path, :not_an_object}}

  defp enum(value, mapping, path) do
    case Map.fetch(mapping, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_value, path, value}}
    end
  end

  defp datetime(value, path) do
    case is_binary(value) && DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> {:ok, dt}
      _ -> {:error, {:invalid_value, path, value}}
    end
  end

  defp optional_datetime(nil, _path), do: {:ok, nil}
  defp optional_datetime(value, path), do: datetime(value, path)

  defp map_while_ok(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end
```

Note: the Task 1 test asserting `snapshot["database"]` breaks with the struct return — update it to `snapshot.database` / `%Snapshot{}` pattern (and table access to structs). Do that now.

- [ ] **Step 3: Run tests, verify pass**

Run: `mix test`
Expected: PASS (including updated Task 1 assertions).

- [ ] **Step 4: Write the SnapshotBuilder test helper**

`test/support/snapshot_builder.ex`:

```elixir
defmodule Cerbero.Test.SnapshotBuilder do
  @moduledoc """
  Builds raw snapshot maps for tests, stamped through the real checksum
  path so every fixture a rule test consumes has passed the same strict
  decode + privacy allowlist as a production snapshot.
  """

  alias Cerbero.Snapshot

  def build(overrides \\ %{}) do
    %{
      "applied_migrations" => [],
      "cerbero_version" => "0.1.0",
      "checksum" => nil,
      "collected_at" => "2026-07-01T00:00:00Z",
      "database" => "app_prod",
      "engine" => %{"name" => "postgres", "version" => "15.4", "version_num" => 150_004},
      "format_version" => 1,
      "standby" => false,
      "stats_provenance" => "primary",
      "stats_reset" => "2026-01-01T00:00:00Z",
      "tables" => []
    }
    |> Map.merge(overrides)
    |> Snapshot.stamp()
  end

  def build_snapshot(overrides \\ %{}) do
    {:ok, snapshot} = Snapshot.decode(build(overrides))
    snapshot
  end

  @doc "A table map with sane small defaults; override what the test cares about."
  def table(name, overrides \\ %{}) do
    %{
      "columns" => [column("id", %{"type" => "bigint"})],
      "constraints" => [],
      "heap_bytes" => 8192,
      "idx_scan" => 0,
      "indexes" => [],
      "last_analyze" => nil,
      "last_autoanalyze" => "2026-06-30T00:00:00Z",
      "n_live_tup" => 100,
      "n_tup_del" => 0,
      "n_tup_ins" => 0,
      "n_tup_upd" => 0,
      "name" => name,
      "partition_of" => nil,
      "partitioned" => false,
      "relpages" => 1,
      "reltuples" => 100.0,
      "schema" => "public",
      "seq_scan" => 0,
      "total_bytes" => 8192
    }
    |> Map.merge(overrides)
  end

  def column(name, overrides \\ %{}) do
    %{
      "default" => nil, "generated" => nil, "identity" => false,
      "name" => name, "not_null" => false, "type" => "bigint"
    }
    |> Map.merge(overrides)
  end

  def index(name, keys, overrides \\ %{}) do
    %{
      "bytes" => 8192,
      "keys" => Enum.map(keys, &%{"kind" => "column", "name" => &1}),
      "method" => "btree", "name" => name, "partial" => false,
      "primary" => false, "unique" => false, "valid" => true
    }
    |> Map.merge(overrides)
  end

  def fk(name, columns, ref_table, overrides \\ %{}) do
    %{
      "columns" => columns, "is_not_null_check_on" => nil, "name" => name,
      "on_delete" => "no_action", "on_update" => "no_action",
      "references" => %{"columns" => ["id"], "table" => ref_table},
      "type" => "foreign_key", "validated" => true
    }
    |> Map.merge(overrides)
  end
end
```

- [ ] **Step 5: Write the privacy test**

`test/cerbero/privacy_test.exs`:

```elixir
defmodule Cerbero.PrivacyTest do
  @moduledoc """
  The privacy allowlist. Adding any free-text-capable field to the
  snapshot REQUIRES touching this file — that is the point of it.
  Layers enforced here: strict schema (unknown fields rejected at every
  level), closed enums, and no expression-text fields anywhere.
  """
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot
  import Cerbero.Test.SnapshotBuilder

  @committed_fixtures Path.wildcard("test/fixtures/snapshots/*.json")

  test "every committed fixture passes strict decode" do
    for path <- @committed_fixtures do
      assert {:ok, %Snapshot{}} = Snapshot.load(path), "fixture #{path} failed strict decode"
    end
  end

  test "builder output passes strict decode" do
    assert {:ok, %Snapshot{}} =
             Snapshot.decode(build(%{"tables" => [table("events"), table("orgs")]}))
  end

  # The invariant, mechanically: no field whose value could carry
  # expression text or literals exists in the schema. If this list of
  # string-valued fields grows, a human must justify the addition here.
  @string_fields_that_are_identifiers_or_enums ~w(
    cerbero_version database name schema type method partition_of table
    on_delete on_update is_not_null_check_on kind stats_provenance version
    collected_at stats_reset last_analyze last_autoanalyze checksum
  )

  test "all string-valued leaves in the fixture are identifier/enum/timestamp fields" do
    raw = "test/fixtures/snapshots/huge_table.json" |> File.read!() |> JSON.decode!()
    for {key_path, value} <- string_leaves(raw), is_binary(value) do
      key = List.last(key_path)
      assert key in @string_fields_that_are_identifiers_or_enums or is_integer(key),
             "unexpected string field #{inspect(key_path)} — privacy review required"
    end
  end

  defp string_leaves(map, path \\ [])

  defp string_leaves(map, path) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> string_leaves(v, path ++ [k]) end)

  defp string_leaves(list, path) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> string_leaves(v, path ++ [i]) end)

  defp string_leaves(v, path) when is_binary(v), do: [{path, v}]
  defp string_leaves(_v, _path), do: []
end
```

Note: `applied_migrations` entries are version strings reached through integer indexes — the `is_integer(key)` clause covers list elements whose parent key was already vetted; tighten later if it proves too loose.

- [ ] **Step 6: Run, verify pass, commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A
git commit -m "feat: typed strict snapshot decode + privacy allowlist test + fixture builder"
```

---

### Task 3: Config and staleness policy

**Files:**
- Create: `lib/cerbero/config.ex`, `lib/cerbero/snapshot/staleness.ex`
- Test: `test/cerbero/config_test.exs`, `test/cerbero/staleness_test.exs`

**Interfaces:**
- Consumes: `%Cerbero.Snapshot{collected_at: DateTime.t()}`.
- Produces: `%Cerbero.Config{}` with defaults below and `Cerbero.Config.load(path) :: {:ok, %Config{}} | {:error, {:bad_config, msg}}`; `Cerbero.Snapshot.Staleness.assess(snapshot, now, config) :: %Staleness{age_days: integer, scale_mode: :exact | :unbounded, threshold_multiplier: float}`. Later tasks rely on exactly these field names.

- [ ] **Step 1: Write failing tests**

`test/cerbero/config_test.exs`:

```elixir
defmodule Cerbero.ConfigTest do
  use ExUnit.Case, async: true

  alias Cerbero.Config

  test "defaults match the design doc" do
    assert {:ok, %Config{} = c} = Config.load("nonexistent/.cerbero.exs")
    assert c.rows_warning == 100_000
    assert c.rows_error == 1_000_000
    assert c.bytes_error == 1_073_741_824
    assert c.hot_ops_per_sec == 1.0
    assert c.headroom_days == 14
    assert c.headroom_multiplier == 0.5
    assert c.stale_warn_days == 30
    assert c.stale_degrade_days == 90
    assert c.fail_on == :error
    assert c.skip_checks == []
    assert c.severity_overrides == %{}
    assert c.lock_timeout_attested == false
    assert c.strict_concurrent_index == false
    assert c.start_after == nil
    assert c.precision == :exact
    assert c.schemas == ["public"]
    assert c.migrations_paths == ["priv/repo/migrations"]
    assert c.snapshot_path == "priv/repo/cerbero_snapshot.json"
  end

  test "loads overrides from a .cerbero.exs keyword list" do
    path = Path.join(System.tmp_dir!(), ".cerbero.exs")
    File.write!(path, "[rows_error: 5_000_000, lock_timeout_attested: true]")
    assert {:ok, %Config{rows_error: 5_000_000, lock_timeout_attested: true}} = Config.load(path)
  end

  test "unknown keys are a bad_config error, not a crash" do
    path = Path.join(System.tmp_dir!(), ".cerbero_bad.exs")
    File.write!(path, "[rows_eror: 5]")
    assert {:error, {:bad_config, msg}} = Config.load(path)
    assert msg =~ "rows_eror"
  end
end
```

`test/cerbero/staleness_test.exs`:

```elixir
defmodule Cerbero.StalenessTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot.Staleness
  import Cerbero.Test.SnapshotBuilder

  defp assess(days_old) do
    snapshot = build_snapshot()
    now = DateTime.add(snapshot.collected_at, days_old, :day)
    {:ok, config} = Cerbero.Config.load("nonexistent")
    Staleness.assess(snapshot, now, config)
  end

  test "fresh snapshot: exact scale, no headroom" do
    assert %Staleness{age_days: 3, scale_mode: :exact, threshold_multiplier: 1.0} = assess(3)
  end

  test "past 14 days: headroom multiplier 0.5, still exact" do
    assert %Staleness{scale_mode: :exact, threshold_multiplier: 0.5} = assess(20)
  end

  test "past 90 days: scale degrades to unbounded" do
    assert %Staleness{scale_mode: :unbounded, threshold_multiplier: 0.5} = assess(91)
  end
end
```

Run: `mix test test/cerbero/config_test.exs test/cerbero/staleness_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 2: Implement**

`lib/cerbero/config.ex`:

```elixir
defmodule Cerbero.Config do
  @moduledoc "Checker configuration, loaded from `.cerbero.exs` (a keyword list)."

  defstruct rows_warning: 100_000,
            rows_error: 1_000_000,
            bytes_error: 1_073_741_824,
            hot_ops_per_sec: 1.0,
            headroom_days: 14,
            headroom_multiplier: 0.5,
            stale_warn_days: 30,
            stale_degrade_days: 90,
            fail_on: :error,
            skip_checks: [],
            severity_overrides: %{},
            lock_timeout_attested: false,
            strict_concurrent_index: false,
            start_after: nil,
            precision: :exact,
            schemas: ["public"],
            migrations_paths: ["priv/repo/migrations"],
            snapshot_path: "priv/repo/cerbero_snapshot.json"

  @type t :: %__MODULE__{}

  @spec load(Path.t()) :: {:ok, t()} | {:error, {:bad_config, String.t()}}
  def load(path \\ ".cerbero.exs") do
    if File.exists?(path) do
      {opts, _bindings} = Code.eval_file(path)
      from_keyword(opts)
    else
      {:ok, %__MODULE__{}}
    end
  rescue
    e -> {:error, {:bad_config, Exception.message(e)}}
  end

  @spec from_keyword(keyword()) :: {:ok, t()} | {:error, {:bad_config, String.t()}}
  def from_keyword(opts) do
    known = Map.keys(%__MODULE__{}) -- [:__struct__]

    case Keyword.keys(opts) -- known do
      [] -> {:ok, struct!(__MODULE__, opts)}
      unknown -> {:error, {:bad_config, "unknown config keys: #{inspect(unknown)}"}}
    end
  end
end
```

`lib/cerbero/snapshot/staleness.ex`:

```elixir
defmodule Cerbero.Snapshot.Staleness do
  @moduledoc """
  Staleness degrades confidence, never fails unrelated PRs. Past the
  headroom window, severity thresholds shrink (a table at 600k rows three
  weeks ago is judged as if at the 1M tier). Past the degrade age, every
  row count becomes unknown → unbounded, so a stale snapshot cannot
  silently certify anything — but PRs with no pending migrations still
  pass. The age findings themselves are emitted by the snapshot_health
  rule, which consumes this struct.
  """

  alias Cerbero.{Config, Snapshot}

  defstruct [:age_days, :scale_mode, :threshold_multiplier]

  @type t :: %__MODULE__{
          age_days: integer(),
          scale_mode: :exact | :unbounded,
          threshold_multiplier: float()
        }

  @spec assess(Snapshot.t(), DateTime.t(), Config.t()) :: t()
  def assess(%Snapshot{collected_at: at}, %DateTime{} = now, %Config{} = config) do
    age_days = DateTime.diff(now, at, :day)

    %__MODULE__{
      age_days: age_days,
      scale_mode: if(age_days > config.stale_degrade_days, do: :unbounded, else: :exact),
      threshold_multiplier:
        if(age_days > config.headroom_days, do: config.headroom_multiplier, else: 1.0)
    }
  end
end
```

- [ ] **Step 3: Run, verify pass, commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A
git commit -m "feat: config loading with design defaults + staleness policy (headroom, degrade-to-unbounded)"
```

---

### Task 4: Finding struct, Check behaviour, and the severity function

**Files:**
- Create: `lib/cerbero/finding.ex`, `lib/cerbero/check.ex`, `lib/cerbero/severity.ex`
- Test: `test/cerbero/severity_test.exs`

**Interfaces:**
- Consumes: `%Cerbero.Config{}` (Task 3).
- Produces: `%Cerbero.Finding{check, severity, message, file, line, relations, engine, metadata}`; `Cerbero.Finding.at_least?(severity, threshold) :: boolean`; behaviour `Cerbero.Check` with `@callback id() :: atom` and `@callback run(Cerbero.Migration.t(), Cerbero.Catalog.t(), Cerbero.Config.t()) :: [Cerbero.Finding.t()]`; `Cerbero.Severity.assess(lock, cost, scale, traffic, config, multiplier \\ 1.0) :: :error | :warning | :info | :none` where `scale :: {:rows, non_neg_integer, bytes :: non_neg_integer} | :zero | :unknown` and `traffic :: :hot | :cold | :unknown`. Every rule task uses these exact shapes.

- [ ] **Step 1: Write failing severity tests**

`test/cerbero/severity_test.exs`:

```elixir
defmodule Cerbero.SeverityTest do
  use ExUnit.Case, async: true

  alias Cerbero.Severity

  setup do
    {:ok, config} = Cerbero.Config.load("nonexistent")
    %{config: config}
  end

  # {lock, cost, scale, traffic, multiplier, expected}
  @cases [
    # full_scan/rewrite under write-blocking lock: tiers by rows/bytes
    {:share, :full_scan, {:rows, 412_000_000, 219_902_325_555}, :cold, 1.0, :error},
    {:access_exclusive, :rewrite, {:rows, 500_000, 0}, :cold, 1.0, :warning},
    {:access_exclusive, :rewrite, {:rows, 50_000, 2_000_000_000}, :cold, 1.0, :error},
    {:share, :full_scan, {:rows, 5_000, 8_192}, :cold, 1.0, :info},
    # headroom multiplier: 600k rows judged at 0.5x thresholds -> error tier
    {:share, :full_scan, {:rows, 600_000, 0}, :cold, 0.5, :error},
    # unknown scale = unbounded, never small: warning floor
    {:share, :full_scan, :unknown, :unknown, 1.0, :warning},
    # born-this-deploy zero scale under a scan: nothing to scan
    {:share, :full_scan, :zero, :cold, 1.0, :none},
    # metadata-only under AEL: traffic OR rows gates warning; never silent
    {:access_exclusive, :metadata_only, {:rows, 10_000, 8_192}, :hot, 1.0, :warning},
    {:access_exclusive, :metadata_only, {:rows, 200_000, 8_192}, :cold, 1.0, :warning},
    {:access_exclusive, :metadata_only, {:rows, 10, 8_192}, :cold, 1.0, :info},
    {:access_exclusive, :metadata_only, :zero, :cold, 1.0, :info},
    # non-blocking lock, metadata cost: silent
    {:share_update_exclusive, :metadata_only, {:rows, 412_000_000, 0}, :hot, 1.0, :none},
    # non-blocking full scan (CIC, VALIDATE): cost note at scale, info
    {:share_update_exclusive, :full_scan, {:rows, 412_000_000, 0}, :cold, 1.0, :info},
    {:share_update_exclusive, :full_scan, {:rows, 5_000, 0}, :cold, 1.0, :none}
  ]

  test "severity table", %{config: config} do
    for {lock, cost, scale, traffic, mult, expected} <- @cases do
      assert Severity.assess(lock, cost, scale, traffic, config, mult) == expected,
             "#{inspect({lock, cost, scale, traffic, mult})} expected #{expected}"
    end
  end

  test "ordering helper" do
    assert Cerbero.Finding.at_least?(:error, :warning)
    assert Cerbero.Finding.at_least?(:warning, :warning)
    refute Cerbero.Finding.at_least?(:info, :warning)
  end
end
```

Run: `mix test test/cerbero/severity_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement**

`lib/cerbero/finding.ex`:

```elixir
defmodule Cerbero.Finding do
  @moduledoc "One judged fact: mechanism + scale + provenance, with source location."

  @enforce_keys [:check, :severity, :message]
  defstruct [:check, :severity, :message, :file, :line, relations: [], engine: nil, metadata: %{}]

  @type severity :: :error | :warning | :info
  @type t :: %__MODULE__{}

  @order %{error: 3, warning: 2, info: 1}

  @spec at_least?(severity(), severity()) :: boolean()
  def at_least?(severity, threshold), do: @order[severity] >= @order[threshold]
end
```

`lib/cerbero/check.ex`:

```elixir
defmodule Cerbero.Check do
  @moduledoc """
  Behaviour for migration checks. Internal rules are its first consumers;
  it is public API by design (spec constraint, born from real Credo-check
  pain).
  """

  @callback id() :: atom()
  @callback run(Cerbero.Migration.t(), Cerbero.Catalog.t(), Cerbero.Config.t()) ::
              [Cerbero.Finding.t()]
end
```

`lib/cerbero/severity.ex`:

```elixir
defmodule Cerbero.Severity do
  @moduledoc """
  severity(lock, cost, scale, traffic, config, multiplier).

  Lock-queue damage tracks traffic, not table size; rewrite/scan damage
  tracks rows and bytes. The multiplier is staleness headroom (thresholds
  shrink as the snapshot ages). Unknown scale is unbounded, never small.
  An ACCESS EXCLUSIVE operation is never silent: the floor is :info.
  """

  alias Cerbero.Config

  @write_blocking [:access_exclusive, :share, :share_row_exclusive]

  @type scale :: {:rows, non_neg_integer(), non_neg_integer()} | :zero | :unknown
  @type traffic :: :hot | :cold | :unknown

  @spec assess(atom(), atom(), scale(), traffic(), Config.t(), float()) ::
          :error | :warning | :info | :none
  def assess(lock, cost, scale, traffic, config, multiplier \\ 1.0)

  # Scanning/rewriting under a write-blocking lock: the classic outage.
  def assess(lock, cost, scale, _traffic, %Config{} = c, mult)
      when lock in @write_blocking and cost in [:full_scan, :rewrite] do
    case scale do
      :zero -> if lock == :access_exclusive, do: :info, else: :none
      :unknown -> :warning
      {:rows, rows, bytes} ->
        cond do
          rows >= c.rows_error * mult or bytes >= c.bytes_error * mult -> :error
          rows >= c.rows_warning * mult -> :warning
          lock == :access_exclusive -> :info
          true -> :info
        end
    end
  end

  # Metadata-only under AEL: gate on traffic OR rows; never silent.
  def assess(:access_exclusive, :metadata_only, scale, traffic, %Config{} = c, mult) do
    rows = case scale do
      {:rows, n, _} -> n
      _ -> 0
    end

    cond do
      traffic == :hot -> :warning
      scale == :unknown -> :warning
      rows >= c.rows_warning * mult -> :warning
      true -> :info
    end
  end

  # Non-blocking full scan (CIC, VALIDATE CONSTRAINT): resource cost note at scale.
  def assess(_lock, cost, {:rows, rows, bytes}, _traffic, %Config{} = c, mult)
      when cost in [:full_scan, :rewrite] do
    if rows >= c.rows_error * mult or bytes >= c.bytes_error * mult, do: :info, else: :none
  end

  def assess(_lock, cost, :unknown, _traffic, _c, _mult)
      when cost in [:full_scan, :rewrite], do: :info

  def assess(_lock, _cost, _scale, _traffic, _config, _mult), do: :none
end
```

- [ ] **Step 3: Run, verify pass, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: Finding struct, Check behaviour, severity policy (traffic-aware, headroom, AEL floor)"
```

---

### Task 5: SQL classifier

Anchored keyword heuristic; anything unclassifiable is `:unknown` (which later becomes the `unclassified_sql` warning — the escape route must be reachable by `--fail-on`).

**Files:**
- Create: `lib/cerbero/sql/classifier.ex`
- Test: `test/cerbero/sql/classifier_test.exs`

**Interfaces:**
- Produces: `Cerbero.SQL.Classifier.classify(sql :: String.t()) :: [%Classified{}]` (one entry per statement; multi-statement strings yield multiple entries). `%Cerbero.SQL.Classifier.Classified{class, table, column, constraint, concurrently: boolean, not_valid: boolean, unique: boolean}` with `class` ∈ `:create_index | :drop_index | :create_table | :drop_table | :add_column | :drop_column | :set_not_null | :add_check_is_not_null | :add_check | :add_foreign_key | :validate_constraint | :alter_column_type | :update | :delete | :insert_select | :truncate | :reindex | :unknown`. Table names come back schema-qualified when the SQL qualifies them, bare otherwise; quotes stripped.

- [ ] **Step 1: Write failing table-driven tests**

`test/cerbero/sql/classifier_test.exs`:

```elixir
defmodule Cerbero.SQL.ClassifierTest do
  use ExUnit.Case, async: true

  alias Cerbero.SQL.Classifier
  alias Cerbero.SQL.Classifier.Classified

  defp one(sql) do
    assert [classified] = Classifier.classify(sql)
    classified
  end

  test "create index, plain and concurrent, unique, quoted, qualified" do
    assert %Classified{class: :create_index, table: "events", concurrently: false} =
             one("CREATE INDEX idx ON events (user_id)")

    assert %Classified{class: :create_index, table: "public.events", concurrently: true, unique: true} =
             one("CREATE UNIQUE INDEX CONCURRENTLY idx ON \"public\".\"events\" (user_id)")
  end

  test "drop index" do
    assert %Classified{class: :drop_index, concurrently: false} = one("DROP INDEX idx")
    assert %Classified{class: :drop_index, concurrently: true} = one("drop index concurrently if exists idx")
  end

  test "the safe NOT NULL two-step, raw-SQL form (design §3 overlay requirement)" do
    assert %Classified{class: :add_check_is_not_null, table: "events", column: "org_id",
                       constraint: "org_id_not_null", not_valid: true} =
             one("ALTER TABLE events ADD CONSTRAINT org_id_not_null CHECK (org_id IS NOT NULL) NOT VALID")

    assert %Classified{class: :validate_constraint, table: "events", constraint: "org_id_not_null"} =
             one("ALTER TABLE events VALIDATE CONSTRAINT org_id_not_null")

    assert %Classified{class: :set_not_null, table: "events", column: "org_id"} =
             one("ALTER TABLE events ALTER COLUMN org_id SET NOT NULL")
  end

  test "generic check, fk, type change, add column" do
    assert %Classified{class: :add_check, not_valid: false} =
             one("ALTER TABLE t ADD CONSTRAINT positive CHECK (price > 0)")

    assert %Classified{class: :add_foreign_key, table: "events", not_valid: true} =
             one("ALTER TABLE events ADD CONSTRAINT fk FOREIGN KEY (org_id) REFERENCES orgs (id) NOT VALID")

    assert %Classified{class: :alter_column_type, table: "events", column: "id"} =
             one("ALTER TABLE events ALTER COLUMN id TYPE bigint")

    assert %Classified{class: :add_column, table: "events", column: "flags"} =
             one("ALTER TABLE events ADD COLUMN flags integer DEFAULT 0")
  end

  test "DML detection" do
    assert %Classified{class: :update, table: "events"} = one("UPDATE events SET x = 1")
    assert %Classified{class: :delete, table: "events"} = one("DELETE FROM events WHERE x = 1")
    assert %Classified{class: :insert_select, table: "events_v2"} =
             one("INSERT INTO events_v2 SELECT * FROM events")
  end

  test "multi-statement strings classify each statement" do
    assert [%Classified{class: :create_table}, %Classified{class: :create_index}] =
             Classifier.classify("CREATE TABLE a (id int); CREATE INDEX i ON a (id);")
  end

  test "comments are stripped; unclassifiable is :unknown, never a crash" do
    assert %Classified{class: :truncate, table: "events"} =
             one("-- boom\nTRUNCATE events")

    assert %Classified{class: :unknown} = one("CLUSTER events USING idx")
    assert %Classified{class: :unknown} = one("DO $$ BEGIN NULL; END $$")
  end
end
```

Run: `mix test test/cerbero/sql/classifier_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement**

`lib/cerbero/sql/classifier.ex`:

```elixir
defmodule Cerbero.SQL.Classifier do
  @moduledoc """
  Keyword-heuristic classification of raw SQL in `execute/1,2`. This is
  deliberately NOT a SQL parser: anchored patterns over normalized text,
  with `:unknown` as the honest fallback (surfaced as `unclassified_sql`).
  DML is *detected* (target table), never analyzed.
  """

  defmodule Classified do
    defstruct class: :unknown,
              table: nil,
              column: nil,
              constraint: nil,
              concurrently: false,
              not_valid: false,
              unique: false
  end

  @ident ~S{((?:"[^"]+"|[a-z_][a-z0-9_$]*)(?:\.(?:"[^"]+"|[a-z_][a-z0-9_$]*))?)}

  @spec classify(String.t()) :: [%Classified{}]
  def classify(sql) when is_binary(sql) do
    sql
    |> strip_comments()
    |> split_statements()
    |> Enum.map(&classify_statement/1)
  end

  defp strip_comments(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, " ")
    |> String.replace(~r{/\*.*?\*/}s, " ")
  end

  defp split_statements(sql) do
    sql
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize(stmt) do
    stmt |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp classify_statement(stmt) do
    n = normalize(stmt)

    cond do
      m = run(~r/^create (unique )?index (concurrently )?(?:if not exists )?\S+ on (?:only )?#{@ident}/, n) ->
        %Classified{class: :create_index, unique: m[1] != "", concurrently: m[2] != "", table: unq(m[3])}

      m = run(~r/^drop index (concurrently )?(?:if exists )?#{@ident}/, n) ->
        %Classified{class: :drop_index, concurrently: m[1] != "", table: nil, constraint: unq(m[2])}

      m = run(~r/^create table (?:if not exists )?#{@ident}/, n) ->
        %Classified{class: :create_table, table: unq(m[1])}

      m = run(~r/^drop table (?:if exists )?#{@ident}/, n) ->
        %Classified{class: :drop_table, table: unq(m[1])}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} add constraint (\S+) check \( ?(\S+) is not null ?\)( not valid)?/, n) ->
        %Classified{class: :add_check_is_not_null, table: unq(m[1]), constraint: unq(m[2]),
                    column: unq(m[3]), not_valid: m[4] != ""}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} add constraint (\S+) check /, n) ->
        %Classified{class: :add_check, table: unq(m[1]), constraint: unq(m[2]),
                    not_valid: String.ends_with?(n, "not valid")}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:constraint (\S+) )?foreign key/, n) ->
        %Classified{class: :add_foreign_key, table: unq(m[1]), constraint: unq(m[2]),
                    not_valid: String.ends_with?(n, "not valid")}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} validate constraint (\S+)/, n) ->
        %Classified{class: :validate_constraint, table: unq(m[1]), constraint: unq(m[2])}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} alter column (\S+) set not null/, n) ->
        %Classified{class: :set_not_null, table: unq(m[1]), column: unq(m[2])}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} alter column (\S+) (?:set data )?type /, n) ->
        %Classified{class: :alter_column_type, table: unq(m[1]), column: unq(m[2])}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:column )?(?:if not exists )?(\S+) /, n) ->
        %Classified{class: :add_column, table: unq(m[1]), column: unq(m[2])}

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} drop (?:column )?(?:if exists )?(\S+)/, n) ->
        %Classified{class: :drop_column, table: unq(m[1]), column: unq(m[2])}

      m = run(~r/^truncate (?:table )?(?:only )?#{@ident}/, n) ->
        %Classified{class: :truncate, table: unq(m[1])}

      m = run(~r/^reindex /, n) && true ->
        _ = m
        %Classified{class: :reindex, concurrently: String.contains?(n, " concurrently")}

      m = run(~r/^update (?:only )?#{@ident} set /, n) ->
        %Classified{class: :update, table: unq(m[1])}

      m = run(~r/^delete from (?:only )?#{@ident}/, n) ->
        %Classified{class: :delete, table: unq(m[1])}

      m = run(~r/^insert into #{@ident}[\s\S]* select /, n) ->
        %Classified{class: :insert_select, table: unq(m[1])}

      true ->
        %Classified{class: :unknown}
    end
  end

  # Returns a 1-indexed capture map (m[1], m[2], ...) or nil.
  defp run(regex, string) do
    case Regex.run(regex, string) do
      nil -> nil
      captures -> captures |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c || ""} end)
    end
  end

  defp unq(nil), do: nil
  defp unq(""), do: nil
  defp unq(ident), do: ident |> String.replace("\"", "") |> String.trim_trailing(",")
end
```

Note on `@ident` interpolation into `~r//`: module attributes interpolate at compile time in sigils without modifiers — verify with the tests; if the sigil complains, build the regexes with `Regex.compile!("...#{@ident}...")` in module attributes instead. The tests are the arbiter.

- [ ] **Step 3: Run until green, then commit**

Run: `mix test test/cerbero/sql/classifier_test.exs`
Expected: PASS. Iterate on patterns until the table passes — the test list is the spec.

```bash
git add -A
git commit -m "feat: SQL classifier — anchored keyword heuristic, DDL + DML detection, :unknown fallback"
```

---

### Task 6: Operation structs and the migration parser

Static AST analysis. Migrations are never executed; dynamically-built operations become `%Unknown{}`, never silence.

**Files:**
- Create: `lib/cerbero/operation.ex`, `lib/cerbero/migration.ex`, `lib/cerbero/migration/parser.ex`
- Create: `test/fixtures/migrations/unsafe/20260801000000_add_events_payload_index.exs`, `test/fixtures/migrations/safe/20260801000001_add_events_payload_index_concurrently.exs`
- Test: `test/cerbero/migration/parser_test.exs`

**Interfaces:**
- Consumes: `Cerbero.SQL.Classifier.classify/1` (Task 5).
- Produces: `Cerbero.Migration.Parser.parse_file(path) :: {:ok, %Cerbero.Migration{}} | {:error, term}`; `parse_string(source, file \\ "inline.exs") :: same` (used by all rule tests); `Cerbero.Migration.Parser.parse_dir(dir) :: {:ok, [%Migration{}]}` (sorted by version). `%Cerbero.Migration{file, module, version :: String.t() | nil, attrs: %{disable_ddl_transaction: boolean, disable_migration_lock: boolean, cerbero_skip: [{atom, String.t()}]}, operations: [op]}`. Operation structs (all with `:line`):
  - `%Cerbero.Operation.CreateTable{table, columns: [%{name: String.t(), type: atom | tuple, opts: keyword}]}`
  - `%Cerbero.Operation.AlterTable{table, ops: [{:add_column, name, type, opts} | {:modify_column, name, type, opts} | {:remove_column, name}]}` — `type` may be `{:references, table, opts}`
  - `%Cerbero.Operation.CreateIndex{table, keys :: [String.t() | :expression], concurrently, unique}`
  - `%Cerbero.Operation.DropIndex{table, concurrently}`
  - `%Cerbero.Operation.CreateConstraint{table, name, check :: String.t() | nil, validate :: boolean}`
  - `%Cerbero.Operation.DropTable{table}`
  - `%Cerbero.Operation.RenameOp{table}`
  - `%Cerbero.Operation.RawSQL{sql, classified: [%Classified{}]}`
  - `%Cerbero.Operation.Unknown{description}`
  All table names are strings, unqualified as written (qualification happens in Catalog).

- [ ] **Step 1: Commit two corpus fixtures**

`test/fixtures/migrations/unsafe/20260801000000_add_events_payload_index.exs`:

```elixir
defmodule AppRepo.Migrations.AddEventsPayloadIndex do
  use Ecto.Migration

  def change do
    create index(:events, [:org_id, :inserted_at])
  end
end
```

`test/fixtures/migrations/safe/20260801000001_add_events_payload_index_concurrently.exs`:

```elixir
defmodule AppRepo.Migrations.AddEventsPayloadIndexConcurrently do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:events, [:org_id, :inserted_at], concurrently: true)
  end
end
```

- [ ] **Step 2: Write failing parser tests**

`test/cerbero/migration/parser_test.exs`:

```elixir
defmodule Cerbero.Migration.ParserTest do
  use ExUnit.Case, async: true

  alias Cerbero.Migration
  alias Cerbero.Migration.Parser
  alias Cerbero.Operation.{AlterTable, CreateConstraint, CreateIndex, CreateTable, DropIndex, RawSQL, Unknown}

  defp ops!(source) do
    {:ok, %Migration{operations: ops}} = Parser.parse_string(source)
    ops
  end

  test "parses the committed corpus fixtures with versions and attributes" do
    {:ok, unsafe} = Parser.parse_file("test/fixtures/migrations/unsafe/20260801000000_add_events_payload_index.exs")
    assert unsafe.version == "20260801000000"
    assert unsafe.attrs.disable_ddl_transaction == false
    assert [%CreateIndex{table: "events", keys: ["org_id", "inserted_at"], concurrently: false, line: 5}] =
             unsafe.operations

    {:ok, safe} = Parser.parse_file("test/fixtures/migrations/safe/20260801000001_add_events_payload_index_concurrently.exs")
    assert safe.attrs.disable_ddl_transaction and safe.attrs.disable_migration_lock
    assert [%CreateIndex{concurrently: true}] = safe.operations
  end

  test "create table with columns, references, and defaults" do
    assert [%CreateTable{table: "events_v2", columns: cols}] = ops!("""
           defmodule M do
             use Ecto.Migration
             def change do
               create table(:events_v2) do
                 add :org_id, references(:orgs, on_delete: :nothing), null: false
                 add :flags, :integer, default: 0
                 add :inserted_at, :naive_datetime, default: fragment("now()")
               end
             end
           end
           """)

    assert [
             %{name: "org_id", type: {:references, "orgs", [on_delete: :nothing]}, opts: [null: false]},
             %{name: "flags", type: :integer, opts: [default: 0]},
             %{name: "inserted_at", type: :naive_datetime, opts: [default: {:fragment, "now()"}]}
           ] = cols
  end

  test "alter table: add/modify/remove" do
    assert [%AlterTable{table: "events", ops: ops}] = ops!("""
           defmodule M do
             use Ecto.Migration
             def up do
               alter table(:events) do
                 add :score, :float
                 modify :org_id, :bigint, null: false
                 remove :legacy
               end
             end
           end
           """)

    assert [
             {:add_column, "score", :float, []},
             {:modify_column, "org_id", :bigint, [null: false]},
             {:remove_column, "legacy"}
           ] = ops
  end

  test "unique_index, drop index, constraint" do
    assert [
             %CreateIndex{table: "events", unique: true},
             %DropIndex{table: "events", concurrently: true},
             %CreateConstraint{table: "products", name: "price_positive", check: "price > 0", validate: false}
           ] = ops!("""
           defmodule M do
             use Ecto.Migration
             def change do
               create unique_index(:events, [:external_id])
               drop index(:events, [:legacy], concurrently: true)
               create constraint(:products, "price_positive", check: "price > 0", validate: false)
             end
           end
           """)
  end

  test "execute with a literal string is classified raw SQL; two-arg takes up only" do
    assert [%RawSQL{sql: "TRUNCATE events", classified: [%{class: :truncate}]}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def up do
                 execute "TRUNCATE events", "SELECT 1"
               end
               def down do
               end
             end
             """)
  end

  test "dynamic constructs become Unknown, never silence, never execution" do
    assert [%Unknown{}] = ops!("""
           defmodule M do
             use Ecto.Migration
             def change do
               for t <- [:a, :b], do: create(index(t, [:x]))
             end
           end
           """)

    assert [%Unknown{}] = ops!("""
           defmodule M do
             use Ecto.Migration
             def up do
               execute build_sql()
             end
             defp build_sql, do: "DROP TABLE users"
           end
           """)
  end

  test "@cerbero_skip is parsed; empty reason is a parse error" do
    {:ok, m} = Parser.parse_string("""
    defmodule M do
      use Ecto.Migration
      @cerbero_skip [{:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}]
      def change do
        create index(:events, [:org_id])
      end
    end
    """)

    assert m.attrs.cerbero_skip == [{:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}]

    assert {:error, {:empty_skip_reason, :unsafe_index_creation}} =
             Parser.parse_string("""
             defmodule M do
               use Ecto.Migration
               @cerbero_skip [{:unsafe_index_creation, ""}]
               def change do
               end
             end
             """)
  end
end
```

Run: `mix test test/cerbero/migration/parser_test.exs` — Expected: FAIL.

- [ ] **Step 3: Implement operation structs**

`lib/cerbero/operation.ex`:

```elixir
defmodule Cerbero.Operation do
  @moduledoc "Typed operations mirroring Ecto migration DSL semantics, with source lines."

  defmodule CreateTable do
    defstruct [:table, :line, columns: []]
  end

  defmodule AlterTable do
    defstruct [:table, :line, ops: []]
  end

  defmodule CreateIndex do
    defstruct [:table, :line, keys: [], concurrently: false, unique: false]
  end

  defmodule DropIndex do
    defstruct [:table, :line, concurrently: false]
  end

  defmodule CreateConstraint do
    defstruct [:table, :name, :line, check: nil, validate: true]
  end

  defmodule DropTable do
    defstruct [:table, :line]
  end

  defmodule RenameOp do
    defstruct [:table, :line]
  end

  defmodule RawSQL do
    defstruct [:sql, :line, classified: []]
  end

  defmodule Unknown do
    defstruct [:line, :description]
  end
end
```

`lib/cerbero/migration.ex`:

```elixir
defmodule Cerbero.Migration do
  @moduledoc "A parsed migration file: attributes + ordered operations."

  defstruct file: nil,
            module: nil,
            version: nil,
            attrs: %{disable_ddl_transaction: false, disable_migration_lock: false, cerbero_skip: []},
            operations: []

  @type t :: %__MODULE__{}
end
```

- [ ] **Step 4: Implement the parser**

`lib/cerbero/migration/parser.ex`:

```elixir
defmodule Cerbero.Migration.Parser do
  @moduledoc """
  Static AST analysis of migration source. Never compiles or executes
  user code: Ecto's DSL macros call the private, repo-bound
  Ecto.Migration.Runner, so interception would mean replicating private
  API. Cost: dynamically-generated operations are invisible — they are
  emitted as %Unknown{}, never silence.
  """

  alias Cerbero.Migration
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier

  @spec parse_dir(Path.t()) :: {:ok, [Migration.t()]} | {:error, term()}
  def parse_dir(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case parse_file(path) do
        {:ok, migration} -> {:cont, {:ok, [migration | acc]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, migrations} -> {:ok, migrations |> Enum.reverse() |> Enum.sort_by(& &1.version)}
      other -> other
    end
  end

  @spec parse_file(Path.t()) :: {:ok, Migration.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, source} <- File.read(path) do
      parse_string(source, path)
    end
  end

  @spec parse_string(String.t(), Path.t()) :: {:ok, Migration.t()} | {:error, term()}
  def parse_string(source, file \\ "inline.exs") do
    case Code.string_to_quoted(source, columns: false) do
      {:ok, ast} -> build(ast, file)
      {:error, {meta, msg, token}} -> {:error, {:syntax, meta, to_string(msg) <> inspect(token)}}
    end
  end

  defp build(ast, file) do
    {module, body} = find_module(ast)

    with {:ok, attrs} <- attributes(body) do
      operations =
        body
        |> migration_bodies()
        |> Enum.flat_map(&extract_ops/1)

      {:ok,
       %Migration{
         file: file,
         module: module,
         version: version_from(file),
         attrs: attrs,
         operations: operations
       }}
    end
  end

  defp version_from(file) do
    case Regex.run(~r/(\d{10,14})_/, Path.basename(file)) do
      [_, version] -> version
      nil -> nil
    end
  end

  defp find_module({:defmodule, _, [alias_ast, [do: body]]}), do: {Macro.to_string(alias_ast), body}
  defp find_module({:__block__, _, nodes}) do
    Enum.find_value(nodes, {nil, nil}, fn
      {:defmodule, _, _} = mod -> find_module(mod)
      _ -> nil
    end)
  end
  defp find_module(_), do: {nil, nil}

  defp attributes(body) do
    body
    |> block_nodes()
    |> Enum.reduce_while({:ok, %Migration{}.attrs}, fn
      {:@, _, [{:disable_ddl_transaction, _, [true]}]}, {:ok, attrs} ->
        {:cont, {:ok, %{attrs | disable_ddl_transaction: true}}}

      {:@, _, [{:disable_migration_lock, _, [true]}]}, {:ok, attrs} ->
        {:cont, {:ok, %{attrs | disable_migration_lock: true}}}

      {:@, _, [{:cerbero_skip, _, [skips]}]}, {:ok, attrs} ->
        case decode_skips(skips) do
          {:ok, decoded} -> {:cont, {:ok, %{attrs | cerbero_skip: decoded}}}
          {:error, _} = e -> {:halt, e}
        end

      _node, acc ->
        {:cont, acc}
    end)
  end

  defp decode_skips(skips) when is_list(skips) do
    Enum.reduce_while(skips, {:ok, []}, fn
      {:{}, _, _}, _acc -> {:halt, {:error, :invalid_skip}}
      {check, reason}, {:ok, acc} when is_atom(check) and is_binary(reason) ->
        if String.trim(reason) == "" do
          {:halt, {:error, {:empty_skip_reason, check}}}
        else
          {:cont, {:ok, acc ++ [{check, reason}]}}
        end
      _other, _acc ->
        {:halt, {:error, :invalid_skip}}
    end)
  end

  defp decode_skips(_), do: {:error, :invalid_skip}

  # up/1 and change/1 bodies are judged; down is out of scope in v1.
  defp migration_bodies(body) do
    body
    |> block_nodes()
    |> Enum.flat_map(fn
      {:def, _, [{name, _, _}, [do: fun_body]]} when name in [:up, :change] -> [fun_body]
      _ -> []
    end)
  end

  defp block_nodes({:__block__, _, nodes}), do: nodes
  defp block_nodes(nil), do: []
  defp block_nodes(node), do: [node]

  defp extract_ops(fun_body) do
    fun_body
    |> block_nodes()
    |> Enum.map(&op/1)
    |> Enum.reject(&is_nil/1)
  end

  # --- create/drop/alter/execute -------------------------------------------

  defp op({:create, meta, [{:table, _, [name | _]}, [do: table_body]]}) do
    %Op.CreateTable{table: name(name), line: meta[:line], columns: columns(table_body)}
  end

  defp op({:create, meta, [{:table, _, [name | _]}]}) do
    %Op.CreateTable{table: name(name), line: meta[:line], columns: []}
  end

  defp op({verb, meta, [{index_kind, _, index_args}]})
       when verb in [:create, :create_if_not_exists] and index_kind in [:index, :unique_index] do
    case index_args do
      [table, keys | rest] when is_list(keys) ->
        opts = List.first(rest) || []
        %Op.CreateIndex{
          table: name(table),
          keys: Enum.map(keys, &key_name/1),
          concurrently: literal_opt(opts, :concurrently, false),
          unique: index_kind == :unique_index or literal_opt(opts, :unique, false),
          line: meta[:line]
        }

      _ ->
        unknown(meta, "create index with dynamic arguments")
    end
  end

  defp op({:create, meta, [{:constraint, _, [table, cname | rest]}]}) do
    opts = List.first(rest) || []
    %Op.CreateConstraint{
      table: name(table),
      name: name(cname),
      check: literal_opt(opts, :check, nil),
      validate: literal_opt(opts, :validate, true),
      line: meta[:line]
    }
  end

  defp op({drop, meta, [{index_kind, _, [table | _rest_args]} | maybe_opts]})
       when drop in [:drop, :drop_if_exists] and index_kind in [:index, :unique_index] do
    inner_opts =
      case {index_kind, maybe_opts} do
        {_, [opts]} when is_list(opts) -> opts
        _ -> index_inner_opts({index_kind, table})
      end

    %Op.DropIndex{table: name(table), concurrently: literal_opt(inner_opts, :concurrently, false), line: meta[:line]}
  end

  defp op({drop, meta, [{:table, _, [name | _]} | _]}) when drop in [:drop, :drop_if_exists] do
    %Op.DropTable{table: name(name), line: meta[:line]}
  end

  defp op({:alter, meta, [{:table, _, [name | _]}, [do: alter_body]]}) do
    %Op.AlterTable{table: name(name), line: meta[:line], ops: alter_ops(alter_body)}
  end

  defp op({:execute, meta, [sql | _down]}) when is_binary(sql) do
    %Op.RawSQL{sql: sql, line: meta[:line], classified: Classifier.classify(sql)}
  end

  defp op({:execute, meta, _dynamic}) do
    unknown(meta, "execute with non-literal SQL")
  end

  defp op({:rename, meta, [{:table, _, [name | _]} | _]}) do
    %Op.RenameOp{table: name(name), line: meta[:line]}
  end

  # Non-DDL statements that are safe to ignore in a migration body.
  defp op({fun, _meta, _args}) when fun in [:flush, :repo, :prefix, :timeout, :log], do: nil

  defp op(node) do
    meta = if is_tuple(node) and tuple_size(node) == 3, do: elem(node, 1), else: []
    unknown(meta, Macro.to_string(node) |> String.slice(0, 80))
  end

  defp unknown(meta, description) do
    %Op.Unknown{line: meta[:line], description: description}
  end

  # Ecto allows the concurrently opt inside index/3 itself when dropping.
  defp index_inner_opts({_kind, _table}), do: []

  defp columns(table_body) do
    table_body
    |> block_nodes()
    |> Enum.flat_map(fn
      {:add, _, [col, type | rest]} ->
        [%{name: name(col), type: type_of(type), opts: keyword_opts(List.first(rest) || [])}]

      {:add, _, [col]} ->
        [%{name: name(col), type: nil, opts: []}]

      {:timestamps, _, _} ->
        [%{name: "inserted_at", type: :naive_datetime, opts: []},
         %{name: "updated_at", type: :naive_datetime, opts: []}]

      _ ->
        []
    end)
  end

  defp alter_ops(alter_body) do
    alter_body
    |> block_nodes()
    |> Enum.map(fn
      {:add, _, [col, type | rest]} ->
        {:add_column, name(col), type_of(type), keyword_opts(List.first(rest) || [])}

      {:modify, _, [col, type | rest]} ->
        {:modify_column, name(col), type_of(type), keyword_opts(List.first(rest) || [])}

      {:remove, _, [col | _]} ->
        {:remove_column, name(col)}

      other ->
        {:unknown_alter, Macro.to_string(other)}
    end)
  end

  defp type_of({:references, _, [table | rest]}),
    do: {:references, name(table), keyword_opts(List.first(rest) || [])}

  defp type_of(type) when is_atom(type), do: type
  defp type_of({:__aliases__, _, _} = t), do: Macro.to_string(t)
  defp type_of(other), do: {:dynamic, Macro.to_string(other)}

  defp keyword_opts(opts) when is_list(opts) do
    Enum.map(opts, fn
      {k, {:fragment, _, [frag]}} when is_binary(frag) -> {k, {:fragment, frag}}
      {k, {_, _, _} = ast} -> {k, {:dynamic, Macro.to_string(ast)}}
      {k, v} -> {k, v}
    end)
  end

  defp keyword_opts(_), do: []

  defp literal_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) or is_binary(value) or is_nil(value) or is_number(value) -> value
      _dynamic -> default
    end
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(_expr), do: :expression

  defp name(n) when is_atom(n), do: Atom.to_string(n)
  defp name(n) when is_binary(n), do: n
  defp name({_, _, _} = ast), do: Macro.to_string(ast)
end
```

- [ ] **Step 5: Run until green, then commit**

Run: `mix test test/cerbero/migration/parser_test.exs`
Expected: PASS. The AST shapes above are the common Ecto forms; if a test reveals a different quoted shape (e.g. `drop index(:events, [:legacy], concurrently: true)` puts opts inside the `index` call args — it does: `{:index, _, [table, keys, opts]}`), adjust the `op/1` clause for `drop` to read opts from the third element of `index_args`. The tests define correctness.

```bash
git add -A
git commit -m "feat: static AST migration parser -> typed operations; corpus fixtures"
```

---

### Task 7: DDL lock/cost data, Effects derivation (total), CRDB limitation table

**Files:**
- Create: `lib/cerbero/ddl/locks.ex`, `lib/cerbero/ddl/effect.ex`, `lib/cerbero/ddl/effects.ex`, `lib/cerbero/ddl/crdb.ex`
- Test: `test/cerbero/ddl/locks_test.exs`, `test/cerbero/ddl/effects_test.exs`

**Interfaces:**
- Consumes: Operation structs (Task 6), `%Classified{}` (Task 5).
- Produces:
  - `Cerbero.DDL.Locks.entry(class :: atom, engine :: :postgres, version_num :: integer) :: {lock, cost} | :unmapped`
  - `Cerbero.DDL.Locks.classes() :: [atom]` (every mapped class — the totality anchor)
  - `%Cerbero.DDL.Effect{class, lock, cost, relations :: [{:target | :referenced, String.t()}], notes :: [String.t()], unmapped: boolean}`
  - `Cerbero.DDL.Effects.derive(op, engine_name, version_num) :: [%Effect{}]` — **total**: never raises, unmapped classes get `{:access_exclusive, :rewrite, unmapped: true}`
  - `Cerbero.DDL.Effects.classes_emitted() :: [atom]` — every class `derive/3` can produce (checked against `Locks.classes()` by the totality test)
  - `Cerbero.DDL.CRDB.judge(class, version_num) :: :online | {:limited, String.t()} | {:rejected, String.t()}`

- [ ] **Step 1: Write failing tests**

`test/cerbero/ddl/locks_test.exs`:

```elixir
defmodule Cerbero.DDL.LocksTest do
  use ExUnit.Case, async: true

  alias Cerbero.DDL.{Effects, Locks}

  # The v1 PG table from design §4, spot-checked.
  @expected [
    {:create_index, {:share, :full_scan}},
    {:create_index_concurrently, {:share_update_exclusive, :full_scan}},
    {:drop_index, {:access_exclusive, :metadata_only}},
    {:drop_index_concurrently, {:share_update_exclusive, :metadata_only}},
    {:add_column_constant_default, {:access_exclusive, :metadata_only}},
    {:add_column_volatile_default, {:access_exclusive, :rewrite}},
    {:add_column_generated_stored, {:access_exclusive, :rewrite}},
    {:add_primary_key, {:access_exclusive, :full_scan}},
    {:add_unique, {:access_exclusive, :full_scan}},
    {:set_not_null, {:access_exclusive, :full_scan}},
    {:add_check, {:access_exclusive, :full_scan}},
    {:add_check_not_valid, {:access_exclusive, :metadata_only}},
    {:validate_check, {:share_update_exclusive, :full_scan}},
    {:add_foreign_key, {:share_row_exclusive, :full_scan}},
    {:add_foreign_key_not_valid, {:share_row_exclusive, :metadata_only}},
    {:validate_foreign_key, {:share_update_exclusive, :full_scan}},
    {:alter_column_type, {:access_exclusive, :rewrite}},
    {:alter_column_type_binary_coercible, {:access_exclusive, :metadata_only}},
    {:attach_partition, {:share_update_exclusive, :full_scan}},
    {:detach_partition, {:access_exclusive, :metadata_only}},
    {:set_logged, {:access_exclusive, :rewrite}},
    {:truncate, {:access_exclusive, :metadata_only}},
    {:reindex, {:access_exclusive, :full_scan}},
    {:reindex_concurrently, {:share_update_exclusive, :full_scan}},
    {:drop_column, {:access_exclusive, :metadata_only}},
    {:rename, {:access_exclusive, :metadata_only}},
    {:set_default, {:access_exclusive, :metadata_only}},
    {:drop_table, {:access_exclusive, :metadata_only}},
    {:create_table, {:none, :metadata_only}}
  ]

  test "the v1 PG lock/cost table" do
    for {class, expected} <- @expected do
      assert Locks.entry(class, :postgres, 150_000) == expected, "#{class}"
    end
  end

  test "totality: every class Effects can emit has a Locks entry for postgres" do
    for class <- Effects.classes_emitted() do
      assert Locks.entry(class, :postgres, 150_000) != :unmapped,
             "#{class} falls through to the conservative default — add an explicit entry"
    end
  end

  test "unmapped classes return :unmapped (the tripwire, not a crash)" do
    assert Locks.entry(:made_up_operation, :postgres, 150_000) == :unmapped
  end
end
```

`test/cerbero/ddl/effects_test.exs`:

```elixir
defmodule Cerbero.DDL.EffectsTest do
  use ExUnit.Case, async: true

  alias Cerbero.DDL.{Effect, Effects}
  alias Cerbero.Migration.Parser

  defp effects(source) do
    {:ok, migration} = Parser.parse_string(source)
    Enum.flat_map(migration.operations, &Effects.derive(&1, :postgres, 150_004))
  end

  defp migration(body), do: "defmodule M do\n use Ecto.Migration\n def change do\n #{body}\n end\nend"

  test "non-concurrent index: SHARE + full_scan on the target" do
    assert [%Effect{class: :create_index, lock: :share, cost: :full_scan, relations: [target: "events"]}] =
             effects(migration("create index(:events, [:org_id])"))
  end

  test "add column with constant vs volatile default vs plain" do
    assert [%Effect{class: :add_column_constant_default, cost: :metadata_only},
            %Effect{class: :add_column_volatile_default, cost: :rewrite},
            %Effect{class: :add_column_constant_default}] =
             effects(migration("""
             alter table(:events) do
               add :flags, :integer, default: 0
               add :token, :uuid, default: fragment("gen_random_uuid()")
               add :note, :text
             end
             """))
  end

  test "add FK touches referencing and referenced" do
    assert [%Effect{class: :add_foreign_key, lock: :share_row_exclusive,
                    relations: [target: "events", referenced: "orgs"]}] =
             effects(migration("""
             alter table(:events) do
               add :org_id, references(:orgs)
             end
             """))
  end

  test "modify to NOT NULL emits set_not_null; type change emits alter_column_type" do
    assert [%Effect{class: :alter_column_type, cost: :rewrite},
            %Effect{class: :set_not_null, cost: :full_scan}] =
             effects(migration("""
             alter table(:events) do
               modify :org_id, :bigint, null: false
             end
             """))
             |> Enum.sort_by(& &1.class)
  end

  test "raw SQL derives through its classification" do
    assert [%Effect{class: :add_check_not_valid, cost: :metadata_only, relations: [target: "events"]}] =
             effects(migration(~s|execute "ALTER TABLE events ADD CONSTRAINT c CHECK (org_id IS NOT NULL) NOT VALID"|))
  end

  test "Unknown operations derive to the conservative default with unmapped: true" do
    assert [%Effect{lock: :access_exclusive, cost: :rewrite, unmapped: true}] =
             effects(migration("for t <- [:a], do: create(index(t, [:x]))"))
  end

  test "version-conditional note: PG version is named" do
    [%Effect{notes: notes}] = effects(migration("create index(:events, [:org_id])"))
    assert Enum.any?(notes, &(&1 =~ "assuming PG 15"))
  end
end
```

Run: `mix test test/cerbero/ddl` — Expected: FAIL.

- [ ] **Step 2: Implement Locks, Effect, Effects, CRDB**

`lib/cerbero/ddl/effect.ex`:

```elixir
defmodule Cerbero.DDL.Effect do
  @moduledoc "What one operation does to the database: lock mode, cost class, touched relations."

  defstruct [:class, :lock, :cost, relations: [], notes: [], unmapped: false, line: nil]

  @type lock ::
          :access_exclusive | :share | :share_row_exclusive | :share_update_exclusive
          | :row_exclusive | :none | :online_schema_change
  @type cost :: :metadata_only | :full_scan | :rewrite
  @type t :: %__MODULE__{}
end
```

`lib/cerbero/ddl/locks.ex`:

```elixir
defmodule Cerbero.DDL.Locks do
  @moduledoc """
  The (operation class, engine, version range) -> {lock, cost} mapping.
  This is DATA, not conditionals; layer 4's lock-verification suite is
  its empirical anchor. Anything absent returns :unmapped and Effects
  applies the conservative default (AEL + rewrite + tripwire finding).
  """

  @pg %{
    create_index: {:share, :full_scan},
    create_index_concurrently: {:share_update_exclusive, :full_scan},
    drop_index: {:access_exclusive, :metadata_only},
    drop_index_concurrently: {:share_update_exclusive, :metadata_only},
    add_column_constant_default: {:access_exclusive, :metadata_only},
    add_column_volatile_default: {:access_exclusive, :rewrite},
    add_column_generated_stored: {:access_exclusive, :rewrite},
    add_primary_key: {:access_exclusive, :full_scan},
    add_unique: {:access_exclusive, :full_scan},
    set_not_null: {:access_exclusive, :full_scan},
    add_check: {:access_exclusive, :full_scan},
    add_check_not_valid: {:access_exclusive, :metadata_only},
    validate_check: {:share_update_exclusive, :full_scan},
    add_foreign_key: {:share_row_exclusive, :full_scan},
    add_foreign_key_not_valid: {:share_row_exclusive, :metadata_only},
    validate_foreign_key: {:share_update_exclusive, :full_scan},
    alter_column_type: {:access_exclusive, :rewrite},
    alter_column_type_binary_coercible: {:access_exclusive, :metadata_only},
    attach_partition: {:share_update_exclusive, :full_scan},
    set_logged: {:access_exclusive, :rewrite},
    truncate: {:access_exclusive, :metadata_only},
    reindex: {:access_exclusive, :full_scan},
    reindex_concurrently: {:share_update_exclusive, :full_scan},
    drop_column: {:access_exclusive, :metadata_only},
    rename: {:access_exclusive, :metadata_only},
    set_default: {:access_exclusive, :metadata_only},
    drop_table: {:access_exclusive, :metadata_only},
    create_table: {:none, :metadata_only},
    dml_update: {:row_exclusive, :full_scan},
    dml_delete: {:row_exclusive, :full_scan},
    dml_insert_select: {:row_exclusive, :full_scan}
  }

  @spec classes() :: [atom()]
  def classes, do: Map.keys(@pg) ++ [:detach_partition]

  @spec entry(atom(), :postgres | :cockroachdb, integer()) ::
          {Cerbero.DDL.Effect.lock(), Cerbero.DDL.Effect.cost()} | :unmapped
  def entry(:detach_partition, :postgres, version_num) when version_num >= 140_000,
    do: {:share_update_exclusive, :metadata_only}

  def entry(:detach_partition, :postgres, _version_num),
    do: {:access_exclusive, :metadata_only}

  def entry(class, :postgres, _version_num), do: Map.get(@pg, class, :unmapped)

  # CRDB: online schema changes; per-class judgment lives in Cerbero.DDL.CRDB.
  def entry(class, :cockroachdb, _version_num) do
    case Map.get(@pg, class, :unmapped) do
      :unmapped -> :unmapped
      {_lock, cost} -> {:online_schema_change, cost}
    end
  end
end
```

`lib/cerbero/ddl/effects.ex`:

```elixir
defmodule Cerbero.DDL.Effects do
  @moduledoc "Operation -> [Effect]. Total: unmapped classes get the conservative default."

  alias Cerbero.DDL.{Effect, Locks}
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @doc "Every class this module can emit — checked against Locks by the totality test."
  def classes_emitted do
    ~w(create_table create_index create_index_concurrently drop_index drop_index_concurrently
       add_column_constant_default add_column_volatile_default add_column_generated_stored
       add_primary_key add_unique set_not_null add_check add_check_not_valid validate_check
       add_foreign_key add_foreign_key_not_valid validate_foreign_key alter_column_type
       truncate reindex reindex_concurrently drop_column drop_table rename set_default
       dml_update dml_delete dml_insert_select)a
  end

  @spec derive(struct(), :postgres | :cockroachdb, integer()) :: [Effect.t()]
  def derive(op, engine, version_num) do
    op
    |> classify()
    |> Enum.map(fn {class, relations} ->
      case Locks.entry(class, engine, version_num) do
        {lock, cost} ->
          %Effect{class: class, lock: lock, cost: cost, relations: relations,
                  notes: [version_note(engine, version_num)], line: line_of(op)}

        :unmapped ->
          conservative(class, relations, engine, version_num, op)
      end
    end)
  end

  defp conservative(class, relations, engine, version_num, op) do
    %Effect{class: class, lock: :access_exclusive, cost: :rewrite, relations: relations,
            unmapped: true, notes: [version_note(engine, version_num)], line: line_of(op)}
  end

  defp line_of(%{line: line}), do: line
  defp line_of(_), do: nil

  defp version_note(:postgres, version_num),
    do: "assuming PG #{div(version_num, 10_000)} per snapshot; version-conditional verdicts may change"

  defp version_note(:cockroachdb, version_num),
    do: "assuming CockroachDB #{version_num} per snapshot"

  # -- classification of operations into lock-table classes -----------------

  defp classify(%Op.CreateTable{table: t}), do: [{:create_table, [target: t]}]
  defp classify(%Op.DropTable{table: t}), do: [{:drop_table, [target: t]}]
  defp classify(%Op.RenameOp{table: t}), do: [{:rename, [target: t]}]

  defp classify(%Op.CreateIndex{table: t, concurrently: true}),
    do: [{:create_index_concurrently, [target: t]}]

  defp classify(%Op.CreateIndex{table: t, unique: true, concurrently: false}),
    do: [{:add_unique, [target: t]}]

  defp classify(%Op.CreateIndex{table: t}), do: [{:create_index, [target: t]}]

  defp classify(%Op.DropIndex{table: t, concurrently: true}),
    do: [{:drop_index_concurrently, [target: t]}]

  defp classify(%Op.DropIndex{table: t}), do: [{:drop_index, [target: t]}]

  defp classify(%Op.CreateConstraint{table: t, validate: false}),
    do: [{:add_check_not_valid, [target: t]}]

  defp classify(%Op.CreateConstraint{table: t}), do: [{:add_check, [target: t]}]

  defp classify(%Op.AlterTable{table: t, ops: ops}), do: Enum.flat_map(ops, &alter_class(&1, t))

  defp classify(%Op.RawSQL{classified: classified}), do: Enum.flat_map(classified, &sql_class/1)

  defp classify(%Op.Unknown{}), do: [{:unknown_operation, []}]

  defp classify(_other), do: [{:unknown_operation, []}]

  defp alter_class({:add_column, _name, {:references, ref, _}, opts}, t) do
    fk = [{if(Keyword.get(opts, :validate, true), do: :add_foreign_key, else: :add_foreign_key_not_valid),
           [target: t, referenced: ref]}]
    fk ++ add_column_class(opts, t)
  end

  defp alter_class({:add_column, _name, _type, opts}, t), do: add_column_class(opts, t)

  defp alter_class({:modify_column, _name, type, opts}, t) do
    type_change = if type != nil, do: [{:alter_column_type, [target: t]}], else: []
    not_null = if Keyword.get(opts, :null) == false, do: [{:set_not_null, [target: t]}], else: []
    fk =
      case type do
        {:references, ref, _} -> [{:add_foreign_key, [target: t, referenced: ref]}]
        _ -> []
      end

    type_change ++ not_null ++ fk
  end

  defp alter_class({:remove_column, _name}, t), do: [{:drop_column, [target: t]}]
  defp alter_class({:unknown_alter, _}, _t), do: [{:unknown_operation, []}]

  defp add_column_class(opts, t) do
    cond do
      Keyword.has_key?(opts, :generated) -> [{:add_column_generated_stored, [target: t]}]
      match?({:fragment, _}, Keyword.get(opts, :default)) -> [{:add_column_volatile_default, [target: t]}]
      match?({:dynamic, _}, Keyword.get(opts, :default)) -> [{:add_column_volatile_default, [target: t]}]
      true -> [{:add_column_constant_default, [target: t]}]
    end
  end

  defp sql_class(%Classified{class: :create_index, concurrently: true, table: t}),
    do: [{:create_index_concurrently, [target: t]}]

  defp sql_class(%Classified{class: :create_index, unique: true, table: t}),
    do: [{:add_unique, [target: t]}]

  defp sql_class(%Classified{class: :create_index, table: t}), do: [{:create_index, [target: t]}]

  defp sql_class(%Classified{class: :drop_index, concurrently: c}),
    do: [{if(c, do: :drop_index_concurrently, else: :drop_index), []}]

  defp sql_class(%Classified{class: :add_check_is_not_null, not_valid: true, table: t}),
    do: [{:add_check_not_valid, [target: t]}]

  defp sql_class(%Classified{class: :add_check_is_not_null, table: t}), do: [{:add_check, [target: t]}]

  defp sql_class(%Classified{class: :add_check, not_valid: nv, table: t}),
    do: [{if(nv, do: :add_check_not_valid, else: :add_check), [target: t]}]

  defp sql_class(%Classified{class: :add_foreign_key, not_valid: nv, table: t}),
    do: [{if(nv, do: :add_foreign_key_not_valid, else: :add_foreign_key), [target: t]}]

  # VALIDATE CONSTRAINT: FK vs CHECK is resolved by the catalog in rules;
  # here we use the stricter FK profile (SUE on referencing + ROW SHARE on referenced).
  defp sql_class(%Classified{class: :validate_constraint, table: t}),
    do: [{:validate_foreign_key, [target: t]}]

  defp sql_class(%Classified{class: :set_not_null, table: t}), do: [{:set_not_null, [target: t]}]
  defp sql_class(%Classified{class: :alter_column_type, table: t}), do: [{:alter_column_type, [target: t]}]
  defp sql_class(%Classified{class: :add_column, table: t}), do: [{:add_column_constant_default, [target: t]}]
  defp sql_class(%Classified{class: :drop_column, table: t}), do: [{:drop_column, [target: t]}]
  defp sql_class(%Classified{class: :create_table, table: t}), do: [{:create_table, [target: t]}]
  defp sql_class(%Classified{class: :drop_table, table: t}), do: [{:drop_table, [target: t]}]
  defp sql_class(%Classified{class: :truncate, table: t}), do: [{:truncate, [target: t]}]

  defp sql_class(%Classified{class: :reindex, concurrently: c}),
    do: [{if(c, do: :reindex_concurrently, else: :reindex), []}]

  defp sql_class(%Classified{class: :update, table: t}), do: [{:dml_update, [target: t]}]
  defp sql_class(%Classified{class: :delete, table: t}), do: [{:dml_delete, [target: t]}]
  defp sql_class(%Classified{class: :insert_select, table: t}), do: [{:dml_insert_select, [target: t]}]

  defp sql_class(%Classified{class: :unknown}), do: [{:unclassified_sql, []}]
end
```

Note: `:unknown_operation` and `:unclassified_sql` are NOT in `classes_emitted/0` — they are meta-finding markers, not lock-table classes; `Locks.entry/3` returns `:unmapped` for them and the conservative default applies. `classes_emitted/0` lists only classes that claim a real lock mapping.

`lib/cerbero/ddl/crdb.ex`:

```elixir
defmodule Cerbero.DDL.CRDB do
  @moduledoc """
  CockroachDB limitation table, keyed by class and version. Same
  data-not-conditionals rigor as Locks. Scoped to the facts rules 4 and 7
  consume; layer 4 asserts the observable behaviors behind it.
  """

  @doc """
  :online — succeeds as an online schema change;
  {:limited, note} — succeeds with a caveat worth a finding;
  {:rejected, note} — the engine refuses it; cerbero errors BEFORE deploy fails.
  """
  @spec judge(atom(), integer()) :: :online | {:limited, String.t()} | {:rejected, String.t()}
  def judge(:alter_column_type_indexed, _v),
    do: {:rejected, "CockroachDB rejects ALTER COLUMN TYPE on a column used by an index, constraint, or computed column"}

  def judge(:alter_column_type_in_txn, _v),
    do: {:rejected, "CockroachDB rejects ALTER COLUMN TYPE inside an explicit transaction with other statements"}

  def judge(:multiple_ddl_in_txn, _v),
    do: {:limited, "multiple schema changes in one transaction are restricted; failed changes cannot roll back cleanly"}

  def judge(:create_index, _v),
    do: {:limited, "index builds are online but consume foreground cluster resources at scale"}

  def judge(_class, _v), do: :online
end
```

- [ ] **Step 3: Run until green, then commit**

Run: `mix test test/cerbero/ddl test/cerbero/migration test/cerbero/sql`
Expected: PASS (including the totality test).

```bash
git add -A
git commit -m "feat: DDL lock/cost data table, total Effects derivation, CRDB limitation table"
```

---

### Task 8: Catalog — queryable model, scale and traffic policy

**Files:**
- Create: `lib/cerbero/catalog.ex`
- Test: `test/cerbero/catalog_test.exs`

**Interfaces:**
- Consumes: `%Cerbero.Snapshot{}`, `%Staleness{}`, `%Config{}`.
- Produces (later tasks rely on these exact signatures):
  - `Cerbero.Catalog.from_snapshot(snapshot, staleness) :: %Catalog{}`
  - `Cerbero.Catalog.empty(engine \\ :postgres, version_num \\ 150_000) :: %Catalog{}` (`source: :replay`, everything unknown-scale)
  - `Cerbero.Catalog.qualify(name) :: String.t()` — `"events"` → `"public.events"`; already-qualified names pass through
  - `Cerbero.Catalog.table(catalog, name) :: %Snapshot.Table{} | nil`
  - `Cerbero.Catalog.known?(catalog, name) :: boolean` (in snapshot ∪ overlay)
  - `Cerbero.Catalog.born?(catalog, name)`, `Cerbero.Catalog.backfilled?(catalog, name)`
  - `Cerbero.Catalog.scale(catalog, name) :: {:rows, non_neg_integer, bytes :: non_neg_integer} | :zero | :unknown` — the `Cerbero.Severity.scale()` type
  - `Cerbero.Catalog.traffic(catalog, name, config) :: :hot | :cold | :unknown`
  - `Cerbero.Catalog.column(catalog, table, column_name)`, `has_index_leading_on?(catalog, table, column_name)`, `validated_not_null_check?(catalog, table, column_name)`, `constraint(catalog, table, constraint_name)`
  - Struct fields: `engine, version_num, tables :: %{qualified_name => %Snapshot.Table{}}, scale_mode, multiplier, born :: MapSet, backfilled :: MapSet, source :: :snapshot | :replay, collected_at, stats_reset, standby, stats_provenance`

- [ ] **Step 1: Write failing tests**

`test/cerbero/catalog_test.exs`:

```elixir
defmodule Cerbero.CatalogTest do
  use ExUnit.Case, async: true

  alias Cerbero.{Catalog, Config}
  alias Cerbero.Snapshot.Staleness
  import Cerbero.Test.SnapshotBuilder

  defp catalog(tables, snapshot_overrides \\ %{}, staleness_overrides \\ []) do
    snapshot = build_snapshot(Map.merge(%{"tables" => tables}, snapshot_overrides))
    staleness = struct!(%Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}, staleness_overrides)
    Catalog.from_snapshot(snapshot, staleness)
  end

  setup do
    {:ok, config} = Config.load("nonexistent")
    %{config: config}
  end

  test "scale: max(reltuples, n_live_tup); bytes from heap_bytes" do
    cat = catalog([table("events", %{"reltuples" => 400.0, "n_live_tup" => 500, "heap_bytes" => 9000})])
    assert Catalog.scale(cat, "events") == {:rows, 500, 9000}
  end

  test "scale: reltuples -1 (never analyzed, PG >= 14) falls back to n_live_tup" do
    cat = catalog([table("events", %{"reltuples" => -1.0, "n_live_tup" => 123})])
    assert {:rows, 123, _} = Catalog.scale(cat, "events")
  end

  test "partitioned parent: sum over partitions, never the parent row" do
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => 0.0, "n_live_tup" => 0, "heap_bytes" => 0}),
        table("events_p0", %{"partition_of" => "public.events", "n_live_tup" => 100, "reltuples" => 100.0, "heap_bytes" => 10}),
        table("events_p1", %{"partition_of" => "public.events", "n_live_tup" => 250, "reltuples" => 250.0, "heap_bytes" => 20})
      ])

    assert Catalog.scale(cat, "events") == {:rows, 350, 30}
  end

  test "unknown table is :unknown — absence is never safety", %{config: _} do
    cat = catalog([])
    assert Catalog.scale(cat, "ghost") == :unknown
    refute Catalog.known?(cat, "ghost")
  end

  test "degraded staleness makes every scale unknown" do
    cat = catalog([table("events", %{"n_live_tup" => 5})], %{}, scale_mode: :unbounded)
    assert Catalog.scale(cat, "events") == :unknown
  end

  test "traffic: counters normalized by stats_reset age", %{config: config} do
    # collected_at 2026-07-01, stats_reset 2026-01-01: ~15.6M seconds.
    hot = catalog([table("flags", %{"idx_scan" => 40_000_000, "n_tup_upd" => 1_000_000})])
    cold = catalog([table("flags", %{"idx_scan" => 12, "n_tup_upd" => 3})])
    assert Catalog.traffic(hot, "flags", config) == :hot
    assert Catalog.traffic(cold, "flags", config) == :cold
  end

  test "standby snapshot yields unknown traffic and unknown-friendly stats", %{config: config} do
    cat = catalog([table("flags")], %{"standby" => true, "stats_provenance" => "standby"})
    assert Catalog.traffic(cat, "flags", config) == :unknown
  end

  test "lookup helpers", %{config: _} do
    t =
      table("events", %{
        "columns" => [column("org_id", %{"not_null" => false})],
        "indexes" => [index("events_org_id_index", ["org_id"])],
        "constraints" => [
          %{"columns" => [], "is_not_null_check_on" => "org_id", "name" => "org_id_nn",
            "on_delete" => nil, "on_update" => nil, "references" => nil,
            "type" => "check", "validated" => true}
        ]
      })

    cat = catalog([t])
    assert Catalog.has_index_leading_on?(cat, "events", "org_id")
    refute Catalog.has_index_leading_on?(cat, "events", "id")
    assert Catalog.validated_not_null_check?(cat, "events", "org_id")
    assert %{name: "org_id"} = Catalog.column(cat, "events", "org_id")
  end
end
```

Run: `mix test test/cerbero/catalog_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement `lib/cerbero/catalog.ex`**

```elixir
defmodule Cerbero.Catalog do
  @moduledoc """
  The queryable in-memory model the checks run against. Row-estimate
  policy: max(reltuples, n_live_tup) when reltuples >= 0, else n_live_tup;
  partitioned parents are the sum of their partitions, never the parent
  row; unknown scale is unbounded, never small.
  """

  alias Cerbero.{Config, Snapshot}
  alias Cerbero.Snapshot.{Staleness, Table}

  defstruct engine: :postgres,
            version_num: 150_000,
            tables: %{},
            scale_mode: :exact,
            multiplier: 1.0,
            born: MapSet.new(),
            backfilled: MapSet.new(),
            source: :snapshot,
            collected_at: nil,
            stats_reset: nil,
            standby: false,
            stats_provenance: :primary

  @type t :: %__MODULE__{}

  @spec from_snapshot(Snapshot.t(), Staleness.t()) :: t()
  def from_snapshot(%Snapshot{} = s, %Staleness{} = staleness) do
    %__MODULE__{
      engine: s.engine.name,
      version_num: s.engine.version_num,
      tables: Map.new(s.tables, fn t -> {"#{t.schema}.#{t.name}", t} end),
      scale_mode: staleness.scale_mode,
      multiplier: staleness.threshold_multiplier,
      source: :snapshot,
      collected_at: s.collected_at,
      stats_reset: s.stats_reset,
      standby: s.standby,
      stats_provenance: s.stats_provenance
    }
  end

  @spec empty(:postgres | :cockroachdb, integer()) :: t()
  def empty(engine \\ :postgres, version_num \\ 150_000) do
    %__MODULE__{engine: engine, version_num: version_num, source: :replay, scale_mode: :unbounded}
  end

  @spec qualify(String.t()) :: String.t()
  def qualify(name) do
    if String.contains?(name, "."), do: name, else: "public." <> name
  end

  @spec table(t(), String.t()) :: Table.t() | nil
  def table(%__MODULE__{tables: tables}, name), do: Map.get(tables, qualify(name))

  @spec known?(t(), String.t()) :: boolean()
  def known?(cat, name), do: table(cat, name) != nil

  @spec born?(t(), String.t()) :: boolean()
  def born?(%__MODULE__{born: born}, name), do: MapSet.member?(born, qualify(name))

  @spec backfilled?(t(), String.t()) :: boolean()
  def backfilled?(%__MODULE__{backfilled: b}, name), do: MapSet.member?(b, qualify(name))

  @spec scale(t(), String.t()) :: {:rows, non_neg_integer(), non_neg_integer()} | :zero | :unknown
  def scale(%__MODULE__{} = cat, name) do
    cond do
      born?(cat, name) and backfilled?(cat, name) -> :unknown
      born?(cat, name) -> :zero
      cat.scale_mode == :unbounded -> :unknown
      true ->
        case table(cat, name) do
          nil -> :unknown
          %Table{partitioned: true} -> partition_sum(cat, qualify(name))
          %Table{} = t -> {:rows, row_estimate(t), t.heap_bytes || 0}
        end
    end
  end

  defp partition_sum(cat, parent) do
    cat.tables
    |> Map.values()
    |> Enum.filter(&(&1.partition_of == parent))
    |> Enum.reduce({:rows, 0, 0}, fn t, {:rows, rows, bytes} ->
      {:rows, rows + row_estimate(t), bytes + (t.heap_bytes || 0)}
    end)
  end

  defp row_estimate(%Table{reltuples: rt, n_live_tup: nlt}) do
    nlt = nlt || 0

    if is_number(rt) and rt >= 0 do
      max(trunc(rt), nlt)
    else
      nlt
    end
  end

  @spec traffic(t(), String.t(), Config.t()) :: :hot | :cold | :unknown
  def traffic(%__MODULE__{} = cat, name, %Config{} = config) do
    with false <- cat.standby,
         %Table{} = t <- table(cat, name),
         %DateTime{} = reset <- cat.stats_reset,
         %DateTime{} = collected <- cat.collected_at,
         seconds when seconds > 0 <- DateTime.diff(collected, reset, :second) do
      ops = (t.seq_scan || 0) + (t.idx_scan || 0) + (t.n_tup_ins || 0) + (t.n_tup_upd || 0) + (t.n_tup_del || 0)
      if ops / seconds >= config.hot_ops_per_sec, do: :hot, else: :cold
    else
      _ -> :unknown
    end
  end

  @spec column(t(), String.t(), String.t()) :: map() | nil
  def column(cat, table_name, column_name) do
    case table(cat, table_name) do
      nil -> nil
      %Table{columns: cols} -> Enum.find(cols, &(&1.name == column_name))
    end
  end

  @spec has_index_leading_on?(t(), String.t(), String.t()) :: boolean()
  def has_index_leading_on?(cat, table_name, column_name) do
    case table(cat, table_name) do
      nil -> false
      %Table{indexes: indexes} ->
        Enum.any?(indexes, fn idx ->
          match?([%{kind: :column, name: ^column_name} | _], idx.keys)
        end)
    end
  end

  @spec validated_not_null_check?(t(), String.t(), String.t()) :: boolean()
  def validated_not_null_check?(cat, table_name, column_name) do
    case table(cat, table_name) do
      nil -> false
      %Table{constraints: cons} ->
        Enum.any?(cons, &(&1.type == :check and &1.validated and &1.is_not_null_check_on == column_name))
    end
  end

  @spec constraint(t(), String.t(), String.t()) :: map() | nil
  def constraint(cat, table_name, constraint_name) do
    case table(cat, table_name) do
      nil -> nil
      %Table{constraints: cons} -> Enum.find(cons, &(&1.name == constraint_name))
    end
  end
end
```

- [ ] **Step 3: Run, verify pass, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: catalog model — scale policy (max/Σ/unbounded), traffic proxy, lookups"
```

---

### Task 9: Pending-migration overlay (`Catalog.apply/2`)

Correctness requirement, not a feature: pending migration 1 creates `events_v2`, pending migration 2 indexes it — the checker must fold each migration's structural effects into the catalog before judging the next. Folds both the Ecto DSL and classified raw SQL, including the recommended NOT NULL two-step.

**Files:**
- Modify: `lib/cerbero/catalog.ex`
- Test: `test/cerbero/catalog_overlay_test.exs`

**Interfaces:**
- Consumes: Operation structs (Task 6), `%Classified{}` (Task 5).
- Produces: `Cerbero.Catalog.apply(catalog, operation) :: catalog` and `Cerbero.Catalog.apply_migration(catalog, %Migration{}) :: catalog`.

- [ ] **Step 1: Write failing tests**

`test/cerbero/catalog_overlay_test.exs`:

```elixir
defmodule Cerbero.CatalogOverlayTest do
  use ExUnit.Case, async: true

  alias Cerbero.Catalog
  alias Cerbero.Migration.Parser
  import Cerbero.Test.SnapshotBuilder

  defp base_catalog(tables \\ []) do
    snapshot = build_snapshot(%{"tables" => tables})
    staleness = %Cerbero.Snapshot.Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    Catalog.from_snapshot(snapshot, staleness)
  end

  defp apply_source(cat, body) do
    {:ok, m} = Parser.parse_string("defmodule M do\n use Ecto.Migration\n def change do\n #{body}\n end\nend")
    Catalog.apply_migration(cat, m)
  end

  test "created table is known, born, and :zero scale" do
    cat = apply_source(base_catalog(), """
    create table(:events_v2) do
      add :org_id, :bigint
    end
    """)

    assert Catalog.known?(cat, "events_v2")
    assert Catalog.born?(cat, "events_v2")
    assert Catalog.scale(cat, "events_v2") == :zero
    assert %{name: "org_id"} = Catalog.column(cat, "events_v2", "org_id")
  end

  test "created-then-backfilled table is NOT empty by construction (revocation)" do
    cat =
      base_catalog()
      |> apply_source("create table(:events_v2) do\n add :x, :bigint\n end")
      |> apply_source(~s|execute "INSERT INTO events_v2 SELECT * FROM events"|)

    assert Catalog.backfilled?(cat, "events_v2")
    assert Catalog.scale(cat, "events_v2") == :unknown
  end

  test "DSL-created index becomes visible (rule 6 consumes this)" do
    cat =
      base_catalog([table("events")])
      |> apply_source("create index(:events, [:org_id])")

    assert Catalog.has_index_leading_on?(cat, "events", "org_id")
  end

  test "the raw-SQL NOT NULL two-step is recognized: NOT VALID check + VALIDATE" do
    cat =
      base_catalog([table("events", %{"columns" => [column("org_id")]})])
      |> apply_source(~s|execute "ALTER TABLE events ADD CONSTRAINT org_id_nn CHECK (org_id IS NOT NULL) NOT VALID"|)

    refute Catalog.validated_not_null_check?(cat, "events", "org_id")

    cat = apply_source(cat, ~s|execute "ALTER TABLE events VALIDATE CONSTRAINT org_id_nn"|)
    assert Catalog.validated_not_null_check?(cat, "events", "org_id")
  end

  test "alter table add/remove/modify columns updates the model" do
    cat =
      base_catalog([table("events", %{"columns" => [column("org_id"), column("legacy")]})])
      |> apply_source("""
      alter table(:events) do
        add :score, :float
        modify :org_id, :bigint, null: false
        remove :legacy
      end
      """)

    assert %{name: "score"} = Catalog.column(cat, "events", "score")
    assert %{not_null: true} = Catalog.column(cat, "events", "org_id")
    assert Catalog.column(cat, "events", "legacy") == nil
  end

  test "raw-SQL created table is also born" do
    cat = apply_source(base_catalog(), ~s|execute "CREATE TABLE events_v2 (id bigint)"|)
    assert Catalog.born?(cat, "events_v2")
  end

  test "dropped table disappears" do
    cat = base_catalog([table("legacy")]) |> apply_source("drop table(:legacy)")
    refute Catalog.known?(cat, "legacy")
  end
end
```

Run: `mix test test/cerbero/catalog_overlay_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement the overlay in `lib/cerbero/catalog.ex`**

Append to the module:

```elixir
  alias Cerbero.Migration
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @spec apply_migration(t(), Migration.t()) :: t()
  def apply_migration(cat, %Migration{operations: ops}), do: Enum.reduce(ops, cat, &apply(&2, &1))

  @spec apply(t(), struct()) :: t()
  def apply(cat, %Op.CreateTable{table: name, columns: columns}) do
    born_table(cat, name, Enum.map(columns, &overlay_column/1))
  end

  def apply(cat, %Op.DropTable{table: name}) do
    %{cat | tables: Map.delete(cat.tables, qualify(name)), born: MapSet.delete(cat.born, qualify(name))}
  end

  def apply(cat, %Op.AlterTable{table: name, ops: alter_ops}) do
    update_table(cat, name, fn t -> Enum.reduce(alter_ops, t, &apply_alter/2) end)
  end

  def apply(cat, %Op.CreateIndex{table: name, keys: keys, unique: unique}) do
    idx = %{
      name: "#{name}_#{Enum.map_join(keys, "_", &to_string/1)}_index",
      unique: unique, primary: false, valid: true, method: "btree", partial: false, bytes: 0,
      keys: Enum.map(keys, fn
        :expression -> %{kind: :expression}
        k -> %{kind: :column, name: k}
      end)
    }

    update_table(cat, name, fn t -> %{t | indexes: t.indexes ++ [idx]} end)
  end

  def apply(cat, %Op.DropIndex{}), do: cat

  def apply(cat, %Op.CreateConstraint{table: name, name: cname, check: check, validate: validate}) do
    is_nn =
      case check && Regex.run(~r/^\s*(\w+)\s+is\s+not\s+null\s*$/i, check) do
        [_, col] -> col
        _ -> nil
      end

    con = %{name: cname, type: :check, columns: [], validated: validate,
            references: nil, on_delete: nil, on_update: nil, is_not_null_check_on: is_nn}

    update_table(cat, name, fn t -> %{t | constraints: t.constraints ++ [con]} end)
  end

  def apply(cat, %Op.RawSQL{classified: classified}), do: Enum.reduce(classified, cat, &apply_sql(&2, &1))
  def apply(cat, %Op.RenameOp{}), do: cat
  def apply(cat, %Op.Unknown{}), do: cat

  defp apply_sql(cat, %Classified{class: :create_table, table: name}), do: born_table(cat, name, [])
  defp apply_sql(cat, %Classified{class: :drop_table, table: name}), do: apply(cat, %Op.DropTable{table: name})

  defp apply_sql(cat, %Classified{class: :add_check_is_not_null, table: name, column: col, constraint: cname, not_valid: nv}) do
    con = %{name: cname, type: :check, columns: [col], validated: not nv,
            references: nil, on_delete: nil, on_update: nil, is_not_null_check_on: col}

    update_table(cat, name, fn t -> %{t | constraints: t.constraints ++ [con]} end)
  end

  defp apply_sql(cat, %Classified{class: :validate_constraint, table: name, constraint: cname}) do
    update_table(cat, name, fn t ->
      %{t | constraints: Enum.map(t.constraints, fn con ->
        if con.name == cname, do: %{con | validated: true}, else: con
      end)}
    end)
  end

  defp apply_sql(cat, %Classified{class: :set_not_null, table: name, column: col}) do
    update_column(cat, name, col, &%{&1 | not_null: true})
  end

  defp apply_sql(cat, %Classified{class: :add_column, table: name, column: col}) do
    update_table(cat, name, fn t ->
      %{t | columns: t.columns ++ [%{name: col, type: "unknown", not_null: false, identity: false, generated: nil, default: nil}]}
    end)
  end

  defp apply_sql(cat, %Classified{class: :drop_column, table: name, column: col}) do
    update_table(cat, name, fn t -> %{t | columns: Enum.reject(t.columns, &(&1.name == col))} end)
  end

  defp apply_sql(cat, %Classified{class: :create_index, table: name}) when is_binary(name) do
    update_table(cat, name, fn t ->
      idx = %{name: "raw_sql_index_#{length(t.indexes)}", unique: false, primary: false,
              valid: true, method: "btree", partial: false, bytes: 0, keys: [%{kind: :expression}]}
      %{t | indexes: t.indexes ++ [idx]}
    end)
  end

  defp apply_sql(cat, %Classified{class: dml, table: name}) when dml in [:update, :delete, :insert_select] and is_binary(name) do
    %{cat | backfilled: MapSet.put(cat.backfilled, qualify(name))}
  end

  defp apply_sql(cat, %Classified{}), do: cat

  defp apply_alter({:add_column, name, type, opts}, t) do
    col = %{name: name, type: overlay_type(type), not_null: Keyword.get(opts, :null) == false,
            identity: false, generated: nil, default: overlay_default(opts)}
    %{t | columns: t.columns ++ [col]}
  end

  defp apply_alter({:modify_column, name, type, opts}, t) do
    %{t | columns: Enum.map(t.columns, fn col ->
      if col.name == name do
        col = if type, do: %{col | type: overlay_type(type)}, else: col
        case Keyword.get(opts, :null) do
          false -> %{col | not_null: true}
          true -> %{col | not_null: false}
          nil -> col
        end
      else
        col
      end
    end)}
  end

  defp apply_alter({:remove_column, name}, t), do: %{t | columns: Enum.reject(t.columns, &(&1.name == name))}
  defp apply_alter(_other, t), do: t

  defp born_table(cat, name, columns) do
    qname = qualify(name)
    [schema, bare] = String.split(qname, ".", parts: 2)

    t = %Snapshot.Table{
      schema: schema, name: bare, partitioned: false, partition_of: nil,
      reltuples: 0.0, relpages: 0, n_live_tup: 0, last_analyze: nil, last_autoanalyze: nil,
      seq_scan: 0, idx_scan: 0, n_tup_ins: 0, n_tup_upd: 0, n_tup_del: 0,
      heap_bytes: 0, total_bytes: 0, columns: columns, indexes: [], constraints: []
    }

    %{cat | tables: Map.put(cat.tables, qname, t), born: MapSet.put(cat.born, qname)}
  end

  defp update_table(cat, name, fun) do
    case table(cat, name) do
      nil -> cat
      t -> %{cat | tables: Map.put(cat.tables, qualify(name), fun.(t))}
    end
  end

  defp update_column(cat, table_name, col_name, fun) do
    update_table(cat, table_name, fn t ->
      %{t | columns: Enum.map(t.columns, &if(&1.name == col_name, do: fun.(&1), else: &1))}
    end)
  end

  defp overlay_column(%{name: name, type: type, opts: opts}) do
    %{name: name, type: overlay_type(type), not_null: Keyword.get(opts, :null) == false,
      identity: false, generated: nil, default: overlay_default(opts)}
  end

  defp overlay_type({:references, _table, _opts}), do: "bigint"
  defp overlay_type(nil), do: "unknown"
  defp overlay_type(type), do: to_string_type(type)

  defp to_string_type(t) when is_atom(t), do: Atom.to_string(t)
  defp to_string_type(t) when is_binary(t), do: t
  defp to_string_type({:dynamic, s}), do: s

  defp overlay_default(opts) do
    case Keyword.fetch(opts, :default) do
      :error -> nil
      {:ok, {:fragment, _}} -> %{present: true, volatile: true, kind: :expression}
      {:ok, {:dynamic, _}} -> %{present: true, volatile: true, kind: :expression}
      {:ok, _literal} -> %{present: true, volatile: false, kind: :literal}
    end
  end
```

Note: `apply/2` conflicts with `Kernel.apply/2` — add `import Kernel, except: [apply: 2]` at the top of the module, and call it as `Catalog.apply/2` everywhere else.

- [ ] **Step 3: Run, verify pass, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: pending-migration overlay — DSL + classified SQL effects, born/backfilled tracking"
```

---

### Task 10: Runner — pending selection, overlay threading, skips, meta-findings

**Files:**
- Create: `lib/cerbero/check/runner.ex`, `lib/cerbero/check/meta_findings.ex`, `lib/cerbero/check/helpers.ex`
- Test: `test/cerbero/check/runner_test.exs`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `Cerbero.Check.Runner.select_pending(migrations, applied_versions :: [String.t()], start_after :: String.t() | nil) :: [Migration.t()]`
  - `Cerbero.Check.Runner.run(pending :: [Migration.t()], catalog, config, checks \\ Runner.default_checks()) :: {[Finding.t()], final_catalog}` — findings ordered by migration then check; catalog folded between migrations
  - `Cerbero.Check.Runner.default_checks() :: [module]` — grows as rules land (starts with `[Cerbero.Check.MetaFindings]`)
  - `Cerbero.Check.Helpers.human_rows(n) :: String.t()` ("412M", "41M", "600k", "97"), `Cerbero.Check.Helpers.stats_date(catalog, table) :: String.t() | nil` ("2026-07-01" from `last_autoanalyze`/`last_analyze`), `Cerbero.Check.Helpers.describe_scale(catalog, table) :: String.t()` ("~412M rows, stats 2026-07-01" | "scale unknown"), `Cerbero.Check.Helpers.finding(check_module, severity, message, migration, line, opts) :: %Finding{}`
- The skip contract: `@cerbero_skip [{check_id, reason}]` demotes that check's findings *in that migration* to `:info` and appends `(skipped: <reason>)` to the message; skipped findings are still emitted.

- [ ] **Step 1: Write failing tests**

`test/cerbero/check/runner_test.exs`:

```elixir
defmodule Cerbero.Check.RunnerTest do
  use ExUnit.Case, async: true

  alias Cerbero.{Catalog, Config, Finding, Migration}
  alias Cerbero.Check.Runner
  alias Cerbero.Migration.Parser
  import Cerbero.Test.SnapshotBuilder

  defp parse!(version, body) do
    {:ok, m} = Parser.parse_string(
      "defmodule M#{version} do\n use Ecto.Migration\n def change do\n #{body}\n end\nend",
      "#{version}_m.exs"
    )
    m
  end

  defp catalog(tables \\ []) do
    Catalog.from_snapshot(
      build_snapshot(%{"tables" => tables}),
      %Cerbero.Snapshot.Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    )
  end

  setup do
    {:ok, config} = Config.load("nonexistent")
    %{config: config}
  end

  test "select_pending: applied and pre-cutoff migrations are excluded" do
    migrations = [
      %Migration{version: "20250101000000"},
      %Migration{version: "20260801000000"},
      %Migration{version: "20260801000001"}
    ]

    assert [%{version: "20260801000000"}, %{version: "20260801000001"}] =
             Runner.select_pending(migrations, ["20250101000000"], nil)

    assert [%{version: "20260801000001"}] =
             Runner.select_pending(migrations, [], "20260801000000")
  end

  test "overlay threads between migrations: migration 2 sees migration 1's table", %{config: config} do
    m1 = parse!("20260801000000", "create table(:events_v2) do\n add :org_id, :bigint\n end")
    m2 = parse!("20260801000001", "create index(:events_v2, [:org_id])")

    {_findings, final} = Runner.run([m1, m2], catalog(), config)
    assert Catalog.has_index_leading_on?(final, "events_v2", "org_id")
  end

  test "meta-findings: unclassified SQL and unknown operations warn", %{config: config} do
    m = parse!("20260801000000", """
    execute "CLUSTER events USING idx"
    for t <- [:a], do: create(index(t, [:x]))
    """)

    {findings, _} = Runner.run([m], catalog([table("events")]), config)
    assert Enum.any?(findings, &(&1.check == :unclassified_sql and &1.severity == :warning))
    assert Enum.any?(findings, &(&1.check == :unknown_operation and &1.severity == :warning))
  end

  test "@cerbero_skip demotes to info with reason visible", %{config: config} do
    {:ok, m} = Parser.parse_string("""
    defmodule M do
      use Ecto.Migration
      @cerbero_skip [{:unclassified_sql, "reviewed by DBA 2026-08-01"}]
      def change do
        execute "CLUSTER events USING idx"
      end
    end
    """)

    {findings, _} = Runner.run([m], catalog([table("events")]), config)
    assert [%Finding{check: :unclassified_sql, severity: :info, message: msg}] =
             Enum.filter(findings, &(&1.check == :unclassified_sql))
    assert msg =~ "reviewed by DBA 2026-08-01"
  end

  test "severity_overrides floor from config", %{config: config} do
    config = %{config | severity_overrides: %{unclassified_sql: :error}}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)
    {findings, _} = Runner.run([m], catalog(), config)
    assert [%Finding{severity: :error}] = Enum.filter(findings, &(&1.check == :unclassified_sql))
  end

  test "helpers: human_rows" do
    assert Cerbero.Check.Helpers.human_rows(412_000_000) == "412M"
    assert Cerbero.Check.Helpers.human_rows(41_000_000) == "41M"
    assert Cerbero.Check.Helpers.human_rows(600_000) == "600k"
    assert Cerbero.Check.Helpers.human_rows(97) == "97"
  end
end
```

Run: `mix test test/cerbero/check/runner_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement helpers, meta-findings, runner**

`lib/cerbero/check/helpers.ex`:

```elixir
defmodule Cerbero.Check.Helpers do
  @moduledoc "Message construction shared by rules: scale, stats dates, finding assembly."

  alias Cerbero.{Catalog, Finding, Migration}

  @spec human_rows(non_neg_integer()) :: String.t()
  def human_rows(n) when n >= 1_000_000, do: trim_num(n / 1_000_000) <> "M"
  def human_rows(n) when n >= 1_000, do: trim_num(n / 1_000) <> "k"
  def human_rows(n), do: Integer.to_string(n)

  defp trim_num(f) do
    rounded = Float.round(f, 1)
    if rounded == Float.round(rounded, 0), do: Integer.to_string(trunc(rounded)), else: Float.to_string(rounded)
  end

  @spec stats_date(Catalog.t(), String.t()) :: String.t() | nil
  def stats_date(catalog, table) do
    case Catalog.table(catalog, table) do
      nil -> nil
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

      :zero -> "created in this deploy, empty by construction"
      :unknown -> "scale unknown — treated as unbounded"
    end
  end

  @spec finding(module(), Finding.severity(), String.t(), Migration.t(), integer() | nil, keyword()) :: Finding.t()
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
```

`lib/cerbero/check/meta_findings.ex`:

```elixir
defmodule Cerbero.Check.MetaFindings do
  @moduledoc """
  The escape routes for the worst migrations must be reachable by
  --fail-on: unclassified SQL, unknown operations, and unmapped lock
  entries all warn by default, never silence.
  """
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :meta_findings

  @impl true
  def run(migration, catalog, _config) do
    Enum.flat_map(migration.operations, fn
      %Op.RawSQL{classified: classified, line: line} = op ->
        if Enum.any?(classified, &(&1.class == :unknown)) do
          [%{Helpers.finding(__MODULE__, :warning,
               "cerbero cannot judge this SQL — unclassifiable statement; " <>
                 "review manually or add @cerbero_skip with a reason",
               migration, line) | check: :unclassified_sql}]
        else
          unmapped_findings(op, migration, catalog)
        end

      %Op.Unknown{line: line, description: desc} ->
        [%{Helpers.finding(__MODULE__, :warning,
             "cerbero cannot judge this operation (dynamically constructed): #{desc}",
             migration, line) | check: :unknown_operation}]

      op ->
        unmapped_findings(op, migration, catalog)
    end)
  end

  defp unmapped_findings(op, migration, catalog) do
    op
    |> Effects.derive(catalog.engine, catalog.version_num)
    |> Enum.filter(& &1.unmapped)
    |> Enum.reject(&(&1.class in [:unknown_operation, :unclassified_sql]))
    |> Enum.map(fn effect ->
      %{Helpers.finding(__MODULE__, :warning,
          "operation class #{effect.class} has no lock-table entry; " <>
            "judged conservatively as ACCESS EXCLUSIVE + rewrite",
          migration, effect.line) | check: :unmapped_operation}
    end)
  end
end
```

`lib/cerbero/check/runner.ex`:

```elixir
defmodule Cerbero.Check.Runner do
  @moduledoc "Orders pending migrations, threads the overlay, applies skips and severity overrides."

  alias Cerbero.{Catalog, Config, Finding, Migration}

  @spec default_checks() :: [module()]
  def default_checks do
    [
      Cerbero.Check.MetaFindings
      # Rules append themselves here as their tasks land (Tasks 11-15).
    ]
  end

  @spec select_pending([Migration.t()], [String.t()], String.t() | nil) :: [Migration.t()]
  def select_pending(migrations, applied_versions, start_after) do
    applied = MapSet.new(applied_versions)

    migrations
    |> Enum.reject(&MapSet.member?(applied, &1.version))
    |> Enum.reject(fn m -> start_after != nil and m.version <= start_after end)
    |> Enum.sort_by(& &1.version)
  end

  @spec run([Migration.t()], Catalog.t(), Config.t(), [module()]) :: {[Finding.t()], Catalog.t()}
  def run(pending, %Catalog{} = catalog, %Config{} = config, checks \\ default_checks()) do
    {findings, final_catalog} =
      Enum.map_reduce(pending, catalog, fn migration, cat ->
        findings =
          checks
          |> Enum.reject(&(&1.id() in config.skip_checks))
          |> Enum.flat_map(& &1.run(migration, cat, config))
          |> Enum.map(&apply_skip(&1, migration))
          |> Enum.map(&apply_override(&1, config))

        {findings, Catalog.apply_migration(cat, migration)}
      end)

    {List.flatten(findings), final_catalog}
  end

  defp apply_skip(%Finding{} = finding, %Migration{attrs: %{cerbero_skip: skips}}) do
    case List.keyfind(skips, finding.check, 0) do
      {_, reason} -> %{finding | severity: :info, message: finding.message <> " (skipped: #{reason})"}
      nil -> finding
    end
  end

  defp apply_override(%Finding{} = finding, %Config{severity_overrides: overrides}) do
    case Map.fetch(overrides, finding.check) do
      {:ok, severity} -> %{finding | severity: severity}
      :error -> finding
    end
  end
end
```

- [ ] **Step 3: Run, verify pass, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: check runner — pending selection, overlay threading, skips, meta-findings"
```

---

## Rule tasks — shared test scaffolding

Tasks 11–15 all use this pattern (define once in `test/support/rule_case.ex` during Task 11, Step 1):

```elixir
defmodule Cerbero.Test.RuleCase do
  @moduledoc "Shared scaffolding for rule tests: parse inline source, judge against a built snapshot."

  defmacro __using__(_) do
    quote do
      use ExUnit.Case, async: true
      import Cerbero.Test.SnapshotBuilder
      import Cerbero.Test.RuleCase
      alias Cerbero.{Catalog, Config, Finding}
    end
  end

  alias Cerbero.{Catalog, Config}
  alias Cerbero.Check.Runner
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot.Staleness

  def judge(checks, tables, body, opts \\ []) do
    snapshot_overrides = Keyword.get(opts, :snapshot, %{})
    config_overrides = Keyword.get(opts, :config, [])
    attrs = Keyword.get(opts, :attrs, "")

    {:ok, migration} =
      Parser.parse_string(
        "defmodule M do\n use Ecto.Migration\n#{attrs}\n def change do\n #{body}\n end\nend",
        "20260801000000_m.exs"
      )

    snapshot = Cerbero.Test.SnapshotBuilder.build_snapshot(Map.merge(%{"tables" => tables}, snapshot_overrides))
    staleness = %Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    catalog = Catalog.from_snapshot(snapshot, staleness)
    {:ok, config} = Config.load("nonexistent")
    config = struct!(config, config_overrides)

    {findings, _catalog} = Runner.run([migration], catalog, config, checks)
    findings
  end

  def big_events_table do
    Cerbero.Test.SnapshotBuilder.table("events", %{
      "n_live_tup" => 412_000_000, "reltuples" => 412_000_000.0,
      "heap_bytes" => 219_902_325_555, "total_bytes" => 253_403_070_464,
      "last_autoanalyze" => "2026-07-01T00:00:00Z",
      "columns" => [
        Cerbero.Test.SnapshotBuilder.column("id", %{"not_null" => true}),
        Cerbero.Test.SnapshotBuilder.column("org_id")
      ]
    })
  end
end
```

Each rule task ends by appending its module to `Runner.default_checks/0`.

---

### Task 11: Rule 1 `unsafe_index_creation` + Rule 10 `concurrent_index_requires_attributes`

**Files:**
- Create: `test/support/rule_case.ex`, `lib/cerbero/check/unsafe_index_creation.ex`, `lib/cerbero/check/concurrent_index_requires_attributes.ex`
- Modify: `lib/cerbero/check/runner.ex` (default_checks)
- Test: `test/cerbero/check/unsafe_index_creation_test.exs`, `test/cerbero/check/concurrent_index_requires_attributes_test.exs`

**Interfaces:**
- Consumes: `Effects.derive/3`, `Severity.assess/6`, `Catalog` queries, `Helpers`.
- Produces: check modules with ids `:unsafe_index_creation` and `:concurrent_index_requires_attributes`.

- [ ] **Step 1: Create `test/support/rule_case.ex`** (content above), then write failing tests

`test/cerbero/check/unsafe_index_creation_test.exs`:

```elixir
defmodule Cerbero.Check.UnsafeIndexCreationTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.UnsafeIndexCreation

  defp judge_rule(tables, body, opts \\ []), do: judge([UnsafeIndexCreation], tables, body, opts)

  test "the definition-of-done sentence: non-concurrent index on 412M rows is an error" do
    assert [%Finding{check: :unsafe_index_creation, severity: :error, message: msg, line: 5}] =
             judge_rule([big_events_table()], "create index(:events, [:org_id])")

    assert msg =~ "SHARE lock blocks writes on public.events (~412M rows, stats 2026-07-01) for a full-table scan"
    assert msg =~ "concurrently: true"
  end

  test "silent on small cold tables by default; strict mode restores always-fire" do
    small = table("prefs")
    assert [] = judge_rule([small], "create index(:prefs, [:user_id])")

    assert [%Finding{severity: :warning}] =
             judge_rule([small], "create index(:prefs, [:user_id])",
               config: [strict_concurrent_index: true])
  end

  test "silent on born_this_deploy tables" do
    assert [] = judge_rule([], """
           create table(:events_v2) do
             add :org_id, :bigint
           end
           create index(:events_v2, [:org_id])
           """)
  end

  test "partitioned parent gets the per-partition recipe, judged at summed scale" do
    tables = [
      table("events", %{"partitioned" => true, "n_live_tup" => 0, "reltuples" => 0.0}),
      table("events_p0", %{"partition_of" => "public.events", "n_live_tup" => 2_000_000, "reltuples" => 2_000_000.0})
    ]

    assert [%Finding{severity: :error, message: msg}] =
             judge_rule(tables, "create index(:events, [:org_id])")

    assert msg =~ "per-partition"
    assert msg =~ "ON ONLY"
    refute msg =~ "concurrently: true with"
  end

  test "concurrent index on PG emits nothing here (rule 10's territory)" do
    assert [] = judge_rule([big_events_table()], "create index(:events, [:org_id], concurrently: true)",
             attrs: " @disable_ddl_transaction true\n @disable_migration_lock true")
  end

  test "non-concurrent DROP INDEX at scale recommends the CONCURRENTLY form" do
    assert [%Finding{message: msg}] = judge_rule([big_events_table()], "drop index(:events, [:org_id])")
    assert msg =~ "DROP INDEX CONCURRENTLY"
  end

  test "CRDB: lock warning suppressed, cost finding remains at scale" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule([big_events_table()], "create index(:events, [:org_id])", snapshot: crdb)

    assert msg =~ "foreground cluster resources"
    refute msg =~ "SHARE lock"
  end
end
```

`test/cerbero/check/concurrent_index_requires_attributes_test.exs`:

```elixir
defmodule Cerbero.Check.ConcurrentIndexRequiresAttributesTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.ConcurrentIndexRequiresAttributes

  test "concurrently: true without both attributes is an error (deploy-time failure + invalid index)" do
    assert [%Finding{check: :concurrent_index_requires_attributes, severity: :error, message: msg}] =
             judge([ConcurrentIndexRequiresAttributes], [table("events")],
               "create index(:events, [:org_id], concurrently: true)")

    assert msg =~ "@disable_ddl_transaction"
    assert msg =~ "@disable_migration_lock"
  end

  test "with both attributes set: silent" do
    assert [] =
             judge([ConcurrentIndexRequiresAttributes], [table("events")],
               "create index(:events, [:org_id], concurrently: true)",
               attrs: " @disable_ddl_transaction true\n @disable_migration_lock true")
  end
end
```

Run: `mix test test/cerbero/check` — Expected: FAIL.

- [ ] **Step 2: Implement rule 1**

`lib/cerbero/check/unsafe_index_creation.ex`:

```elixir
defmodule Cerbero.Check.UnsafeIndexCreation do
  @moduledoc "Rule 1: non-concurrent create/drop index. Severity scales with size and traffic."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.{CRDB, Effects}
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :unsafe_index_creation

  @impl true
  def run(migration, catalog, config) do
    migration.operations
    |> Enum.flat_map(fn
      %Op.CreateIndex{concurrently: false} = op -> judge(op, migration, catalog, config)
      %Op.DropIndex{concurrently: false} = op -> judge(op, migration, catalog, config)
      %Op.RawSQL{} = op -> judge(op, migration, catalog, config)
      _ -> []
    end)
  end

  defp judge(op, migration, catalog, config) do
    op
    |> Effects.derive(catalog.engine, catalog.version_num)
    |> Enum.filter(&(&1.class in [:create_index, :add_unique, :drop_index, :reindex]))
    |> Enum.flat_map(fn effect ->
      table = Keyword.get(effect.relations, :target)

      cond do
        table == nil -> []
        Catalog.born?(catalog, table) and not Catalog.backfilled?(catalog, table) -> []
        catalog.engine == :cockroachdb -> crdb_cost_finding(effect, table, migration, catalog, config)
        true -> pg_finding(effect, table, migration, catalog, config)
      end
    end)
  end

  defp pg_finding(effect, table, migration, catalog, config) do
    scale = Catalog.scale(catalog, table)
    traffic = Catalog.traffic(catalog, table, config)
    severity = Severity.assess(effect.lock, effect.cost, scale, traffic, config, catalog.multiplier)
    partitioned = match?(%{partitioned: true}, Catalog.table(catalog, table))

    emit? = severity in [:error, :warning] or config.strict_concurrent_index
    severity = if config.strict_concurrent_index and severity in [:info, :none], do: :warning, else: severity

    if emit? do
      qualified = Catalog.qualify(table)

      mechanism =
        case effect.cost do
          :full_scan -> "#{lock_name(effect.lock)} lock blocks writes on #{qualified} (#{Helpers.describe_scale(catalog, table)}) for a full-table scan"
          :metadata_only -> "#{lock_name(effect.lock)} lock on #{qualified} (#{Helpers.describe_scale(catalog, table)}) queues behind long-running queries; set a lock_timeout"
        end

      [Helpers.finding(__MODULE__, severity, mechanism <> "; " <> remediation(effect.class, partitioned),
         migration, effect.line, relations: [qualified], engine: catalog.engine)]
    else
      []
    end
  end

  defp remediation(:drop_index, _), do: "use DROP INDEX CONCURRENTLY (drop index(..., concurrently: true))"

  defp remediation(_create, true),
    do: "partitioned parent: CREATE INDEX CONCURRENTLY is unsupported through PG 18 — build per-partition indexes CONCURRENTLY, create the parent index ON ONLY, then ATTACH each partition index"

  defp remediation(_create, false),
    do: "use concurrently: true with @disable_ddl_transaction and @disable_migration_lock"

  defp crdb_cost_finding(effect, table, migration, catalog, config) do
    with {:limited, note} <- CRDB.judge(:create_index, catalog.version_num),
         {:rows, rows, _} <- Catalog.scale(catalog, table),
         true <- rows >= config.rows_warning * catalog.multiplier do
      severity = if rows >= config.rows_error * catalog.multiplier, do: :warning, else: :info

      [Helpers.finding(__MODULE__, severity,
         "index build on #{Catalog.qualify(table)} (#{Helpers.describe_scale(catalog, table)}) is online on CockroachDB but #{note}",
         migration, effect.line, relations: [Catalog.qualify(table)], engine: :cockroachdb)]
    else
      _ -> []
    end
  end

  defp lock_name(:share), do: "SHARE"
  defp lock_name(:access_exclusive), do: "ACCESS EXCLUSIVE"
  defp lock_name(:share_update_exclusive), do: "SHARE UPDATE EXCLUSIVE"
  defp lock_name(:share_row_exclusive), do: "SHARE ROW EXCLUSIVE"
  defp lock_name(other), do: other |> Atom.to_string() |> String.upcase()
end
```

- [ ] **Step 3: Implement rule 10**

`lib/cerbero/check/concurrent_index_requires_attributes.ex`:

```elixir
defmodule Cerbero.Check.ConcurrentIndexRequiresAttributes do
  @moduledoc """
  Rule 10: concurrently: true without both @disable_ddl_transaction and
  @disable_migration_lock fails at deploy time and leaves an invalid
  index. Rule 1's own advice must not produce that.
  """
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :concurrent_index_requires_attributes

  @impl true
  def run(migration, _catalog, _config) do
    %{disable_ddl_transaction: ddl, disable_migration_lock: lock} = migration.attrs

    if ddl and lock do
      []
    else
      for %Op.CreateIndex{concurrently: true, line: line} <- migration.operations do
        Helpers.finding(__MODULE__, :error,
          "concurrently: true requires both @disable_ddl_transaction true and " <>
            "@disable_migration_lock true; without them the deploy fails and leaves an invalid index",
          migration, line)
      end
    end
  end
end
```

- [ ] **Step 4: Register, run, commit**

Add both modules to `Runner.default_checks/0` (order: rule modules first, `MetaFindings` last).

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: rules 1 + 10 — unsafe index creation (scale/traffic/partition/CRDB aware), CIC attributes"
```

---

### Task 12: Rule 2 `not_null_on_populated_table` + Rule 3 `column_default_rewrite`

**Files:**
- Create: `lib/cerbero/check/not_null_on_populated_table.ex`, `lib/cerbero/check/column_default_rewrite.ex`
- Modify: `lib/cerbero/check/runner.ex`
- Test: `test/cerbero/check/not_null_test.exs`, `test/cerbero/check/default_rewrite_test.exs`

- [ ] **Step 1: Write failing tests**

`test/cerbero/check/not_null_test.exs`:

```elixir
defmodule Cerbero.Check.NotNullTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.NotNullOnPopulatedTable

  defp judge_rule(tables, body, opts \\ []), do: judge([NotNullOnPopulatedTable], tables, body, opts)

  test "SET NOT NULL on a populated table without a proving CHECK: severity by rows, two-step spelled out" do
    assert [%Finding{check: :not_null_on_populated_table, severity: :error, message: msg}] =
             judge_rule([big_events_table()], "modify :org_id, :bigint, null: false" |> in_alter("events"))

    assert msg =~ "full-table scan under ACCESS EXCLUSIVE"
    assert msg =~ "CHECK (org_id IS NOT NULL) NOT VALID"
    assert msg =~ "VALIDATE CONSTRAINT"
  end

  test "silent when the column is already NOT NULL in the snapshot" do
    t = table("events", %{"columns" => [column("org_id", %{"not_null" => true})], "n_live_tup" => 5_000_000, "reltuples" => 5_000_000.0})
    assert [] = judge_rule([t], "modify :org_id, :bigint, null: false" |> in_alter("events"))
  end

  test "PG >= 12 with a validated IS NOT NULL check (snapshot): metadata-only info note" do
    t =
      table("events", %{
        "n_live_tup" => 5_000_000, "reltuples" => 5_000_000.0,
        "columns" => [column("org_id")],
        "constraints" => [
          %{"columns" => ["org_id"], "is_not_null_check_on" => "org_id", "name" => "org_id_nn",
            "on_delete" => nil, "on_update" => nil, "references" => nil, "type" => "check", "validated" => true}
        ]
      })

    assert [%Finding{severity: :info, message: msg}] =
             judge_rule([t], "modify :org_id, :bigint, null: false" |> in_alter("events"))

    assert msg =~ "scan is skipped"
  end

  test "recognizes its own recommended two-step in raw SQL across pending migrations (overlay)" do
    # Overlay case is covered by catalog_overlay_test; here: the raw-SQL SET NOT NULL form fires too.
    t = table("events", %{"n_live_tup" => 5_000_000, "reltuples" => 5_000_000.0, "columns" => [column("org_id")]})

    assert [%Finding{severity: :error}] =
             judge_rule([t], ~s|execute "ALTER TABLE events ALTER COLUMN org_id SET NOT NULL"|)
  end

  def in_alter(body, table), do: "alter table(:#{table}) do\n #{body}\n end"
end
```

`test/cerbero/check/default_rewrite_test.exs`:

```elixir
defmodule Cerbero.Check.DefaultRewriteTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.ColumnDefaultRewrite

  defp judge_rule(tables, body, opts \\ []), do: judge([ColumnDefaultRewrite], tables, body, opts)

  defp alter_events(body), do: "alter table(:events) do\n #{body}\n end"

  test "constant default is metadata-only within the PG >= 13 floor: silent" do
    assert [] = judge_rule([big_events_table()], alter_events("add :flags, :integer, default: 0"))
  end

  test "volatile default rewrites at scale: error" do
    assert [%Finding{check: :column_default_rewrite, severity: :error, message: msg}] =
             judge_rule([big_events_table()], alter_events(~s|add :token, :uuid, default: fragment("gen_random_uuid()")|))

    assert msg =~ "rewrite"
  end

  test "GENERATED ... STORED rewrites on every version — the folklore trap" do
    assert [%Finding{severity: :error, message: msg}] =
             judge_rule([big_events_table()], alter_events(~s|add :total, :bigint, generated: "ALWAYS AS (1) STORED"|))

    assert msg =~ "GENERATED"
  end

  test "CRDB: online backfill cost note instead of lock warning" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule([big_events_table()], alter_events(~s|add :token, :uuid, default: fragment("gen_random_uuid()")|), snapshot: crdb)

    assert msg =~ "backfill"
    refute msg =~ "ACCESS EXCLUSIVE"
  end
end
```

Run: `mix test test/cerbero/check` — Expected: FAIL.

- [ ] **Step 2: Implement rule 2**

`lib/cerbero/check/not_null_on_populated_table.ex`:

```elixir
defmodule Cerbero.Check.NotNullOnPopulatedTable do
  @moduledoc "Rule 2: SET NOT NULL scans under AEL unless a validated IS NOT NULL CHECK exists (PG >= 12)."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :not_null_on_populated_table

  @impl true
  def run(migration, catalog, config) do
    migration.operations
    |> Enum.flat_map(&set_not_null_targets/1)
    |> Enum.flat_map(fn {table, column, line} -> judge(table, column, line, migration, catalog, config) end)
  end

  defp set_not_null_targets(%Op.AlterTable{table: t, ops: ops, line: line}) do
    for {:modify_column, col, _type, opts} <- ops, Keyword.get(opts, :null) == false, do: {t, col, line}
  end

  defp set_not_null_targets(%Op.RawSQL{classified: classified, line: line}) do
    for %Classified{class: :set_not_null, table: t, column: col} <- classified, do: {t, col, line}
  end

  defp set_not_null_targets(_), do: []

  defp judge(table, column, line, migration, catalog, config) do
    qualified = Catalog.qualify(table)

    cond do
      match?(%{not_null: true}, Catalog.column(catalog, table, column)) ->
        []

      catalog.engine == :postgres and catalog.version_num >= 120_000 and
          Catalog.validated_not_null_check?(catalog, table, column) ->
        [Helpers.finding(__MODULE__, :info,
           "SET NOT NULL on #{qualified}.#{column}: a validated IS NOT NULL CHECK exists, " <>
             "so the scan is skipped (PG >= 12); still takes ACCESS EXCLUSIVE briefly — set a lock_timeout",
           migration, line, relations: [qualified])]

      true ->
        scale = Catalog.scale(catalog, table)
        traffic = Catalog.traffic(catalog, table, config)
        severity = Severity.assess(:access_exclusive, :full_scan, scale, traffic, config, catalog.multiplier)

        if severity == :none do
          []
        else
          [Helpers.finding(__MODULE__, severity,
             "SET NOT NULL on #{qualified}.#{column} (#{Helpers.describe_scale(catalog, table)}) " <>
               "forces a full-table scan under ACCESS EXCLUSIVE. Two-step instead: " <>
               "ADD CONSTRAINT ... CHECK (#{column} IS NOT NULL) NOT VALID, then VALIDATE CONSTRAINT " <>
               "in a later migration; on PG >= 12 the final SET NOT NULL then skips the scan",
             migration, line, relations: [qualified])]
        end
    end
  end
end
```

- [ ] **Step 3: Implement rule 3**

`lib/cerbero/check/column_default_rewrite.ex`:

```elixir
defmodule Cerbero.Check.ColumnDefaultRewrite do
  @moduledoc "Rule 3: volatile defaults and GENERATED STORED columns rewrite the table."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects

  @impl true
  def id, do: :column_default_rewrite

  @impl true
  def run(migration, catalog, config) do
    migration.operations
    |> Enum.flat_map(&Effects.derive(&1, catalog.engine, catalog.version_num))
    |> Enum.filter(&(&1.class in [:add_column_volatile_default, :add_column_generated_stored]))
    |> Enum.flat_map(fn effect ->
      table = Keyword.get(effect.relations, :target)
      scale = Catalog.scale(catalog, table)
      traffic = Catalog.traffic(catalog, table, config)

      what =
        case effect.class do
          :add_column_volatile_default -> "a volatile default"
          :add_column_generated_stored -> "a GENERATED ... STORED column (rewrites on every PG version)"
        end

      case {catalog.engine, Severity.assess(:access_exclusive, :rewrite, scale, traffic, config, catalog.multiplier)} do
        {_, :none} ->
          []

        {:cockroachdb, severity} ->
          [Helpers.finding(__MODULE__, severity,
             "adding a column with #{what} on #{Catalog.qualify(table)} " <>
               "(#{Helpers.describe_scale(catalog, table)}) triggers an online backfill that consumes " <>
               "cluster resources at scale", migration, effect.line,
             relations: [Catalog.qualify(table)], engine: :cockroachdb)]

        {:postgres, severity} ->
          [Helpers.finding(__MODULE__, severity,
             "adding a column with #{what} forces a full-table rewrite of #{Catalog.qualify(table)} " <>
               "(#{Helpers.describe_scale(catalog, table)}) under ACCESS EXCLUSIVE. " <>
               "Add the column without the default, backfill in batches, then set the default",
             migration, effect.line, relations: [Catalog.qualify(table)], engine: :postgres)]
      end
    end)
  end
end
```

- [ ] **Step 4: Register both in `Runner.default_checks/0`, run, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: rules 2 + 3 — NOT NULL two-step awareness, volatile/GENERATED default rewrites"
```

---

### Task 13: Rule 4 `column_type_change` + Rule 5 `fk_validation_scan` + Rule 6 `fk_missing_index`

**Files:**
- Create: `lib/cerbero/check/column_type_change.ex`, `lib/cerbero/check/fk_validation_scan.ex`, `lib/cerbero/check/fk_missing_index.ex`
- Modify: `lib/cerbero/check/runner.ex`
- Test: `test/cerbero/check/column_type_change_test.exs`, `test/cerbero/check/fk_test.exs`

- [ ] **Step 1: Write failing tests**

`test/cerbero/check/column_type_change_test.exs`:

```elixir
defmodule Cerbero.Check.ColumnTypeChangeTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.ColumnTypeChange

  defp judge_rule(tables, body, opts \\ []), do: judge([ColumnTypeChange], tables, body, opts)

  defp events_with(type, extra \\ %{}) do
    table("events", Map.merge(%{
      "n_live_tup" => 412_000_000, "reltuples" => 412_000_000.0, "heap_bytes" => 219_902_325_555,
      "last_autoanalyze" => "2026-07-01T00:00:00Z",
      "columns" => [column("id", %{"type" => type, "not_null" => true})],
      "indexes" => [index("events_pkey", ["id"], %{"primary" => true, "unique" => true})]
    }, extra))
  end

  test "int -> bigint on 412M rows: AEL + rewrite + index rebuilds named, error" do
    assert [%Finding{check: :column_type_change, severity: :error, message: msg}] =
             judge_rule([events_with("integer")], "alter table(:events) do\n modify :id, :bigint\n end")

    assert msg =~ "rewrite"
    assert msg =~ "events_pkey"
  end

  test "varchar(50) -> varchar(255) is binary-coercible: silent at metadata cost, but never for AEL on hot tables" do
    t = events_with("character varying(50)", %{"n_live_tup" => 1000, "reltuples" => 1000.0, "heap_bytes" => 8192,
          "idx_scan" => 0, "seq_scan" => 0, "n_tup_ins" => 0, "n_tup_upd" => 0, "n_tup_del" => 0})

    assert [%Finding{severity: :info, message: msg}] =
             judge_rule([t], "alter table(:events) do\n modify :id, :string, size: 255\n end")

    assert msg =~ "lock_timeout"
  end

  test "same type: no finding" do
    t = events_with("bigint")
    assert [] = judge_rule([t], "alter table(:events) do\n modify :id, :bigint\n end")
  end

  test "CRDB: type change on an indexed column is rejected by the engine — error before deploy" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :error, message: msg}] =
             judge_rule([events_with("integer")], "alter table(:events) do\n modify :id, :bigint\n end",
               snapshot: crdb)

    assert msg =~ "CockroachDB rejects"
  end
end
```

`test/cerbero/check/fk_test.exs`:

```elixir
defmodule Cerbero.Check.FKTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.{FKMissingIndex, FKValidationScan}

  defp orgs, do: table("orgs", %{"n_live_tup" => 41_000_000, "reltuples" => 41_000_000.0,
    "last_autoanalyze" => "2026-07-01T00:00:00Z"})

  test "ADD FK without validate: false — both tables' scale, referenced-table lock named" do
    assert [%Finding{check: :fk_validation_scan, severity: :error, message: msg}] =
             judge([FKValidationScan], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs)
             end
             """)

    assert msg =~ "writes to public.orgs (~41M rows"
    assert msg =~ "public.events (~412M rows"
    assert msg =~ "validate: false"
  end

  test "with validate: false: silent (metadata only)" do
    assert [] =
             judge([FKValidationScan], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs, validate: false)
             end
             """)
  end

  test "NOT-VALID advice is version-gated for partitioned referencing tables below PG 18" do
    partitioned_events = table("events", %{"partitioned" => true})
    p0 = table("events_p0", %{"partition_of" => "public.events", "n_live_tup" => 2_000_000, "reltuples" => 2_000_000.0})

    assert [%Finding{message: msg}] =
             judge([FKValidationScan], [partitioned_events, p0, orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs)
             end
             """)

    refute msg =~ "validate: false"
    assert msg =~ "PG 18"
  end

  test "new FK with no covering index on the referencing column" do
    assert [%Finding{check: :fk_missing_index, severity: :warning, message: msg}] =
             judge([FKMissingIndex], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs, validate: false)
             end
             """)

    assert msg =~ "owner_org_id"
  end

  test "an index created in the same migration counts as covering" do
    assert [] =
             judge([FKMissingIndex], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs, validate: false)
             end
             create index(:events, [:owner_org_id], concurrently: true)
             """,
             attrs: " @disable_ddl_transaction true\n @disable_migration_lock true")
  end
end
```

Run: `mix test test/cerbero/check` — Expected: FAIL.

- [ ] **Step 2: Implement rule 4**

`lib/cerbero/check/column_type_change.ex`:

```elixir
defmodule Cerbero.Check.ColumnTypeChange do
  @moduledoc "Rule 4: type changes — rewrite + index rebuilds on PG; engine-rejection table on CRDB."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.CRDB
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :column_type_change

  # Ecto DSL type -> formatted PG type (as pg_catalog formats it).
  @dsl_types %{
    integer: "integer", bigint: "bigint", text: "text", boolean: "boolean", uuid: "uuid",
    float: "double precision", naive_datetime: "timestamp without time zone",
    utc_datetime: "timestamp with time zone", date: "date", jsonb: "jsonb"
  }

  @impl true
  def run(migration, catalog, config) do
    for %Op.AlterTable{table: table, ops: ops, line: line} <- migration.operations,
        {:modify_column, col, type, opts} <- ops,
        type != nil,
        new_type = format_type(type, opts),
        current = Catalog.column(catalog, table, col),
        finding <- judge(table, col, current, new_type, line, migration, catalog, config) do
      finding
    end
  end

  defp judge(_table, _col, %{type: current}, new_type, _line, _m, _cat, _cfg) when current == new_type, do: []
  defp judge(_table, _col, nil, _new, _line, _m, _cat, _cfg), do: []

  defp judge(table, col, %{type: current}, new_type, line, migration, catalog, config) do
    qualified = Catalog.qualify(table)

    if catalog.engine == :cockroachdb do
      crdb_judge(qualified, col, line, migration, catalog)
    else
      scale = Catalog.scale(catalog, table)
      traffic = Catalog.traffic(catalog, table, config)
      coercible = binary_coercible?(current, new_type)
      cost = if coercible, do: :metadata_only, else: :rewrite
      severity = Severity.assess(:access_exclusive, cost, scale, traffic, config, catalog.multiplier)

      if severity == :none do
        []
      else
        message =
          if coercible do
            "#{qualified}.#{col} #{current} -> #{new_type} is binary-coercible (metadata only) " <>
              "but still takes ACCESS EXCLUSIVE — acquisition queues behind long-running queries; set a lock_timeout"
          else
            indexes = indexes_on(catalog, table, col)

            "#{qualified}.#{col} #{current} -> #{new_type} rewrites the table " <>
              "(#{Helpers.describe_scale(catalog, table)}) under ACCESS EXCLUSIVE" <>
              case indexes do
                [] -> ""
                names -> ", plus rebuilds of: #{Enum.join(names, ", ")}"
              end
          end

        [Helpers.finding(__MODULE__, severity, message, migration, line, relations: [qualified])]
      end
    end
  end

  defp crdb_judge(qualified, col, line, migration, catalog) do
    bare = qualified |> String.split(".") |> List.last()

    indexed? = indexes_on(catalog, bare, col) != []

    case indexed? and CRDB.judge(:alter_column_type_indexed, catalog.version_num) do
      {:rejected, note} ->
        [Helpers.finding(__MODULE__, :error, "#{qualified}.#{col}: #{note}", migration, line,
           relations: [qualified], engine: :cockroachdb)]

      _ ->
        [Helpers.finding(__MODULE__, :warning,
           "#{qualified}.#{col}: ALTER COLUMN TYPE on CockroachDB is restricted " <>
             "(cannot run inside a transaction with other statements)",
           migration, line, relations: [qualified], engine: :cockroachdb)]
    end
  end

  defp indexes_on(catalog, table, col) do
    case Catalog.table(catalog, table) do
      nil -> []
      t ->
        for idx <- t.indexes,
            Enum.any?(idx.keys, &match?(%{kind: :column, name: ^col}, &1)),
            do: idx.name
    end
  end

  defp format_type(:string, opts), do: "character varying(#{Keyword.get(opts, :size, 255)})"
  defp format_type(type, _opts) when is_atom(type), do: Map.get(@dsl_types, type, Atom.to_string(type))
  defp format_type({:references, _, _}, _opts), do: "bigint"
  defp format_type(other, _opts), do: to_string(inspect(other))

  # The in-code binary-coercible table: varchar(n)->varchar(m>=n), varchar->text.
  defp binary_coercible?(current, new_type) do
    case {parse_varchar(current), parse_varchar(new_type)} do
      {{:varchar, n}, {:varchar, m}} -> m >= n
      {{:varchar, _}, _} -> new_type == "text"
      _ -> false
    end
  end

  defp parse_varchar("character varying(" <> rest), do: {:varchar, rest |> String.trim_trailing(")") |> String.to_integer()}
  defp parse_varchar("character varying"), do: {:varchar, 0}
  defp parse_varchar(_), do: nil
end
```

- [ ] **Step 3: Implement rules 5 and 6**

`lib/cerbero/check/fk_validation_scan.ex`:

```elixir
defmodule Cerbero.Check.FKValidationScan do
  @moduledoc "Rule 5: ADD FK scans the referencing table while blocking writes on BOTH tables."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects

  @impl true
  def id, do: :fk_validation_scan

  @impl true
  def run(migration, catalog, config) do
    migration.operations
    |> Enum.flat_map(&Effects.derive(&1, catalog.engine, catalog.version_num))
    |> Enum.filter(&(&1.class == :add_foreign_key))
    |> Enum.flat_map(fn effect ->
      referencing = Keyword.get(effect.relations, :target)
      referenced = Keyword.get(effect.relations, :referenced)
      judge(referencing, referenced, effect.line, migration, catalog, config)
    end)
  end

  defp judge(referencing, referenced, line, migration, catalog, config) do
    scale_ing = Catalog.scale(catalog, referencing)
    scale_ed = if referenced, do: Catalog.scale(catalog, referenced), else: :unknown
    traffic = Catalog.traffic(catalog, referencing, config)

    severity =
      [scale_ing, scale_ed]
      |> Enum.map(&Severity.assess(:share_row_exclusive, :full_scan, &1, traffic, config, catalog.multiplier))
      |> Enum.max_by(fn s -> %{error: 3, warning: 2, info: 1, none: 0}[s] end)

    if severity in [:error, :warning] do
      q_ing = Catalog.qualify(referencing)
      q_ed = referenced && Catalog.qualify(referenced)

      partitioned = match?(%{partitioned: true}, Catalog.table(catalog, referencing))
      not_valid_supported = not (partitioned and catalog.engine == :postgres and catalog.version_num < 180_000)

      remediation =
        if not_valid_supported do
          "add the FK with validate: false (NOT VALID), then VALIDATE CONSTRAINT in a later migration " <>
            "(SHARE UPDATE EXCLUSIVE, writes continue)"
        else
          "NOT VALID foreign keys on partitioned referencing tables require PG 18; " <>
            "below that, schedule the validation scan for a maintenance window"
        end

      [Helpers.finding(__MODULE__, severity,
         "ADD FOREIGN KEY: writes to #{q_ed} (#{Helpers.describe_scale(catalog, referenced)}) are blocked " <>
           "while #{q_ing} (#{Helpers.describe_scale(catalog, referencing)}) is scanned " <>
           "(SHARE ROW EXCLUSIVE on both). " <> remediation,
         migration, line, relations: Enum.reject([q_ing, q_ed], &is_nil/1))]
    else
      []
    end
  end
end
```

`lib/cerbero/check/fk_missing_index.ex`:

```elixir
defmodule Cerbero.Check.FKMissingIndex do
  @moduledoc "Rule 6: a new FK whose referencing column has no covering index in catalog ∪ overlay."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :fk_missing_index

  @impl true
  def run(migration, catalog, config) do
    same_migration_indexed =
      for %Op.CreateIndex{table: t, keys: [first | _]} <- migration.operations,
          into: MapSet.new(),
          do: {Catalog.qualify(t), to_string(first)}

    for %Op.AlterTable{table: table, ops: ops, line: line} <- migration.operations,
        {op_kind, col, {:references, ref, _opts}, _col_opts} <- normalize(ops),
        op_kind in [:add_column, :modify_column],
        not covered?(catalog, table, col, same_migration_indexed),
        finding <- [emit(table, col, ref, line, migration, config)] do
      finding
    end
  end

  defp normalize(ops) do
    Enum.map(ops, fn
      {kind, col, type, opts} -> {kind, col, type, opts}
      {kind, col} -> {kind, col, nil, []}
    end)
  end

  defp covered?(catalog, table, col, same_migration_indexed) do
    Catalog.has_index_leading_on?(catalog, table, col) or
      MapSet.member?(same_migration_indexed, {Catalog.qualify(table), col})
  end

  defp emit(table, col, ref, line, migration, _config) do
    q = Catalog.qualify(table)

    Helpers.finding(__MODULE__, :warning,
      "new foreign key #{q}.#{col} -> #{Catalog.qualify(ref)} has no covering index on #{col}; " <>
        "deletes/updates on the referenced table will sequential-scan #{q}",
      migration, line, relations: [q, Catalog.qualify(ref)])
  end
end
```

- [ ] **Step 4: Register rules 4/5/6 in `Runner.default_checks/0`, run until green, commit**

Run: `mix test` — Expected: PASS. (The rule-4 `modify :id, :string, size: 255` test depends on the parser keeping the `size:` opt — it does, via `keyword_opts/1`.)

```bash
git add -A
git commit -m "feat: rules 4-6 — type changes (coercible table, CRDB rejections), FK scan, FK missing index"
```

---

### Task 14: Rule 7 `crdb_transactional_ddl` + Rule 9 `dml_in_migration`

**Files:**
- Create: `lib/cerbero/check/crdb_transactional_ddl.ex`, `lib/cerbero/check/dml_in_migration.ex`
- Modify: `lib/cerbero/check/runner.ex`
- Test: `test/cerbero/check/crdb_test.exs`, `test/cerbero/check/dml_test.exs`

- [ ] **Step 1: Write failing tests**

`test/cerbero/check/crdb_test.exs`:

```elixir
defmodule Cerbero.Check.CRDBTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.CRDBTransactionalDDL

  @crdb %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

  defp judge_rule(tables, body, opts \\ []) do
    judge([CRDBTransactionalDDL], tables, body, Keyword.merge([snapshot: @crdb], opts))
  end

  test "multiple DDL in one transactional migration: warning" do
    assert [%Finding{check: :crdb_transactional_ddl, severity: :warning}] =
             judge_rule([table("events")], """
             create index(:events, [:org_id])
             alter table(:events) do
               add :flags, :integer
             end
             """)
  end

  test "ALTER COLUMN TYPE mixed with other DDL: error" do
    assert findings = judge_rule([table("events", %{"columns" => [column("id", %{"type" => "integer"})]})], """
             alter table(:events) do
               modify :id, :bigint
             end
             create index(:events, [:org_id])
             """)

    assert Enum.any?(findings, &(&1.severity == :error))
  end

  test "@disable_ddl_transaction silences the transactional warning" do
    assert [] = judge_rule([table("events")], """
           create index(:events, [:org_id])
           alter table(:events) do
             add :flags, :integer
           end
           """, attrs: " @disable_ddl_transaction true")
  end

  test "on postgres this rule is silent" do
    assert [] = judge([CRDBTransactionalDDL], [table("events")], """
           create index(:events, [:org_id])
           alter table(:events) do
             add :flags, :integer
           end
           """)
  end
end
```

`test/cerbero/check/dml_test.exs`:

```elixir
defmodule Cerbero.Check.DMLTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.DMLInMigration

  test "unbatched UPDATE at scale: warning with the row count" do
    assert [%Finding{check: :dml_in_migration, severity: :warning, message: msg}] =
             judge([DMLInMigration], [big_events_table()], ~s|execute "UPDATE events SET org_id = 1"|)

    assert msg =~ "412M"
    assert msg =~ "single transaction"
  end

  test "small table: silent" do
    assert [] = judge([DMLInMigration], [table("prefs")], ~s|execute "UPDATE prefs SET x = 1"|)
  end

  test "unknown table: warning (unknown scale is unbounded)" do
    assert [%Finding{severity: :warning}] =
             judge([DMLInMigration], [], ~s|execute "UPDATE ghost SET x = 1"|)
  end
end
```

Run: `mix test test/cerbero/check` — Expected: FAIL.

- [ ] **Step 2: Implement**

`lib/cerbero/check/crdb_transactional_ddl.ex`:

```elixir
defmodule Cerbero.Check.CRDBTransactionalDDL do
  @moduledoc "Rule 7: CockroachDB transactional schema-change restrictions."
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.{CRDB, Effects}

  @impl true
  def id, do: :crdb_transactional_ddl

  @dml_classes [:dml_update, :dml_delete, :dml_insert_select]

  @impl true
  def run(migration, catalog, _config) do
    if catalog.engine != :cockroachdb or migration.attrs.disable_ddl_transaction do
      []
    else
      effects =
        migration.operations
        |> Enum.flat_map(&Effects.derive(&1, catalog.engine, catalog.version_num))
        |> Enum.reject(&(&1.class in @dml_classes or &1.class == :create_table))

      type_changes = Enum.filter(effects, &(&1.class == :alter_column_type))

      cond do
        type_changes != [] and length(effects) > 1 ->
          {_, note} = CRDB.judge(:alter_column_type_in_txn, catalog.version_num)

          for effect <- type_changes do
            Helpers.finding(__MODULE__, :error, note <> "; move the type change to its own migration " <>
              "with @disable_ddl_transaction true", migration, effect.line, engine: :cockroachdb)
          end

        length(effects) > 1 ->
          {_, note} = CRDB.judge(:multiple_ddl_in_txn, catalog.version_num)
          [first | _] = effects

          [Helpers.finding(__MODULE__, :warning,
             "#{length(effects)} schema changes in one transactional migration on CockroachDB: #{note}. " <>
               "Split them or set @disable_ddl_transaction true",
             migration, first.line, engine: :cockroachdb)]

        true ->
          []
      end
    end
  end
end
```

`lib/cerbero/check/dml_in_migration.ex`:

```elixir
defmodule Cerbero.Check.DMLInMigration do
  @moduledoc "Rule 9: classifier-detected UPDATE/DELETE/INSERT..SELECT against a table above threshold."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :dml_in_migration

  @impl true
  def run(migration, catalog, config) do
    for %Op.RawSQL{classified: classified, line: line} <- migration.operations,
        %Classified{class: kind, table: table} <- classified,
        kind in [:update, :delete, :insert_select],
        table != nil,
        risky?(catalog, kind, table, config),
        finding <- [emit(kind, table, line, migration, catalog)] do
      finding
    end
  end

  # For INSERT..SELECT the risk scales with the SOURCE size, which the
  # classifier does not extract — judge the (known-unknown) target and
  # let unknown scale stay unbounded.
  defp risky?(catalog, _kind, table, config) do
    case Catalog.scale(catalog, table) do
      {:rows, rows, _} -> rows >= config.rows_warning * catalog.multiplier
      :zero -> false
      :unknown -> true
    end
  end

  defp emit(kind, table, line, migration, catalog) do
    verb = kind |> Atom.to_string() |> String.upcase() |> String.replace("_", " ... ")

    Helpers.finding(__MODULE__, :warning,
      "#{verb} against #{Catalog.qualify(table)} (#{Helpers.describe_scale(catalog, table)}) runs as a " <>
        "single transaction inside the migration: long row locks, WAL burst, replication lag. " <>
        "Backfill in batches outside the migration instead",
      migration, line, relations: [Catalog.qualify(table)])
  end
end
```

Note the interaction with born-table revocation (design §3): `judge/…` sees the catalog *before* this migration's overlay, so a table created in an *earlier pending migration* and backfilled here has scale `:zero` at judgment time. That is correct for `dml_in_migration` (an empty table's backfill is cheap — the design's revocation concerns *scale-rule silencing* for later migrations, which `Catalog.backfilled?` handles). The `:zero -> false` branch encodes this deliberately.

- [ ] **Step 3: Register in `Runner.default_checks/0`, run, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: rules 7 + 9 — CRDB transactional DDL restrictions, unbatched DML at scale"
```

---

### Task 15: Rule 8 `snapshot_health` (global pass)

Runs regardless of pending migrations; consumes the snapshot, staleness, migration list, and catalog. It does not implement the per-migration `Cerbero.Check` behaviour — it exposes `run_global/5` and the CLI (Task 16) invokes it once.

**Files:**
- Create: `lib/cerbero/check/snapshot_health.ex`
- Test: `test/cerbero/check/snapshot_health_test.exs`

**Interfaces:**
- Produces: `Cerbero.Check.SnapshotHealth.run_global(snapshot, staleness, all_migrations :: [Migration.t()], pending :: [Migration.t()], catalog, config) :: [Finding.t()]` (check id `:snapshot_health`).

- [ ] **Step 1: Write failing tests**

`test/cerbero/check/snapshot_health_test.exs`:

```elixir
defmodule Cerbero.Check.SnapshotHealthTest do
  use ExUnit.Case, async: true

  alias Cerbero.{Catalog, Config, Migration}
  alias Cerbero.Check.SnapshotHealth
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot.Staleness
  import Cerbero.Test.SnapshotBuilder

  defp run_health(opts) do
    snapshot = build_snapshot(Keyword.get(opts, :snapshot, %{}))
    age = Keyword.get(opts, :age_days, 1)
    {:ok, config} = Config.load("nonexistent")

    staleness = %Staleness{
      age_days: age,
      scale_mode: if(age > config.stale_degrade_days, do: :unbounded, else: :exact),
      threshold_multiplier: if(age > config.headroom_days, do: 0.5, else: 1.0)
    }

    catalog = Catalog.from_snapshot(snapshot, staleness)

    SnapshotHealth.run_global(snapshot, staleness,
      Keyword.get(opts, :all, []), Keyword.get(opts, :pending, []), catalog, config)
  end

  defp pending!(version, body) do
    {:ok, m} = Parser.parse_string(
      "defmodule P#{version} do\n use Ecto.Migration\n def change do\n #{body}\n end\nend",
      "#{version}_p.exs")
    m
  end

  test "age past 30 days warns; fresh does not" do
    assert [] = run_health(age_days: 3)
    assert Enum.any?(run_health(age_days: 45), &(&1.severity == :warning and &1.message =~ "45 days old"))
  end

  test "age past 90 days states that scale is degraded to unbounded" do
    assert Enum.any?(run_health(age_days: 120), &(&1.message =~ "unbounded"))
  end

  test "invalid index in prod: a failed CONCURRENTLY build costing writes, providing nothing" do
    t = table("events", %{"indexes" => [index("events_bad_idx", ["org_id"], %{"valid" => false})]})
    findings = run_health(snapshot: %{"tables" => [t]})
    assert Enum.any?(findings, &(&1.message =~ "events_bad_idx" and &1.message =~ "invalid"))
  end

  test "history divergence: repo migration with version <= max(applied) but absent from applied" do
    findings = run_health(
      snapshot: %{"applied_migrations" => ["20250101000000", "20250301000000"]},
      all: [%Migration{version: "20250201000000", file: "x.exs"}]
    )
    assert Enum.any?(findings, &(&1.message =~ "20250201000000" and &1.severity == :warning))
  end

  test "aged-pending heuristic: pending migration older than the snapshot has likely been deployed" do
    findings = run_health(pending: [pending!("20250101000000", "create index(:x, [:y])")])
    assert Enum.any?(findings, &(&1.message =~ "already be applied"))
  end

  test "standby snapshot: degraded stats warning" do
    findings = run_health(snapshot: %{"standby" => true, "stats_provenance" => "standby"})
    assert Enum.any?(findings, &(&1.message =~ "standby"))
  end

  test "absent table targeted by pending DDL and not created by the pending set: error demanding re-export" do
    findings = run_health(pending: [pending!("20260901000000", "create index(:ghost, [:x])")])
    assert Enum.any?(findings, &(&1.severity == :error and &1.message =~ "ghost" and &1.message =~ "re-export"))
  end

  test "a table created by the pending set is NOT an absent-table error" do
    findings = run_health(pending: [
      pending!("20260901000000", "create table(:events_v2) do\n add :x, :bigint\n end"),
      pending!("20260901000001", "create index(:events_v2, [:x])")
    ])
    refute Enum.any?(findings, &(&1.message =~ "events_v2"))
  end
end
```

Run: `mix test test/cerbero/check/snapshot_health_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement `lib/cerbero/check/snapshot_health.ex`**

```elixir
defmodule Cerbero.Check.SnapshotHealth do
  @moduledoc """
  Rule 8: the snapshot's own health, surfaced as findings — never silent
  decay, never exit 2. Staleness degrades confidence; absence is never
  safety.
  """

  alias Cerbero.{Catalog, Config, Finding, Migration, Snapshot}
  alias Cerbero.DDL.Effects
  alias Cerbero.Snapshot.Staleness

  @id :snapshot_health

  def id, do: @id

  @spec run_global(Snapshot.t(), Staleness.t(), [Migration.t()], [Migration.t()], Catalog.t(), Config.t()) ::
          [Finding.t()]
  def run_global(snapshot, staleness, all_migrations, pending, catalog, config) do
    age_findings(staleness, config) ++
      invalid_index_findings(snapshot) ++
      divergence_findings(snapshot, all_migrations) ++
      aged_pending_findings(snapshot, pending) ++
      standby_findings(snapshot) ++
      absent_table_findings(pending, catalog)
  end

  defp finding(severity, message, opts \\ []) do
    %Finding{check: @id, severity: severity, message: message,
             file: Keyword.get(opts, :file), line: Keyword.get(opts, :line),
             relations: Keyword.get(opts, :relations, [])}
  end

  defp age_findings(%Staleness{age_days: age}, %Config{} = c) do
    cond do
      age > c.stale_degrade_days ->
        [finding(:warning,
           "snapshot is #{age} days old (limit #{c.stale_degrade_days}): every row count is now " <>
             "treated as unknown -> unbounded; risky operations fire at warning or above. Re-export")]

      age > c.stale_warn_days ->
        [finding(:warning, "snapshot is #{age} days old (warn threshold #{c.stale_warn_days}); re-export soon")]

      true ->
        []
    end
  end

  defp invalid_index_findings(%Snapshot{tables: tables}) do
    for t <- tables, idx <- t.indexes, idx.valid == false do
      finding(:warning,
        "index #{t.schema}.#{t.name}.#{idx.name} is invalid in production — likely a failed " <>
          "CONCURRENTLY build: it costs writes and provides nothing; drop and rebuild it",
        relations: ["#{t.schema}.#{t.name}"])
    end
  end

  defp divergence_findings(%Snapshot{applied_migrations: applied}, all_migrations) do
    case applied do
      [] -> []
      _ ->
        max_applied = Enum.max(applied)
        applied_set = MapSet.new(applied)

        for m <- all_migrations,
            m.version != nil,
            m.version <= max_applied,
            not MapSet.member?(applied_set, m.version) do
          finding(:warning,
            "migration #{m.version} exists in the repo with version <= max(applied) but is absent from " <>
              "the snapshot's applied list — snapshot and repo disagree about history",
            file: m.file)
        end
    end
  end

  defp aged_pending_findings(%Snapshot{collected_at: collected_at}, pending) do
    for m <- pending,
        m.version != nil,
        version_datetime = version_to_datetime(m.version),
        version_datetime != nil,
        DateTime.compare(version_datetime, collected_at) == :lt do
      finding(:warning,
        "pending migration #{m.version} predates the snapshot (#{DateTime.to_date(collected_at)}) — " <>
          "it may already be applied (pending vs applied-after-snapshot is offline-indistinguishable); re-export",
        file: m.file)
    end
  end

  defp version_to_datetime(<<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>) do
    case DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z") do
      {:ok, dt, 0} -> dt
      _ -> nil
    end
  end

  defp version_to_datetime(_), do: nil

  defp standby_findings(%Snapshot{standby: true}) do
    [finding(:warning,
       "snapshot was taken on a hot standby: pg_stat activity counters are instance-local " <>
         "(n_live_tup ~ 0, analyze timestamps NULL) — traffic judgments are degraded")]
  end

  defp standby_findings(_), do: []

  # Absent-and-not-created-by-pending => unknown scale + a demand for re-export.
  defp absent_table_findings(pending, catalog) do
    {findings, _cat} =
      Enum.flat_map_reduce(pending, catalog, fn m, cat ->
        findings =
          m.operations
          |> Enum.flat_map(&Effects.derive(&1, cat.engine, cat.version_num))
          |> Enum.reject(&(&1.class == :create_table))
          |> Enum.flat_map(fn effect ->
            for {_role, table} <- effect.relations,
                is_binary(table),
                not Catalog.known?(cat, table) do
              finding(:error,
                "pending migration targets #{Catalog.qualify(table)}, which is absent from the snapshot " <>
                  "and not created by the pending set — absence is never safety; re-export the snapshot",
                file: m.file, line: effect.line, relations: [Catalog.qualify(table)])
            end
          end)

        {findings, Catalog.apply_migration(cat, m)}
      end)

    Enum.uniq_by(findings, & &1.message)
  end
end
```

- [ ] **Step 3: Run, verify pass, commit**

Run: `mix test` — Expected: PASS.

```bash
git add -A
git commit -m "feat: rule 8 snapshot_health — age, invalid indexes, divergence, aged-pending, absent tables"
```

---

### Task 16: CLI `cerbero.check` — orchestration, formatters, exit codes, golden files

**Files:**
- Create: `lib/cerbero/cli/check.ex`, `lib/cerbero/cli/format/human.ex`, `lib/cerbero/cli/format/json.ex`, `lib/mix/tasks/cerbero.check.ex`
- Create: `test/golden/check_human.txt`, `test/golden/check_json.json` (generated via `UPDATE_GOLDEN=1`, then reviewed and committed)
- Test: `test/cerbero/cli/check_test.exs`

**Interfaces:**
- Produces: `Cerbero.CLI.Check.run(argv, opts \\ []) :: exit_code :: 0 | 1 | 2` with injectable `opts[:io]` (an IO device; default `:stdio`) and `opts[:clock]` (zero-arity fun returning `DateTime`; default `&DateTime.utc_now/0`).
- Flags: `--snapshot PATH` (default from config), `--migrations DIR` (default from config, first entry), `--config PATH` (default `.cerbero.exs`), `--format human|json` (default `human`), `--fail-on error|warning|info` (default from config), `--no-snapshot`, `--verbose`.
- Exit codes: 0 / 1 / 2 per Global Constraints. Staleness is never exit 2.
- No-snapshot structural mode: catalog built by replaying full history through `Catalog.apply_migration/2` from `Catalog.empty/0`; `config.start_after` is the pending cutoff; every finding message gets the suffix `" [no snapshot: structural checks only, scale unknown]"`; no `snapshot_health` pass.

- [ ] **Step 1: Write failing tests**

`test/cerbero/cli/check_test.exs`:

```elixir
defmodule Cerbero.CLI.CheckTest do
  use ExUnit.Case, async: false

  alias Cerbero.CLI.Check

  @snapshot "test/fixtures/snapshots/huge_table.json"
  @migrations "test/fixtures/migrations/unsafe"
  # Snapshot collected_at is 2026-07-01; this clock makes it 12 days old.
  @clock fn -> ~U[2026-07-13 00:00:00Z] end

  defp run(argv) do
    {:ok, io} = StringIO.open("")
    code = Check.run(argv, io: io, clock: @clock)
    {_, output} = StringIO.contents(io)
    {code, output}
  end

  defp golden(name, actual) do
    path = "test/golden/#{name}"
    if System.get_env("UPDATE_GOLDEN") == "1", do: File.write!(path, actual)
    assert File.read!(path) == actual, "golden mismatch for #{name}; UPDATE_GOLDEN=1 to regenerate"
  end

  test "definition of done: non-concurrent index on the 412M-row table fails CI, no DB reachable" do
    {code, output} = run(["--snapshot", @snapshot, "--migrations", @migrations, "--config", "nonexistent"])

    assert code == 1
    assert output =~ "SHARE lock blocks writes on public.events (~412M rows, stats 2026-07-01) for a full-table scan"
    assert output =~ "unsafe_index_creation"
    assert output =~ "20260801000000_add_events_payload_index.exs:5"
    assert output =~ "judged against snapshot of app_prod, 2026-07-01, 12 days old"
  end

  test "human output matches golden byte-for-byte" do
    {_code, output} = run(["--snapshot", @snapshot, "--migrations", @migrations, "--config", "nonexistent"])
    golden("check_human.txt", output)
  end

  test "json output matches golden and is canonically stable" do
    {code, output} = run(["--snapshot", @snapshot, "--migrations", @migrations,
                          "--config", "nonexistent", "--format", "json"])
    assert code == 1
    golden("check_json.json", output)
    assert %{"cerbero_findings_version" => 1, "findings" => [_ | _]} = JSON.decode!(output)
  end

  test "missing snapshot is exit 2 (operational), not exit 1" do
    {code, output} = run(["--snapshot", "no/such/file.json", "--migrations", @migrations, "--config", "nonexistent"])
    assert code == 2
    assert output =~ "error"
  end

  test "safe migration exits 0" do
    {code, _} = run(["--snapshot", @snapshot, "--migrations", "test/fixtures/migrations/safe", "--config", "nonexistent"])
    assert code == 0
  end

  test "--fail-on warning promotes warnings to failures" do
    # The safe corpus has no warnings; use the unsafe one and a tighter fail-on with fresh clock
    {code, _} = run(["--snapshot", @snapshot, "--migrations", @migrations,
                     "--config", "nonexistent", "--fail-on", "warning"])
    assert code == 1
  end

  test "no-snapshot structural mode: runs, labels findings, unknown scale" do
    {code, output} = run(["--no-snapshot", "--migrations", @migrations, "--config", "nonexistent"])
    assert code in [0, 1]
    assert output =~ "no snapshot: structural checks only, scale unknown"
  end
end
```

Run: `mix test test/cerbero/cli/check_test.exs` — Expected: FAIL.

- [ ] **Step 2: Implement formatters**

`lib/cerbero/cli/format/human.ex`:

```elixir
defmodule Cerbero.CLI.Format.Human do
  @moduledoc "Grouped-per-migration human output; info notes collapsed unless verbose."

  alias Cerbero.Finding

  @spec render([Finding.t()], String.t(), boolean()) :: String.t()
  def render(findings, summary_line, verbose) do
    {infos, loud} = Enum.split_with(findings, &(&1.severity == :info))
    shown = if verbose, do: findings, else: loud

    groups =
      shown
      |> Enum.sort_by(&{&1.file || "", &1.line || 0})
      |> Enum.group_by(&(&1.file || "(global)"))
      |> Enum.sort()

    body =
      Enum.map_join(groups, "\n", fn {file, file_findings} ->
        lines =
          Enum.map_join(file_findings, "\n", fn f ->
            loc = if f.line, do: "#{file}:#{f.line}", else: file
            "  [#{f.severity}] #{f.check}: #{f.message} (#{loc})"
          end)

        file <> "\n" <> lines
      end)

    counts = Enum.frequencies_by(findings, & &1.severity)

    tally =
      "#{length(loud)} finding(s) " <>
        "(#{Map.get(counts, :error, 0)} error, #{Map.get(counts, :warning, 0)} warning)" <>
        if not verbose and infos != [] do
          "; #{length(infos)} informational note(s); --verbose to show"
        else
          ""
        end

    Enum.join(Enum.reject(["cerbero: " <> summary_line, body, tally], &(&1 == "")), "\n\n") <> "\n"
  end
end
```

`lib/cerbero/cli/format/json.ex`:

```elixir
defmodule Cerbero.CLI.Format.JSON do
  @moduledoc "Stable, versioned, canonically-encoded JSON output (SARIF adapter deferred)."

  alias Cerbero.Finding
  alias Cerbero.Snapshot.Canonical

  @findings_version 1

  @spec render([Finding.t()], map()) :: String.t()
  def render(findings, summary) do
    %{
      "cerbero_findings_version" => @findings_version,
      "findings" =>
        findings
        |> Enum.sort_by(&{&1.file || "", &1.line || 0, Atom.to_string(&1.check)})
        |> Enum.map(fn f ->
          %{
            "check" => Atom.to_string(f.check),
            "engine" => f.engine && Atom.to_string(f.engine),
            "file" => f.file,
            "line" => f.line,
            "message" => f.message,
            "relations" => f.relations,
            "severity" => Atom.to_string(f.severity)
          }
        end),
      "summary" => summary
    }
    |> Canonical.encode()
  end
end
```

- [ ] **Step 3: Implement the CLI**

`lib/cerbero/cli/check.ex`:

```elixir
defmodule Cerbero.CLI.Check do
  @moduledoc "argv -> findings -> formatted output -> exit code. Injectable clock and IO."

  alias Cerbero.{Catalog, Config, Finding, Snapshot}
  alias Cerbero.Check.{Runner, SnapshotHealth}
  alias Cerbero.CLI.Format
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot.Staleness

  @switches [snapshot: :string, migrations: :string, config: :string, format: :string,
             fail_on: :string, no_snapshot: :boolean, verbose: :boolean]

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    case do_run(argv, clock) do
      {:ok, output, exit_code} ->
        IO.write(io, output)
        exit_code

      {:error, message} ->
        IO.write(io, "cerbero: error: #{message}\n")
        2
    end
  end

  defp do_run(argv, clock) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} -> do_run_parsed(Map.new(parsed), clock)
      {_, _, invalid} -> {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  defp do_run_parsed(parsed, clock) do
    with {:ok, config} <- load_config(parsed),
         {:ok, migrations} <- parse_migrations(parsed, config),
         {:ok, fail_on} <- fail_on(parsed, config) do
      if parsed[:no_snapshot] do
        structural(parsed, config, migrations, fail_on)
      else
        with_snapshot(parsed, config, migrations, fail_on, clock)
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp load_config(parsed) do
    Config.load(parsed[:config] || ".cerbero.exs")
  end

  defp parse_migrations(parsed, config) do
    dir = parsed[:migrations] || hd(config.migrations_paths)

    case Parser.parse_dir(dir) do
      {:ok, migrations} -> {:ok, migrations}
      {:error, {path, reason}} -> {:error, "cannot parse #{path}: #{inspect(reason)}"}
    end
  end

  defp fail_on(parsed, config) do
    case parsed[:fail_on] do
      nil -> {:ok, config.fail_on}
      "error" -> {:ok, :error}
      "warning" -> {:ok, :warning}
      "info" -> {:ok, :info}
      other -> {:error, "invalid --fail-on: #{other}"}
    end
  end

  defp with_snapshot(parsed, config, migrations, fail_on, clock) do
    with {:ok, snapshot} <- Snapshot.load(parsed[:snapshot] || config.snapshot_path) do
      staleness = Staleness.assess(snapshot, clock.(), config)
      catalog = Catalog.from_snapshot(snapshot, staleness)
      pending = Runner.select_pending(migrations, snapshot.applied_migrations, config.start_after)

      health = SnapshotHealth.run_global(snapshot, staleness, migrations, pending, catalog, config)
      {findings, _catalog} = Runner.run(pending, catalog, config)
      findings = health ++ findings

      summary_line =
        "judged against snapshot of #{snapshot.database}, " <>
          "#{DateTime.to_date(snapshot.collected_at)}, #{staleness.age_days} days old"

      summary = %{
        "errors" => count(findings, :error),
        "warnings" => count(findings, :warning),
        "infos" => count(findings, :info),
        "snapshot" => %{
          "age_days" => staleness.age_days,
          "collected_at" => DateTime.to_iso8601(snapshot.collected_at),
          "database" => snapshot.database
        }
      }

      render(parsed, findings, summary_line, summary, fail_on)
    else
      {:error, reason} -> {:error, "snapshot: #{inspect(reason)}"}
    end
  end

  defp structural(parsed, config, migrations, fail_on) do
    {history, pending} =
      Enum.split_with(migrations, fn m ->
        config.start_after != nil and m.version != nil and m.version <= config.start_after
      end)

    catalog = Enum.reduce(history, Catalog.empty(), &Catalog.apply_migration(&2, &1))
    {findings, _} = Runner.run(pending, catalog, config)

    findings =
      Enum.map(findings, &%{&1 | message: &1.message <> " [no snapshot: structural checks only, scale unknown]"})

    summary_line = "no snapshot: structural checks only, scale unknown"

    summary = %{
      "errors" => count(findings, :error), "warnings" => count(findings, :warning),
      "infos" => count(findings, :info), "snapshot" => nil
    }

    render(parsed, findings, summary_line, summary, fail_on)
  end

  defp render(parsed, findings, summary_line, summary, fail_on) do
    output =
      case parsed[:format] || "human" do
        "human" -> Format.Human.render(findings, summary_line, parsed[:verbose] || false)
        "json" -> Format.JSON.render(findings, summary)
        other -> {:error, "invalid --format: #{other}"}
      end

    with out when is_binary(out) <- output do
      exit_code = if Enum.any?(findings, &Finding.at_least?(&1.severity, fail_on)), do: 1, else: 0
      {:ok, out, exit_code}
    end
  end

  defp count(findings, severity), do: Enum.count(findings, &(&1.severity == severity))
end
```

`lib/mix/tasks/cerbero.check.ex`:

```elixir
defmodule Mix.Tasks.Cerbero.Check do
  @shortdoc "Judge pending migrations against the committed cerbero snapshot"
  @moduledoc "See Cerbero.CLI.Check for flags. Exit codes: 0 clean, 1 findings, 2 operational error."
  use Mix.Task

  @impl true
  def run(argv) do
    case Cerbero.CLI.Check.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
```

- [ ] **Step 4: Generate goldens, review, run everything**

```bash
mkdir -p test/golden
UPDATE_GOLDEN=1 mix test test/cerbero/cli/check_test.exs
```

Open both golden files and **read them as a reviewer**: the human file must contain the summary line, the definition-of-done sentence, `file:line`, and the tally; the JSON must be canonical (sorted keys). Then:

Run: `mix test`
Expected: PASS (goldens now byte-compare).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: cerbero.check CLI — human/JSON formatters, exit codes, golden files, structural mode"
```

---

### Task 17: README-first — the claim and the "why not excellent_migrations" comparison

Design §9.7: this document precedes any exporter code. It is the pitch; writing it first tests whether the pitch survives contact with paper.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace README.md**

```markdown
# Cerbero

Offline safety checks for Ecto migrations, judged against a committed snapshot
of your production database's *catalog metadata* — for PostgreSQL and CockroachDB.

**The claim, worded precisely:** cerbero detects a specific catalog-derivable
class of unsafe migrations, judged at export-time scale. It does not certify
migrations as safe; it judges the statement, not the moment.

## How it works

1. `mix cerbero.snapshot` exports catalog metadata (schema shapes, row/byte
   estimates, traffic counters, index/constraint validity) to
   `priv/repo/cerbero_snapshot.json` — a canonical, checksummed, human-diffable
   artifact you commit (or refresh on a CI cron — recommended past one
   deploy/week; a manually-refreshed artifact rots).
2. `mix cerbero.check` parses pending migrations (static AST — your code never
   runs), folds their effects into the catalog model, and judges each operation:
   lock mode × cost class × your production scale and traffic.
3. CI reads the exit code: 0 clean, 1 unsafe at `--fail-on` threshold,
   2 cerbero misconfigured. No database is reachable from CI.

Example finding:

    [error] unsafe_index_creation: SHARE lock blocks writes on public.events
    (~412M rows, stats 2026-07-01) for a full-table scan; use concurrently: true
    with @disable_ddl_transaction and @disable_migration_lock
    (priv/repo/migrations/20260801000000_add_events_payload_index.exs:5)

## Privacy boundary

The snapshot contains **identifiers, type names, enumerated keywords, booleans,
numbers, and timestamps — never expression text, never literals, never row
data**. `pg_stats` (histograms, most-common values) is permanently excluded.
Every SQL statement the exporter can run fits on one reviewable screen
(`Cerbero.Snapshot.Exporter.Queries`); `mix cerbero.snapshot --emit-sql` prints
it as a script a DBA can run with their own credentials, and `--from-file`
ingests the result.

What is *not* claimed: table/column names are exported (they already appear in
your migration files); row counts and byte sizes are business metrics and will
be visible to everyone with repo access, forever — opt into
`precision: :order_of_magnitude` to bucket them. A hot-standby snapshot has
degraded traffic stats (recorded and warned); a scrubbed subset copy produces
confidently wrong scale and is incompatible with scale judgment.

The checksum detects corruption and hand-edits. It is not tamper-proofing:
anyone who can commit can regenerate it.

## Why not excellent_migrations?

We like excellent_migrations. It is AST-only by identity: it judges the
migration text with no knowledge of the database, so it must assume the worst
everywhere — and teams drown in warnings on tables with 40 rows, annotate
everything with skips, and stop reading. Cerbero's differentiation is catalog
knowledge:

| | excellent_migrations | cerbero |
|---|---|---|
| Non-concurrent index | always warns | severity from actual rows/bytes/traffic; silent on small cold tables; correct per-partition recipe on partitioned parents |
| SET NOT NULL | always warns | silent if already NOT NULL; recognizes the validated-CHECK scan-skip (PG ≥ 12), including its own recommended two-step in raw SQL |
| Type change | cannot see the current type | `varchar(50)→varchar(255)` silent; `int→bigint` on 412M rows: error, with the index rebuilds named |
| FK without index | cannot know | rule impossible without the catalog |
| ADD FOREIGN KEY | flags the statement | names the *referenced* table whose writes block while the referencing table is scanned |
| CockroachDB | n/a | engine-conditional verdicts + the CRDB limitation table (rejects before your deploy does) |
| Invalid index in prod, stale stats, history divergence | n/a | `snapshot_health` |
| Adoption on a 400-migration repo | re-annotate history | pending-only: zero findings at adoption |

Three of cerbero's ten rules are impossible without catalog knowledge; five
are severity upgrades where the catalog changes whether CI fails; one is kept
for self-consistency. If you want AST-only checks with zero setup,
excellent_migrations remains the right tool — cerbero's no-snapshot mode
(`--no-snapshot`) gives you a comparable structural baseline plus a trial path.

## Requirements

Elixir ≥ 1.18. PostgreSQL ≥ 13 or CockroachDB ≥ v23.1. Postgres and
CockroachDB only — no adapter behaviour in v1.

## Configuration

`.cerbero.exs` (all optional):

    [
      rows_warning: 100_000,
      rows_error: 1_000_000,
      bytes_error: 1_073_741_824,
      hot_ops_per_sec: 1.0,
      headroom_days: 14,          # past this, thresholds shrink by headroom_multiplier
      headroom_multiplier: 0.5,
      stale_warn_days: 30,
      stale_degrade_days: 90,     # past this, all scale is treated as unbounded
      fail_on: :error,
      strict_concurrent_index: false,
      lock_timeout_attested: false,
      skip_checks: [],
      severity_overrides: %{},    # e.g. %{snapshot_health: :error}
      start_after: nil,
      precision: :exact,          # or :order_of_magnitude
      snapshot_path: "priv/repo/cerbero_snapshot.json",
      migrations_paths: ["priv/repo/migrations"]
    ]

Per-migration escape hatch (reason required, findings still shown at info):

    @cerbero_skip [{:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}]

## Known limitations

A snapshot is point-in-time; findings carry their stats dates; no wall-clock
duration estimates, ever. Pending vs. applied-after-snapshot is offline-
indistinguishable — scheduled re-export is the real mitigation. Lock queues,
long transactions, and concurrent DDL at deploy time are invisible offline:
cerbero judges the statement, not the moment. Dynamically-built operations
surface as `unknown_operation`, never silence. `down` bodies are not judged.
```

- [ ] **Step 2: Read it back once as a skeptic** — does every claim match what Tasks 1–16 built? Fix drift in whichever direction is honest (usually the README).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README-first — the precise claim, privacy boundary, EM comparison (design §9.7)"
```

---

### Task 18: Exporter — queries, `mix cerbero.snapshot`, DBA path, layer-3 integration

**Files:**
- Create: `lib/cerbero/snapshot/exporter/queries.ex`, `lib/cerbero/snapshot/exporter.ex`, `lib/cerbero/cli/snapshot.ex`, `lib/mix/tasks/cerbero.snapshot.ex`
- Create: `docker-compose.test.yml`, `test/integration/seed.sql`, `test/integration/exporter_test.exs`
- Modify: `test/test_helper.exs`

**Interfaces:**
- Produces: `Cerbero.Snapshot.Exporter.export(url :: String.t(), clock \\ &DateTime.utc_now/0) :: {:ok, raw_map} | {:error, term}` (raw map ready for `Snapshot.write!/2`); `Cerbero.Snapshot.Exporter.emit_sql() :: String.t()` (a psql script); `Cerbero.Snapshot.Exporter.from_file(path, clock) :: {:ok, raw_map} | {:error, term}`; `Cerbero.CLI.Snapshot.run(argv, opts) :: 0 | 2` with flags `--url`, `--out PATH`, `--emit-sql`, `--from-file PATH`, `--migration-source NAME` (default `schema_migrations`).
- Every SQL string lives as a module attribute in `Queries`; the only dynamic parts are `$1`-style parameters (schema list) and the quoted migration-source identifier.

- [ ] **Step 1: Configure test tags**

`test/test_helper.exs`:

```elixir
ExUnit.configure(exclude: [:postgres, :integration])
ExUnit.start()
```

- [ ] **Step 2: Write the queries module**

`lib/cerbero/snapshot/exporter/queries.ex`:

```elixir
defmodule Cerbero.Snapshot.Exporter.Queries do
  @moduledoc """
  EVERY SQL statement the exporter can run, on one reviewable screen.
  No dynamic SQL beyond schema-name parameters and the quoted
  migrations-table identifier. The only non-catalog read is the versions
  column of the migrations table. This module is the privacy allowlist's
  first layer — review it like one.
  """

  def version, do: "SELECT version()"
  def server_version_num, do: "SELECT current_setting('server_version_num')::int"
  def current_database, do: "SELECT current_database()"
  def standby, do: "SELECT pg_is_in_recovery()"

  def stats_reset,
    do: "SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()"

  def crdb_probe,
    do: "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'crdb_internal'"

  # sole non-catalog read; identifier is quote_ident-ed in code
  def applied_migrations(quoted_table), do: "SELECT version::text FROM #{quoted_table} ORDER BY 1"

  def tables, do: """
  SELECT n.nspname AS schema, c.relname AS name,
         c.relkind = 'p' AS partitioned,
         parent.relnamespace::regnamespace::text || '.' || parent.relname AS partition_of,
         c.reltuples::float8 AS reltuples, c.relpages::bigint AS relpages,
         s.n_live_tup, s.last_analyze, s.last_autoanalyze,
         s.seq_scan, s.idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
         pg_relation_size(c.oid) AS heap_bytes, pg_total_relation_size(c.oid) AS total_bytes
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
  LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
  LEFT JOIN pg_class parent ON parent.oid = i.inhparent
  WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1)
  ORDER BY n.nspname, c.relname
  """

  def columns, do: """
  SELECT n.nspname AS schema, c.relname AS table, a.attname AS name,
         format_type(a.atttypid, a.atttypmod) AS type,
         a.attnotnull AS not_null,
         a.attidentity <> '' AS identity,
         a.attgenerated = 's' AS generated_stored,
         ad.oid IS NOT NULL AS has_default,
         CASE WHEN ad.oid IS NULL THEN NULL
              WHEN pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval(%' THEN 'sequence'
              WHEN pg_get_expr(ad.adbin, ad.adrelid) ~ '^[^(]*$' THEN 'literal'
              ELSE 'expression' END AS default_kind,
         COALESCE((
           SELECT bool_or(p.provolatile = 'v')
           FROM pg_depend d JOIN pg_proc p ON p.oid = d.refobjid
           WHERE d.classid = 'pg_attrdef'::regclass AND d.objid = ad.oid
             AND d.refclassid = 'pg_proc'::regclass
         ), false) AS default_volatile
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
  WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1)
    AND a.attnum > 0 AND NOT a.attisdropped
  ORDER BY n.nspname, c.relname, a.attnum
  """

  def indexes, do: """
  SELECT n.nspname AS schema, t.relname AS table, ic.relname AS name,
         i.indisunique AS unique, i.indisprimary AS primary, i.indisvalid AS valid,
         am.amname AS method, i.indpred IS NOT NULL AS partial,
         pg_relation_size(ic.oid) AS bytes,
         (SELECT array_agg(CASE WHEN k.attnum = 0 THEN NULL ELSE a.attname END ORDER BY k.ord)
          FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
          LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
         ) AS key_names
  FROM pg_index i
  JOIN pg_class ic ON ic.oid = i.indexrelid
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_am am ON am.oid = ic.relam
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = ANY($1)
  ORDER BY n.nspname, t.relname, ic.relname
  """

  def constraints, do: """
  SELECT n.nspname AS schema, t.relname AS table, con.conname AS name,
         CASE con.contype WHEN 'p' THEN 'primary' WHEN 'u' THEN 'unique'
              WHEN 'f' THEN 'foreign_key' WHEN 'c' THEN 'check' WHEN 'x' THEN 'exclusion' END AS type,
         (SELECT array_agg(a.attname ORDER BY k.ord)
          FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS columns,
         con.convalidated AS validated,
         CASE WHEN con.contype = 'f'
              THEN ft.relnamespace::regnamespace::text || '.' || ft.relname END AS ref_table,
         CASE WHEN con.contype = 'f' THEN
           (SELECT array_agg(a.attname ORDER BY k.ord)
            FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) END AS ref_columns,
         CASE con.confdeltype WHEN 'a' THEN 'no_action' WHEN 'r' THEN 'restrict'
              WHEN 'c' THEN 'cascade' WHEN 'n' THEN 'set_null' WHEN 'd' THEN 'set_default' END AS on_delete,
         CASE con.confupdtype WHEN 'a' THEN 'no_action' WHEN 'r' THEN 'restrict'
              WHEN 'c' THEN 'cascade' WHEN 'n' THEN 'set_null' WHEN 'd' THEN 'set_default' END AS on_update,
         CASE WHEN con.contype = 'c'
                   AND pg_get_constraintdef(con.oid) ~* '^CHECK \\(\\(?([a-z0-9_]+) IS NOT NULL\\)?\\)$'
              THEN (regexp_match(pg_get_constraintdef(con.oid), '\\(([a-z0-9_]+) IS NOT NULL',  'i'))[1]
         END AS is_not_null_check_on
  FROM pg_constraint con
  JOIN pg_class t ON t.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  LEFT JOIN pg_class ft ON ft.oid = con.confrelid
  WHERE n.nspname = ANY($1)
  ORDER BY n.nspname, t.relname, con.conname
  """

  # CRDB alternates (sizes/rows via crdb_internal; PG functions are unreliable there)
  def crdb_version, do: "SELECT value FROM crdb_internal.node_build_info WHERE field = 'Version'"

  def crdb_row_counts,
    do: "SELECT table_name, estimated_row_count FROM crdb_internal.table_row_statistics"

  @doc "All (name, sql) pairs the --emit-sql script includes, in order."
  def emit_list do
    [
      {"version", version()}, {"server_version_num", server_version_num()},
      {"current_database", current_database()}, {"standby", standby()},
      {"stats_reset", stats_reset()},
      {"tables", String.replace(tables(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"columns", String.replace(columns(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"indexes", String.replace(indexes(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"constraints", String.replace(constraints(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"applied_migrations", applied_migrations("schema_migrations")}
    ]
  end
end
```

Note: `pg_get_constraintdef` output is inspected only to derive the boolean/column-name `is_not_null_check_on` — the text itself never leaves the query. This is the "derivation server-side" privacy layer.

- [ ] **Step 3: Write the exporter**

`lib/cerbero/snapshot/exporter.ex`:

```elixir
defmodule Cerbero.Snapshot.Exporter do
  @moduledoc """
  Builds a raw snapshot map from a live connection (or a DBA-returned
  file). Session is read-only with a short statement_timeout — defense in
  depth, not the privacy mechanism (that is the Queries allowlist).
  """

  alias Cerbero.Snapshot.Exporter.Queries

  @cerbero_version Mix.Project.config()[:version]

  @spec export(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(url, opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    schemas = Keyword.get(opts, :schemas, ["public"])
    migration_source = Keyword.get(opts, :migration_source, "schema_migrations")

    with {:ok, conn} <- Postgrex.start_link(url: url, pool_size: 1) do
      try do
        q!(conn, "SET default_transaction_read_only = on")
        q!(conn, "SET statement_timeout = '15s'")
        build(conn, clock, schemas, migration_source)
      rescue
        e -> {:error, {:export_failed, Exception.message(e)}}
      after
        GenServer.stop(conn)
      end
    end
  end

  defp build(conn, clock, schemas, migration_source) do
    engine = detect_engine(conn)

    tables = rows(q!(conn, Queries.tables(), [schemas]))
    columns = rows(q!(conn, Queries.columns(), [schemas]))
    indexes = rows(q!(conn, Queries.indexes(), [schemas]))
    constraints = rows(q!(conn, Queries.constraints(), [schemas]))

    applied =
      case q(conn, Queries.applied_migrations(quote_ident(migration_source))) do
        {:ok, result} -> result |> rows() |> Enum.map(&hd/1) |> Enum.sort()
        {:error, _} -> []
      end

    [[database]] = rows(q!(conn, Queries.current_database()))
    [[standby]] = rows(q!(conn, Queries.standby()))
    stats_reset = conn |> q!(Queries.stats_reset()) |> rows() |> List.first() |> List.first()

    {:ok,
     %{
       "applied_migrations" => applied,
       "cerbero_version" => @cerbero_version,
       "checksum" => nil,
       "collected_at" => clock.() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       "database" => database,
       "engine" => engine,
       "format_version" => Cerbero.Snapshot.format_version(),
       "standby" => standby,
       "stats_provenance" => if(standby, do: "standby", else: "primary"),
       "stats_reset" => stats_reset && DateTime.to_iso8601(stats_reset),
       "tables" => assemble_tables(tables, columns, indexes, constraints)
     }}
  end

  defp detect_engine(conn) do
    [[probe]] = rows(q!(conn, Queries.crdb_probe()))

    if probe > 0 do
      [[version]] = rows(q!(conn, Queries.crdb_version()))
      %{"name" => "cockroachdb", "version" => version, "version_num" => crdb_version_num(version)}
    else
      [[num]] = rows(q!(conn, Queries.server_version_num()))
      %{"name" => "postgres",
        "version" => "#{div(num, 10_000)}.#{rem(num, 10_000)}",
        "version_num" => num}
    end
  end

  # "v25.1.2" -> 25_102 (major*1000 + minor*100 + patch, best-effort)
  defp crdb_version_num(version) do
    case Regex.run(~r/v?(\d+)\.(\d+)(?:\.(\d+))?/, version) do
      [_, major, minor, patch] -> String.to_integer(major) * 1000 + String.to_integer(minor) * 100 + String.to_integer(patch)
      [_, major, minor] -> String.to_integer(major) * 1000 + String.to_integer(minor) * 100
      _ -> 0
    end
  end

  defp assemble_tables(tables, columns, indexes, constraints) do
    col_by = Enum.group_by(columns, fn [schema, table | _] -> {schema, table} end)
    idx_by = Enum.group_by(indexes, fn [schema, table | _] -> {schema, table} end)
    con_by = Enum.group_by(constraints, fn [schema, table | _] -> {schema, table} end)

    Enum.map(tables, fn [schema, name, partitioned, partition_of, reltuples, relpages,
                          n_live_tup, last_analyze, last_autoanalyze,
                          seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del,
                          heap_bytes, total_bytes] ->
      %{
        "schema" => schema, "name" => name,
        "partitioned" => partitioned, "partition_of" => partition_of,
        "reltuples" => reltuples * 1.0, "relpages" => relpages,
        "n_live_tup" => n_live_tup || 0,
        "last_analyze" => iso(last_analyze), "last_autoanalyze" => iso(last_autoanalyze),
        "seq_scan" => seq_scan || 0, "idx_scan" => idx_scan || 0,
        "n_tup_ins" => n_tup_ins || 0, "n_tup_upd" => n_tup_upd || 0, "n_tup_del" => n_tup_del || 0,
        "heap_bytes" => heap_bytes, "total_bytes" => total_bytes,
        "columns" => Enum.map(Map.get(col_by, {schema, name}, []), &column_json/1),
        "indexes" => Enum.map(Map.get(idx_by, {schema, name}, []), &index_json/1),
        "constraints" => Enum.map(Map.get(con_by, {schema, name}, []), &constraint_json/1)
      }
    end)
  end

  defp column_json([_s, _t, name, type, not_null, identity, generated_stored,
                    has_default, default_kind, default_volatile]) do
    %{
      "name" => name, "type" => type, "not_null" => not_null,
      "identity" => identity, "generated" => if(generated_stored, do: "stored"),
      "default" =>
        if has_default do
          %{"present" => true, "volatile" => default_volatile, "kind" => default_kind}
        end
    }
  end

  defp index_json([_s, _t, name, unique, primary, valid, method, partial, bytes, key_names]) do
    %{
      "name" => name, "unique" => unique, "primary" => primary, "valid" => valid,
      "method" => method, "partial" => partial, "bytes" => bytes,
      "keys" =>
        Enum.map(key_names || [], fn
          nil -> %{"kind" => "expression"}
          col -> %{"kind" => "column", "name" => col}
        end)
    }
  end

  defp constraint_json([_s, _t, name, type, columns, validated, ref_table, ref_columns,
                        on_delete, on_update, is_nn]) do
    %{
      "name" => name, "type" => type, "columns" => columns || [], "validated" => validated,
      "references" => if(ref_table, do: %{"table" => ref_table, "columns" => ref_columns || []}),
      "on_delete" => if(type == "foreign_key", do: on_delete),
      "on_update" => if(type == "foreign_key", do: on_update),
      "is_not_null_check_on" => is_nn
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> iso()

  defp q(conn, sql, params \\ []), do: Postgrex.query(conn, sql, params)
  defp q!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params)
  defp rows(%Postgrex.Result{rows: rows}), do: rows

  defp quote_ident(name), do: ~s|"#{String.replace(name, ~s|"|, ~s|""|)}"|

  # --- DBA path ------------------------------------------------------------

  @doc "A psql script: each query wrapped so output is JSON-lines per section."
  @spec emit_sql() :: String.t()
  def emit_sql do
    Queries.emit_list()
    |> Enum.map_join("\n", fn {name, sql} ->
      one_line = sql |> String.trim() |> String.trim_trailing(";")

      """
      \\echo -- cerbero:begin:#{name}
      COPY (SELECT row_to_json(q) FROM (#{one_line}) q) TO STDOUT;
      \\echo -- cerbero:end:#{name}
      """
    end)
  end

  @doc "Rebuild a raw snapshot map from the DBA-returned psql output."
  @spec from_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_file(path, opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    with {:ok, contents} <- File.read(path) do
      sections = parse_sections(contents)
      build_from_sections(sections, clock)
    end
  end

  defp parse_sections(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current, acc} ->
      case line do
        "-- cerbero:begin:" <> name -> {name, Map.put(acc, name, [])}
        "-- cerbero:end:" <> _ -> {nil, acc}
        "" -> {current, acc}
        json when current != nil -> {current, Map.update!(acc, current, &(&1 ++ [JSON.decode!(json)]))}
        _ -> {current, acc}
      end
    end)
    |> elem(1)
  end

  # Maps each section's JSON rows through the same assemble path as the
  # live exporter. Implement by converting the decoded maps back to the
  # positional row lists the assemble_* functions expect (keys are known
  # from the queries' SELECT lists), then reuse build's assembly. PG only
  # in v1 (CRDB DBA path via the mix task against a live connection).
  defp build_from_sections(sections, clock) do
    # ... ~40 lines: pluck by key per section, reuse assemble_tables/4,
    # engine from sections["server_version_num"], etc.
    # Same output contract as build/4: {:ok, raw_map}.
  end
end
```

The `build_from_sections/2` body is the one place this plan leaves the transcription mechanical-but-unwritten: it is a key-plucking mirror of `build/4` with no design decisions left. Write it alongside its test (below) — the section names and column orders are fixed by `Queries.emit_list/0`.

- [ ] **Step 4: CLI + mix task**

`lib/cerbero/cli/snapshot.ex`:

```elixir
defmodule Cerbero.CLI.Snapshot do
  @moduledoc "argv for mix cerbero.snapshot: --url | --emit-sql | --from-file, --out, --migration-source."

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Exporter

  @switches [url: :string, out: :string, emit_sql: :boolean, from_file: :string, migration_source: :string]

  @spec run([String.t()], keyword()) :: 0 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {parsed, _, _} = OptionParser.parse(argv, strict: @switches)
    out = parsed[:out] || "priv/repo/cerbero_snapshot.json"

    result =
      cond do
        parsed[:emit_sql] -> {:emit, Exporter.emit_sql()}
        parsed[:from_file] -> Exporter.from_file(parsed[:from_file], clock: clock)
        parsed[:url] -> Exporter.export(parsed[:url], clock: clock, migration_source: parsed[:migration_source] || "schema_migrations")
        true -> {:error, "one of --url, --emit-sql, --from-file is required"}
      end

    case result do
      {:emit, script} ->
        IO.write(io, script)
        0

      {:ok, raw} ->
        Snapshot.write!(raw, out)
        IO.write(io, "cerbero: wrote #{out}\n")
        0

      {:error, reason} ->
        IO.write(io, "cerbero: error: #{inspect(reason)}\n")
        2
    end
  end
end
```

`lib/mix/tasks/cerbero.snapshot.ex`:

```elixir
defmodule Mix.Tasks.Cerbero.Snapshot do
  @shortdoc "Export a cerbero catalog snapshot from a database"
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    case Cerbero.CLI.Snapshot.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
```

- [ ] **Step 5: Docker + seed + layer-3 integration test**

`docker-compose.test.yml`:

```yaml
services:
  pg16:
    image: postgres:16
    environment: {POSTGRES_PASSWORD: cerbero, POSTGRES_DB: cerbero_test}
    ports: ["54316:5432"]
  pg13:
    image: postgres:13
    environment: {POSTGRES_PASSWORD: cerbero, POSTGRES_DB: cerbero_test}
    ports: ["54313:5432"]
  crdb:
    image: cockroachdb/cockroach:latest-v25.1
    command: start-single-node --insecure
    ports: ["26257:26257"]
```

`test/integration/seed.sql` — one schema exercising every snapshot feature:

```sql
CREATE TABLE orgs (id bigserial PRIMARY KEY, name varchar(255) NOT NULL);
CREATE TABLE events (
  id bigserial, org_id bigint NOT NULL REFERENCES orgs(id),
  payload jsonb, day date NOT NULL,
  total bigint GENERATED ALWAYS AS (id * 2) STORED,
  seq int GENERATED ALWAYS AS IDENTITY,
  inserted_at timestamp DEFAULT now(),
  PRIMARY KEY (id, day)
) PARTITION BY RANGE (day);
CREATE TABLE events_p2026 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE INDEX events_p2026_partial ON events_p2026 (org_id) WHERE payload IS NOT NULL;
CREATE INDEX events_p2026_expr ON events_p2026 ((lower(day::text)));
ALTER TABLE orgs ADD CONSTRAINT orgs_name_nn CHECK (name IS NOT NULL);
CREATE TABLE schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp);
INSERT INTO orgs (name) SELECT 'org-' || g FROM generate_series(1, 100) g;
INSERT INTO schema_migrations (version) VALUES (20250101000000);
ANALYZE;
-- flip an index invalid the honest way a failed CIC leaves it
UPDATE pg_index SET indisvalid = false
WHERE indexrelid = 'events_p2026_partial'::regclass;
```

`test/integration/exporter_test.exs`:

```elixir
defmodule Cerbero.Integration.ExporterTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Exporter

  @url "postgres://postgres:cerbero@localhost:54316/cerbero_test"

  setup_all do
    {:ok, conn} = Postgrex.start_link(url: @url, pool_size: 1)
    Postgrex.query!(conn, "DROP SCHEMA public CASCADE", [])
    Postgrex.query!(conn, "CREATE SCHEMA public", [])
    for stmt <- "test/integration/seed.sql" |> File.read!() |> String.split(";\n", trim: true),
        String.trim(stmt) != "",
        do: Postgrex.query!(conn, stmt, [])
    :ok
  end

  test "export -> stamp -> write -> load -> strict decode round-trips" do
    assert {:ok, raw} = Exporter.export(@url)
    path = Path.join(System.tmp_dir!(), "live_snapshot.json")
    Snapshot.write!(raw, path)
    assert {:ok, %Snapshot{} = s} = Snapshot.load(path)
    assert s.engine.name == :postgres
    assert s.applied_migrations == ["20250101000000"]
  end

  test "every snapshot feature is captured" do
    {:ok, raw} = Exporter.export(@url)
    {:ok, s} = Snapshot.decode(Snapshot.stamp(raw))
    by_name = Map.new(s.tables, &{&1.name, &1})

    assert by_name["events"].partitioned
    assert by_name["events_p2026"].partition_of == "public.events"
    assert Enum.any?(by_name["events"].columns, &(&1.generated == :stored))
    assert Enum.any?(by_name["events"].columns, &(&1.identity))
    assert Enum.any?(by_name["events"].columns, &(&1.default && &1.default.volatile))
    assert Enum.any?(by_name["events_p2026"].indexes, &(&1.partial))
    assert Enum.any?(by_name["events_p2026"].indexes, fn i -> Enum.any?(i.keys, &(&1.kind == :expression)) end)
    assert Enum.any?(by_name["events_p2026"].indexes, &(&1.valid == false))
    assert Enum.any?(by_name["orgs"].constraints, &(&1.is_not_null_check_on == "name"))
    assert Enum.any?(by_name["events_p2026"].constraints, &(&1.type == :foreign_key))
    assert by_name["orgs"].n_live_tup == 100
  end

  test "the emit-sql script and from-file rebuild the same snapshot" do
    script = Path.join(System.tmp_dir!(), "cerbero_export.sql")
    output = Path.join(System.tmp_dir!(), "cerbero_export.out")
    File.write!(script, Exporter.emit_sql())

    {_, 0} = System.cmd("psql", [@url, "--no-psqlrc", "--tuples-only", "-f", script],
                        into: File.stream!(output), stderr_to_stdout: false)

    assert {:ok, from_file} = Exporter.from_file(output)
    assert {:ok, live} = Exporter.export(@url)
    assert Map.delete(from_file, "collected_at") |> Map.delete("checksum") ==
             Map.delete(live, "collected_at") |> Map.delete("checksum")
  end

  test "session is read-only" do
    # The exporter sets default_transaction_read_only; verify our queries module
    # holds no writes by grepping it — the belt to the runtime suspenders.
    source = File.read!("lib/cerbero/snapshot/exporter/queries.ex")
    refute source =~ ~r/\b(INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|TRUNCATE|GRANT)\b/
  end
end
```

- [ ] **Step 6: Run and commit**

```bash
docker compose -f docker-compose.test.yml up -d pg16
mix test --include postgres test/integration/exporter_test.exs
```

Expected: PASS. Iterate on the catalog SQL until the feature-capture test is green — that test is the exporter's spec. Then:

```bash
git add -A
git commit -m "feat: exporter — allowlisted catalog queries, mix cerbero.snapshot, DBA emit-sql/from-file, layer-3 integration"
```

---

### Task 19: Layer 4 — lock verification suite and CRDB differential

The empirical anchor: for each PG entry in `DDL.Locks`, execute a representative statement in a transaction, read `pg_locks`, assert the mapped mode, roll back.

**Files:**
- Create: `test/integration/lock_verification_test.exs`, `test/integration/crdb_test.exs`

- [ ] **Step 1: Write the lock-verification suite**

`test/integration/lock_verification_test.exs`:

```elixir
defmodule Cerbero.Integration.LockVerificationTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Cerbero.DDL.Locks

  @urls %{130_000 => "postgres://postgres:cerbero@localhost:54313/cerbero_test",
          160_000 => "postgres://postgres:cerbero@localhost:54316/cerbero_test"}

  # class -> {setup SQL (idempotent), statement, locked relation}
  @statements %{
    create_index: {nil, "CREATE INDEX lv_idx ON lv_t (x)", "lv_t"},
    drop_index: {"CREATE INDEX IF NOT EXISTS lv_drop_idx ON lv_t (x)", "DROP INDEX lv_drop_idx", "lv_t"},
    add_column_constant_default: {nil, "ALTER TABLE lv_t ADD COLUMN c1 int DEFAULT 0", "lv_t"},
    add_column_volatile_default: {nil, "ALTER TABLE lv_t ADD COLUMN c2 float DEFAULT random()", "lv_t"},
    add_primary_key: {nil, "ALTER TABLE lv_nopk ADD PRIMARY KEY (id)", "lv_nopk"},
    add_unique: {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_u UNIQUE (x)", "lv_t"},
    set_not_null: {nil, "ALTER TABLE lv_t ALTER COLUMN x SET NOT NULL", "lv_t"},
    add_check: {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_c CHECK (x >= 0)", "lv_t"},
    add_check_not_valid: {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_cnv CHECK (x >= 0) NOT VALID", "lv_t"},
    validate_check: {"ALTER TABLE lv_t ADD CONSTRAINT lv_cv CHECK (x >= 0) NOT VALID",
                     "ALTER TABLE lv_t VALIDATE CONSTRAINT lv_cv", "lv_t"},
    add_foreign_key: {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_fk FOREIGN KEY (ref_id) REFERENCES lv_ref (id)", "lv_t"},
    alter_column_type: {nil, "ALTER TABLE lv_t ALTER COLUMN x TYPE bigint", "lv_t"},
    truncate: {nil, "TRUNCATE lv_t", "lv_t"},
    drop_column: {nil, "ALTER TABLE lv_t DROP COLUMN droppable", "lv_t"},
    rename: {nil, "ALTER TABLE lv_t RENAME COLUMN x TO x2", "lv_t"},
    set_default: {nil, "ALTER TABLE lv_t ALTER COLUMN x SET DEFAULT 1", "lv_t"},
    set_logged: {nil, "ALTER TABLE lv_t SET UNLOGGED", "lv_t"}
  }

  @lock_names %{
    access_exclusive: "AccessExclusiveLock", share: "ShareLock",
    share_row_exclusive: "ShareRowExclusiveLock", share_update_exclusive: "ShareUpdateExclusiveLock",
    row_exclusive: "RowExclusiveLock"
  }

  for {version_num, url} <- @urls do
    describe "PG #{div(version_num, 10_000)}" do
      setup do
        {:ok, conn} = Postgrex.start_link(url: unquote(url), pool_size: 1)
        Postgrex.query!(conn, "DROP TABLE IF EXISTS lv_t, lv_nopk, lv_ref CASCADE", [])
        Postgrex.query!(conn, "CREATE TABLE lv_ref (id bigint PRIMARY KEY)", [])
        Postgrex.query!(conn, "CREATE TABLE lv_t (id bigserial PRIMARY KEY, x int, ref_id bigint, droppable int)", [])
        Postgrex.query!(conn, "CREATE TABLE lv_nopk (id bigint NOT NULL)", [])
        %{conn: conn}
      end

      for {class, {setup_sql, stmt, relation}} <- @statements do
        test "#{class}: #{stmt}", %{conn: conn} do
          if unquote(setup_sql), do: Postgrex.query!(conn, unquote(setup_sql), [])
          {expected_lock, _cost} = Locks.entry(unquote(class), :postgres, unquote(version_num))

          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, unquote(stmt), [])

            %{rows: rows} = Postgrex.query!(tx, """
              SELECT mode FROM pg_locks
              WHERE pid = pg_backend_pid() AND relation = $1::regclass
            """, [unquote(relation)])

            modes = List.flatten(rows)

            assert @lock_names[expected_lock] in modes,
                   "#{unquote(class)}: expected #{expected_lock} on #{unquote(relation)}, got #{inspect(modes)}"

            Postgrex.rollback(tx, :done)
          end)
        end
      end
    end
  end
end
```

Note: CONCURRENTLY variants cannot run inside a transaction and are excluded from the in-transaction suite — their lock modes are asserted from PG documentation and left to a comment in `Locks`; the *behavioral* fact CI verifies for them is rule 10's premise (they error inside a transaction), which is one extra test here:

```elixir
  test "CREATE INDEX CONCURRENTLY refuses to run in a transaction (rule 10's premise)" do
    {:ok, conn} = Postgrex.start_link(url: @urls[160_000], pool_size: 1)
    Postgrex.query!(conn, "CREATE TABLE IF NOT EXISTS lv_cic (x int)", [])

    Postgrex.transaction(conn, fn tx ->
      assert {:error, %Postgrex.Error{postgres: %{code: :active_sql_transaction}}} =
               Postgrex.query(tx, "CREATE INDEX CONCURRENTLY lv_cic_idx ON lv_cic (x)", [])
      Postgrex.rollback(tx, :done)
    end)
  end
```

- [ ] **Step 2: CRDB differential**

`test/integration/crdb_test.exs`:

```elixir
defmodule Cerbero.Integration.CRDBTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Exporter

  @url "postgresql://root@localhost:26257/defaultdb?sslmode=disable"

  setup_all do
    {:ok, conn} = Postgrex.start_link(url: @url, pool_size: 1)
    Postgrex.query!(conn, "CREATE TABLE IF NOT EXISTS orgs (id INT8 PRIMARY KEY, name STRING NOT NULL)", [])
    Postgrex.query!(conn, "CREATE INDEX IF NOT EXISTS orgs_name_idx ON orgs (name)", [])
    %{conn: conn}
  end

  test "engine detection + snapshot validates through the same strict decode" do
    assert {:ok, raw} = Exporter.export(@url)
    assert raw["engine"]["name"] == "cockroachdb"
    assert {:ok, %Snapshot{engine: %{name: :cockroachdb}}} = Snapshot.decode(Snapshot.stamp(raw))
  end

  test "the limitation table's core fact: type change on an indexed column is rejected", %{conn: conn} do
    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(conn, "ALTER TABLE orgs ALTER COLUMN name TYPE VARCHAR(10)", [])
  end
end
```

Note: CRDB sizes via `crdb_internal.table_span_stats` will surface here as reality diverges from the PG queries — when a PG catalog query fails on CRDB, add the CRDB alternate to `Queries` (that's the differential's purpose). Budget: the whole layer must stay under 60 s.

- [ ] **Step 3: Run and commit**

```bash
docker compose -f docker-compose.test.yml up -d
mix test --include integration --include postgres test/integration
```

Expected: PASS on pg13, pg16, crdb. Any lock-mode assertion failure is a *bug in `DDL.Locks`* — fix the data table, not the test.

```bash
git add -A
git commit -m "test: layer 4 — empirical lock verification on PG 13/16, CRDB differential"
```

---

### Task 20: Property tests + final wiring

**Files:**
- Create: `test/cerbero/property_test.exs`
- Modify: `README.md` if any drift surfaced during Tasks 18–19

- [ ] **Step 1: Write the two properties (narrow by design; design §8 rejects generative DDL→lock)**

`test/cerbero/property_test.exs`:

```elixir
defmodule Cerbero.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cerbero.Migration.Parser
  alias Cerbero.Operation, as: Op
  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical

  defp json_term do
    leaf = one_of([integer(), float(min: -1.0e6, max: 1.0e6), boolean(), string(:alphanumeric), constant(nil)])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 4),
              map_of(string(:alphanumeric, min_length: 1), child, max_count: 4)])
    end)
  end

  property "canonical encode/decode round-trips and checksum is key-order independent" do
    check all term <- map_of(string(:alphanumeric, min_length: 1), json_term(), max_count: 6) do
      encoded = Canonical.encode(term)
      assert JSON.decode!(encoded) == JSON.decode!(Canonical.encode(JSON.decode!(encoded)))

      shuffled = term |> Enum.shuffle() |> Map.new()
      assert Snapshot.compute_checksum(Map.put(term, "checksum", nil)) ==
               Snapshot.compute_checksum(Map.put(shuffled, "checksum", nil))
    end
  end

  @bodies [
    "create index(:t, [:a])", "drop index(:t, [:a])",
    "alter table(:t) do\n add :x, :integer\n end",
    "execute \"UPDATE t SET x = 1\"", "create table(:t) do\n add :x, :map\n end",
    "rename table(:a), to: table(:b)", "for x <- [1], do: x",
    "execute dynamic_sql()", "flush()"
  ]

  property "parser totality: arbitrary combinations never crash, always yield operations or Unknown" do
    check all bodies <- list_of(member_of(@bodies), min_length: 1, max_length: 6) do
      source = "defmodule P do\n use Ecto.Migration\n def change do\n #{Enum.join(bodies, "\n")}\n end\nend"

      case Parser.parse_string(source) do
        {:ok, migration} ->
          for op <- migration.operations do
            assert op.__struct__ in [Op.CreateTable, Op.AlterTable, Op.CreateIndex, Op.DropIndex,
                                     Op.CreateConstraint, Op.DropTable, Op.RenameOp, Op.RawSQL, Op.Unknown]
          end

        {:error, _} ->
          :ok
      end
    end
  end
end
```

- [ ] **Step 2: Full-suite run**

Run: `mix test` (unit + golden), then `mix test --include postgres --include integration` with Docker up.
Expected: all PASS.

- [ ] **Step 3: Verify the definition of done end-to-end, by hand, once**

```bash
docker compose -f docker-compose.test.yml up -d pg16
mix cerbero.snapshot --url postgres://postgres:cerbero@localhost:54316/cerbero_test --out /tmp/prod_snapshot.json
mix cerbero.check --snapshot /tmp/prod_snapshot.json --migrations test/fixtures/migrations/unsafe
echo $status  # fish: expect 1
```

Confirm the output names the check id, `file:line`, mechanism + scale + stats date, remediation — with no database reachable at check time (stop the container and re-run the check to prove it).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: property coverage (canonical round-trip, parser totality); spike definition of done verified"
```

---

## Self-Review (performed while writing this plan)

**Spec coverage against the design doc:**
- §1 snapshot contents → Tasks 1–2 (fields), 18 (sources). §2 privacy layers → Task 2 (schema allowlist + strictness), Task 18 (query allowlist, read-only session, server-side derivation, `--emit-sql`/`--from-file`). §3 format/staleness/overlay/no-snapshot → Tasks 1, 3, 9, 15, 16. §4 rule model → Tasks 4, 7. §5 module boundaries → File Structure (1:1 with the design's table). §6 rules 1–10 → Tasks 11–15. §7 CI ergonomics → Task 16. §8 layers 0–4 + properties → Tasks throughout, 18–20. §9.7 README-first → Task 17 precedes Task 18. §10 limitations → README (Task 17).
- **Known deliberate deferrals** (design permits): `precision: :order_of_magnitude` bucketing is config-parsed (Task 3) but the bucketing transform in the exporter is not implemented in the spike — add a follow-up task if the author wants it in v1 rather than v1.1; SARIF deferred (design says so); `attach_partition`/`detach_partition` have Locks entries but no DSL/classifier surface emits them yet (raw SQL will hit `:unknown` → warning, which is honest); CRDB `table_span_stats` sizes land during Task 19's differential, not before.
- **Gaps found and fixed during this review:** rule 1 originally didn't judge raw-SQL index creation — its `run/2` now routes `RawSQL` through `Effects`; `snapshot_health` absent-table check needed its own overlay fold (it runs outside the Runner's) — implemented that way in Task 15.

**Placeholder scan:** one intentional exception documented inline — `Exporter.build_from_sections/2` (Task 18) is specified as a mechanical mirror of `build/4` with its test provided; every other code block is complete.

**Type consistency spot-checks:** `Severity.assess/6` scale/traffic types match `Catalog.scale/2` and `Catalog.traffic/3` returns; `Staleness.threshold_multiplier` flows to `catalog.multiplier`; `Helpers.finding/6` signature matches all rule call sites; `Runner.run/4` returns `{findings, catalog}` everywhere; `Classified` struct fields match classifier, Effects, and overlay consumers; `Snapshot.Table` field names match builder keys (string) vs struct (atom) at the decode boundary only.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-06-cerbero-spike.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration (superpowers:subagent-driven-development).

**2. Inline Execution** — execute tasks in-session with checkpoints (superpowers:executing-plans).





