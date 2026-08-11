defmodule Cerbero.DDL.LocksTest do
  use ExUnit.Case, async: true

  alias Cerbero.DDL.Effects
  alias Cerbero.DDL.Locks

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
    {:set_unlogged, {:access_exclusive, :rewrite}},
    {:truncate, {:access_exclusive, :metadata_only}},
    # Table-level lock is SHARE (same as CREATE INDEX) — see the layer 4
    # empirical note on `reindex` in Locks; ACCESS EXCLUSIVE is only what
    # each individual index gets while it's being rebuilt.
    {:reindex, {:share, :full_scan}},
    {:reindex_concurrently, {:share_update_exclusive, :full_scan}},
    {:drop_column, {:access_exclusive, :metadata_only}},
    {:rename, {:access_exclusive, :metadata_only}},
    {:set_default, {:access_exclusive, :metadata_only}},
    {:drop_default, {:access_exclusive, :metadata_only}},
    {:drop_table, {:access_exclusive, :metadata_only}},
    {:create_table, {:none, :metadata_only}}
  ]

  test "the v1 PG lock/cost table" do
    for {class, expected} <- @expected do
      assert Locks.entry(class, :postgres, 150_000) == expected, "#{class}"
    end
  end

  test "detach_partition is always AEL; detach_partition_concurrently is SUE on PG >= 14" do
    # plain DETACH PARTITION
    assert Locks.entry(:detach_partition, :postgres, 130_000) ==
             {:access_exclusive, :metadata_only}

    assert Locks.entry(:detach_partition, :postgres, 150_000) ==
             {:access_exclusive, :metadata_only}

    # DETACH PARTITION CONCURRENTLY (introduced PG 14)
    assert Locks.entry(:detach_partition_concurrently, :postgres, 130_000) ==
             {:access_exclusive, :metadata_only}

    assert Locks.entry(:detach_partition_concurrently, :postgres, 140_000) ==
             {:share_update_exclusive, :metadata_only}

    assert Locks.entry(:detach_partition_concurrently, :postgres, 150_000) ==
             {:share_update_exclusive, :metadata_only}
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
