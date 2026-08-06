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
  def entry(:detach_partition, :postgres, version_num)
      when version_num >= 140_000 and version_num < 150_000,
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
