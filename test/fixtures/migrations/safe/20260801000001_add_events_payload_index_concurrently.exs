defmodule AppRepo.Migrations.AddEventsPayloadIndexConcurrently do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(index(:events, [:org_id, :inserted_at], concurrently: true))
  end
end
