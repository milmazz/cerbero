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

    assert %Classified{
             class: :create_index,
             table: "public.events",
             concurrently: true,
             unique: true
           } =
             one("CREATE UNIQUE INDEX CONCURRENTLY idx ON \"public\".\"events\" (user_id)")
  end

  test "drop index" do
    assert %Classified{class: :drop_index, concurrently: false} = one("DROP INDEX idx")

    assert %Classified{class: :drop_index, concurrently: true} =
             one("drop index concurrently if exists idx")
  end

  test "the safe NOT NULL two-step, raw-SQL form (design §3 overlay requirement)" do
    assert %Classified{
             class: :add_check_is_not_null,
             table: "events",
             column: "org_id",
             constraint: "org_id_not_null",
             not_valid: true
           } =
             one(
               "ALTER TABLE events ADD CONSTRAINT org_id_not_null CHECK (org_id IS NOT NULL) NOT VALID"
             )

    assert %Classified{
             class: :validate_constraint,
             table: "events",
             constraint: "org_id_not_null"
           } =
             one("ALTER TABLE events VALIDATE CONSTRAINT org_id_not_null")

    assert %Classified{class: :set_not_null, table: "events", column: "org_id"} =
             one("ALTER TABLE events ALTER COLUMN org_id SET NOT NULL")
  end

  test "raw ADD PRIMARY KEY / ADD UNIQUE are their own classes, not swallowed by add_column" do
    assert %Classified{class: :add_primary_key, table: "events", constraint: nil} =
             one("ALTER TABLE events ADD PRIMARY KEY (id)")

    assert %Classified{class: :add_primary_key, table: "events", constraint: "events_pkey"} =
             one("ALTER TABLE events ADD CONSTRAINT events_pkey PRIMARY KEY (id)")

    assert %Classified{class: :add_unique, table: "events", constraint: nil} =
             one("ALTER TABLE events ADD UNIQUE (org_id)")

    assert %Classified{class: :add_unique, table: "events", constraint: "events_org_id_key"} =
             one("ALTER TABLE events ADD CONSTRAINT events_org_id_key UNIQUE (org_id)")
  end

  test "generic check, fk, type change, add column" do
    assert %Classified{class: :add_check, not_valid: false} =
             one("ALTER TABLE t ADD CONSTRAINT positive CHECK (price > 0)")

    assert %Classified{class: :add_foreign_key, table: "events", not_valid: true} =
             one(
               "ALTER TABLE events ADD CONSTRAINT fk FOREIGN KEY (org_id) REFERENCES orgs (id) NOT VALID"
             )

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

  test "create index, unnamed (valid, common PG syntax)" do
    assert %Classified{class: :create_index, table: "events", concurrently: false, unique: false} =
             one("CREATE INDEX ON events (col)")

    assert %Classified{class: :create_index, table: "events", concurrently: false, unique: true} =
             one("CREATE UNIQUE INDEX ON events (col)")

    assert %Classified{class: :create_index, table: "events", concurrently: true, unique: false} =
             one("CREATE INDEX CONCURRENTLY ON events (col)")
  end

  test "comment/quote boundaries don't bleed into each other (regression)" do
    # A `--` sitting inside a string literal must not be treated as a
    # comment start — and must not eat the statement(s) that follow it.
    assert [
             %Classified{class: :update, table: "events"},
             %Classified{class: :delete, table: "events"}
           ] =
             Classifier.classify(
               "UPDATE events SET note = '--x' WHERE id = 1; DELETE FROM events WHERE id = 2;"
             )

    # Same for `/*` inside a string literal — must not be treated as a
    # block comment start.
    assert [
             %Classified{class: :update, table: "events"},
             %Classified{class: :delete, table: "events"}
           ] =
             Classifier.classify(
               "UPDATE events SET note = '/* not a comment' WHERE id = 1; DELETE FROM events WHERE id = 2;"
             )

    # A quote character inside a `--` comment must not open a string (and
    # so must not swallow the rest of the input hunting for a close quote).
    assert %Classified{class: :truncate, table: "events"} =
             one("TRUNCATE events -- \"unterminated quote\ncomment")

    # Nested block comments (valid PG) collapse cleanly, without corrupting
    # the statement around them.
    assert %Classified{class: :truncate, table: "events"} =
             one("TRUNCATE /* outer /* inner */ still outer */ events")
  end

  test "invalid/truncated UTF-8 never crashes classify/1" do
    assert [%Classified{class: :unknown}] = Classifier.classify(<<0, 1, 2, 3, 255>>)

    assert [%Classified{class: :unknown}] =
             Classifier.classify("UPDATE events SET note = 'caf" <> <<0xC3>>)
  end

  test "raw RENAME (table, column, constraint) classifies as :rename with the table" do
    assert %Classified{class: :rename, table: "events"} =
             one("ALTER TABLE events RENAME TO events_old")

    assert %Classified{class: :rename, table: "events"} =
             one("ALTER TABLE events RENAME COLUMN org_id TO owner_org_id")

    assert %Classified{class: :rename, table: "events"} =
             one("ALTER TABLE events RENAME CONSTRAINT c1 TO c2")
  end

  test "ATTACH/DETACH PARTITION capture parent and partition" do
    assert %Classified{class: :attach_partition, table: "events", ref_table: "events_p0"} =
             one("ALTER TABLE events ATTACH PARTITION events_p0 FOR VALUES FROM (0) TO (10)")

    assert %Classified{
             class: :detach_partition,
             table: "events",
             ref_table: "events_p0",
             concurrently: false
           } =
             one("ALTER TABLE events DETACH PARTITION events_p0")

    assert %Classified{class: :detach_partition, concurrently: true} =
             one("ALTER TABLE events DETACH PARTITION events_p0 CONCURRENTLY")
  end

  test "SET LOGGED / SET UNLOGGED are distinct classes" do
    assert %Classified{class: :set_logged, table: "events"} =
             one("ALTER TABLE events SET LOGGED")

    assert %Classified{class: :set_unlogged, table: "events"} =
             one("ALTER TABLE events SET UNLOGGED")
  end

  test "SET DEFAULT / DROP DEFAULT on a column" do
    assert %Classified{class: :set_default, table: "events", column: "org_id"} =
             one("ALTER TABLE events ALTER COLUMN org_id SET DEFAULT 0")

    assert %Classified{class: :drop_default, table: "events", column: "org_id"} =
             one("ALTER TABLE events ALTER COLUMN org_id DROP DEFAULT")
  end

  test "quoted identifiers preserve case" do
    assert %Classified{class: :create_table, table: "Flags"} =
             one("CREATE TABLE \"Flags\" (id int)")
  end
end
