defmodule Cerbero.Snapshot do
  @moduledoc """
  The snapshot artifact: decode, verify, canonically re-encode.

  The checksum detects corruption and hand-edits — anyone who can commit
  can regenerate it; it is not tamper-proofing. Tamper-proofing is the
  optional Ed25519 signature (`Cerbero.Snapshot.Signature`): when
  `.cerbero.exs` pins `snapshot_verify_keys`, a snapshot must carry
  a valid signature from one of those keys to load.
  """

  alias Cerbero.Snapshot.Canonical
  alias Cerbero.Snapshot.Signature

  defstruct [
    :format_version,
    :cerbero_version,
    :collected_at,
    :database,
    :engine,
    :standby,
    :stats_provenance,
    :stats_reset,
    :applied_migrations,
    :tables,
    precision: :exact
  ]

  @type t :: %__MODULE__{}

  defmodule Table do
    @moduledoc "One table's decoded catalog metadata: stats, columns, indexes, constraints."
    defstruct [
      :schema,
      :name,
      :partitioned,
      :partition_of,
      :reltuples,
      :relpages,
      :n_live_tup,
      :last_analyze,
      :last_autoanalyze,
      :seq_scan,
      :idx_scan,
      :n_tup_ins,
      :n_tup_upd,
      :n_tup_del,
      :heap_bytes,
      :total_bytes,
      :columns,
      :indexes,
      :constraints
    ]

    @type t :: %__MODULE__{}
  end

  # v1 is the whole 0.1.0 baseline, including the optional top-level
  # "precision" field ("exact" | "order_of_magnitude" — required to interpret
  # count/byte fields honestly in order-of-magnitude export mode) and the
  # optional top-level "signature" field (Ed25519 over the checksum — see
  # Cerbero.Snapshot.Signature). The version only moves on a
  # backwards-incompatible change after release.
  @format_version 1
  @min_supported 1

  def format_version, do: @format_version

  @spec compute_checksum(map()) :: String.t()
  def compute_checksum(map) when is_map(map) do
    # The signature is excluded alongside the checksum itself: it is
    # computed FROM the checksum, so covering it would make
    # sign-after-stamp self-invalidating.
    canonical = map |> Map.put("checksum", nil) |> Map.delete("signature") |> Canonical.encode()
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  @spec stamp(map()) :: map()
  def stamp(map), do: Map.put(map, "checksum", compute_checksum(map))

  @spec write!(map(), Path.t()) :: :ok
  def write!(map, path), do: File.write!(path, Canonical.encode(stamp(map)))

  @spec load(Path.t(), keyword()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def load(path, opts \\ []) do
    verify_keys = Keyword.get(opts, :verify_keys, [])

    with {:ok, bytes} <- read(path),
         {:ok, raw} <- decode_json(bytes),
         :ok <- verify_checksum(raw),
         :ok <- Signature.verify(raw, verify_keys),
         :ok <- gate_version(raw) do
      decode(raw)
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

  # Typed strict decode

  @top_fields ~w(applied_migrations cerbero_version checksum collected_at database engine format_version precision signature standby stats_provenance stats_reset tables)
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
  @constraint_types %{
    "primary" => :primary,
    "unique" => :unique,
    "foreign_key" => :foreign_key,
    "check" => :check,
    "exclusion" => :exclusion
  }
  @default_kinds %{"sequence" => :sequence, "expression" => :expression, "literal" => :literal}
  @key_kinds %{"column" => :column, "expression" => :expression}
  @precisions %{"exact" => :exact, "order_of_magnitude" => :order_of_magnitude}

  # Engine floors (design §9.3): PG >= 13 (server_version_num), CRDB >= v23.1
  # (major*1000 + minor*100 + patch encoding used by the exporter).
  @engine_floors %{
    postgres: {130_000, "PostgreSQL >= 13"},
    cockroachdb: {23_100, "CockroachDB >= v23.1"}
  }

  @doc "Refuses engine versions below the supported floors."
  @spec check_engine_floor(:postgres | :cockroachdb, integer()) ::
          :ok | {:error, {:unsupported_engine, String.t()}}
  def check_engine_floor(engine, version_num) do
    {floor, requirement} = Map.fetch!(@engine_floors, engine)

    if is_integer(version_num) and version_num >= floor do
      :ok
    else
      {:error,
       {:unsupported_engine,
        "snapshot is from #{engine} version_num #{inspect(version_num)}; cerbero supports #{requirement}"}}
    end
  end

  @spec decode(map()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def decode(raw) do
    with :ok <- strict(raw, @top_fields, "$"),
         :ok <- strict(raw["engine"], @engine_fields, "$.engine"),
         {:ok, engine_name} <- enum(raw["engine"]["name"], @engines, "$.engine.name"),
         :ok <- check_engine_floor(engine_name, raw["engine"]["version_num"]),
         {:ok, provenance} <- enum(raw["stats_provenance"], @provenance, "$.stats_provenance"),
         {:ok, collected_at} <- datetime(raw["collected_at"], "$.collected_at"),
         {:ok, stats_reset} <- optional_datetime(raw["stats_reset"], "$.stats_reset"),
         {:ok, precision} <-
           enum(Map.get(raw, "precision", "exact"), @precisions, "$.precision"),
         {:ok, tables} <- decode_tables(raw["tables"]) do
      {:ok,
       %__MODULE__{
         format_version: raw["format_version"],
         cerbero_version: raw["cerbero_version"],
         collected_at: collected_at,
         database: raw["database"],
         engine: %{
           name: engine_name,
           version: raw["engine"]["version"],
           version_num: raw["engine"]["version_num"]
         },
         standby: raw["standby"],
         stats_provenance: provenance,
         stats_reset: stats_reset,
         applied_migrations: raw["applied_migrations"],
         tables: tables,
         precision: precision
       }}
    end
  end

  defp decode_tables(tables) when is_list(tables) do
    map_while_ok(tables, fn t ->
      with :ok <- strict(t, @table_fields, "$.tables[#{t["name"]}]"),
           {:ok, columns} <-
             validate_list(t["columns"], "$.tables[#{t["name"]}].columns", fn l ->
               map_while_ok(l, &decode_column/1)
             end),
           {:ok, indexes} <-
             validate_list(t["indexes"], "$.tables[#{t["name"]}].indexes", fn l ->
               map_while_ok(l, &decode_index/1)
             end),
           {:ok, constraints} <-
             validate_list(t["constraints"], "$.tables[#{t["name"]}].constraints", fn l ->
               map_while_ok(l, &decode_constraint/1)
             end),
           {:ok, la} <- optional_datetime(t["last_analyze"], "last_analyze"),
           {:ok, laa} <- optional_datetime(t["last_autoanalyze"], "last_autoanalyze") do
        {:ok,
         %Table{
           schema: t["schema"],
           name: t["name"],
           partitioned: t["partitioned"],
           partition_of: t["partition_of"],
           reltuples: t["reltuples"],
           relpages: t["relpages"],
           n_live_tup: t["n_live_tup"],
           last_analyze: la,
           last_autoanalyze: laa,
           seq_scan: t["seq_scan"],
           idx_scan: t["idx_scan"],
           n_tup_ins: t["n_tup_ins"],
           n_tup_upd: t["n_tup_upd"],
           n_tup_del: t["n_tup_del"],
           heap_bytes: t["heap_bytes"],
           total_bytes: t["total_bytes"],
           columns: columns,
           indexes: indexes,
           constraints: constraints
         }}
      end
    end)
  end

  defp decode_tables(_), do: {:error, {:invalid_value, "$.tables", :not_a_list}}

  defp decode_column(c) do
    with :ok <- strict(c, @column_fields, "column #{c["name"]}"),
         {:ok, default} <- decode_default(c["default"]),
         {:ok, generated} <- decode_generated(c["generated"]) do
      {:ok,
       %{
         name: c["name"],
         type: c["type"],
         not_null: c["not_null"],
         identity: c["identity"],
         generated: generated,
         default: default
       }}
    end
  end

  defp decode_generated(nil), do: {:ok, nil}
  defp decode_generated("stored"), do: {:ok, :stored}
  defp decode_generated(value), do: {:error, {:invalid_value, "column.generated", value}}

  defp decode_default(nil), do: {:ok, nil}

  defp decode_default(d) do
    with :ok <- strict(d, @default_fields, "default"),
         {:ok, kind} <- enum(d["kind"], @default_kinds, "default.kind") do
      {:ok, %{present: d["present"], volatile: d["volatile"], kind: kind}}
    end
  end

  defp decode_index(i) do
    with :ok <- strict(i, @index_fields, "index #{i["name"]}"),
         {:ok, keys} <-
           validate_list(i["keys"], "index.keys", fn l -> map_while_ok(l, &decode_key/1) end) do
      {:ok,
       %{
         name: i["name"],
         unique: i["unique"],
         primary: i["primary"],
         valid: i["valid"],
         method: i["method"],
         partial: i["partial"],
         bytes: i["bytes"],
         keys: keys
       }}
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
       %{
         name: c["name"],
         type: type,
         columns: c["columns"],
         validated: c["validated"],
         references: refs,
         on_delete: c["on_delete"],
         on_update: c["on_update"],
         is_not_null_check_on: c["is_not_null_check_on"]
       }}
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

  defp validate_list(list, _path, fun) when is_list(list) do
    fun.(list)
  end

  defp validate_list(_other, path, _fun) do
    {:error, {:invalid_value, path, :not_a_list}}
  end

  defp map_while_ok(list, fun) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
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
end
