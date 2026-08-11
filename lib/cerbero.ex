defmodule Cerbero do
  @moduledoc """
  Offline safety checks for Ecto migrations, judged against a committed
  snapshot of production catalog metadata (Postgres and CockroachDB).

  Cerbero detects a specific catalog-derivable class of unsafe migrations,
  judged at export-time scale. It does not certify migrations as safe; it
  judges the statement, not the moment.
  """
end
