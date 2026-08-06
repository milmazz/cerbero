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
