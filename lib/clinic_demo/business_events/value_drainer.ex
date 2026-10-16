defmodule ClinicDemo.BusinessEvents.ValueDrainer do
  @moduledoc """
  Keeps the value projection caught up with the ledger while the app runs,
  so a visit completed on the board shows up on /revenue.

  The publish bridge calls `nudge/0` after each ledger write. Nudges
  debounce for `@debounce_ms`, so a burst of moments folds once, and the
  fold runs in this process, so nudges that arrive mid-fold queue up and
  earn exactly one more pass. A nudge can land before the visit's
  transaction commits; the `@sweep_ms` sweep picks up an event the
  debounced pass ran too early to see.

  `drain/0` is the only way to fold the real ledger. It holds a Postgres
  advisory lock for the whole fold, because the projection engine's drain
  reads its checkpoint without one: two concurrent drains would apply the
  same event twice. That matters on fly, where the release seed runs as a
  second BEAM beside the app. The lock is session-scoped on a checked-out
  connection; if this process dies mid-fold, DBConnection drops that
  connection and Postgres releases the lock with it.

  After a fold that applied events, it broadcasts `{:value_projection_drained,
  count}` on `topic/0`.

  Disabled in test (`config :clinic_demo, :value_drainer, false`): the suite
  drains explicitly, and a process outside the SQL sandbox cannot read.
  """

  use GenServer

  require Logger

  alias ClinicDemo.BusinessEvents.ValueProjector

  @debounce_ms 300
  @sweep_ms 30_000
  @lock_key :erlang.phash2({ValueProjector, :clinic})

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for a fold soon. A no-op when the drainer isn't running."
  def nudge do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :nudge)
    end

    :ok
  end

  @doc "The PubSub topic a fold that applied events broadcasts on."
  def topic, do: "business_events:value_projection"

  @doc """
  Folds every ledger event past the checkpoint into the value projection,
  serialized with every other caller. Returns the number folded.
  """
  def drain do
    ClinicDemo.Repo.checkout(
      fn ->
        ClinicDemo.Repo.query!("SELECT pg_advisory_lock($1)", [@lock_key])

        try do
          ValueProjector.drain(:clinic)
        after
          ClinicDemo.Repo.query!("SELECT pg_advisory_unlock($1)", [@lock_key])
        end
      end,
      timeout: :infinity
    )
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_info(:nudge, %{timer: nil} = state) do
    {:noreply, %{state | timer: Process.send_after(self(), :fold, @debounce_ms)}}
  end

  def handle_info(:nudge, state), do: {:noreply, state}

  def handle_info(:fold, state) do
    fold()
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:sweep, state) do
    fold()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # A failed fold is logged and retried by the next nudge or sweep; the
  # engine's dead-letter table holds an event it could not digest.
  defp fold do
    case drain() do
      0 ->
        :ok

      count ->
        Phoenix.PubSub.broadcast(ClinicDemo.PubSub, topic(), {:value_projection_drained, count})
    end
  rescue
    error -> Logger.warning("value projection fold failed: #{Exception.message(error)}")
  end
end
