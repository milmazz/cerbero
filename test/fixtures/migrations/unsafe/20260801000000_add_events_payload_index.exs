defmodule AppRepo.Migrations.AddEventsPayloadIndex do
  use Ecto.Migration

  def change do
    create(index(:events, [:org_id, :inserted_at]))
  end
end
