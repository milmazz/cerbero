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
end
