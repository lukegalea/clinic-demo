defmodule ClinicDemo.Visits.Invoker do
  @moduledoc """
  What a service task in the visit process actually does.

  Every entry below is an ordinary `ClinicDemo.Scheduling` code interface call,
  made as the actor the engine handed us. That is the whole of the integration,
  and it is deliberately thin: the process decides *when* an appointment is
  checked in, and the `:check_in` action — with its guard on the prior status —
  decides whether it may be. A node that reached around the action would be a
  second way to change a visit.

  `:discharge` is the one worth watching. It refuses anything that is not
  written up, so a process that reaches `Discharge` before the vet has recorded
  their notes fails loudly rather than closing an unfinished visit. The engine
  is authorized like every other caller and guarded like every other caller.

  ## Idempotency

  Node execution may run twice (usage rule 14: Oban redelivery). Each clause
  below names the state its action produces and returns `:ok` without calling
  again once the appointment is already in it. That is narrower than swallowing
  errors: a `discharge` on a visit that was never written up is still a failure,
  because it is not the same thing as a `discharge` that already happened.
  """

  @behaviour AshBpmn.ActionInvoker

  require Logger

  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.Appointment

  @actions ~w(record_triage check_in mark_no_show discharge alert_emergency_team)

  @doc """
  Whether the graph names an action this host can run.

  `ash_bpmn` calls this at publish time, so a diagram cannot ship against a
  service task that would fail at three in the morning on the first instance
  that reached it.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(action), do: action in @actions

  @impl true
  def invoke("record_triage", ctx) do
    urgency = ctx[:inputs]["urgency"]

    run(ctx, &(to_string(&1.triage_urgency) == to_string(urgency)), fn appointment, opts ->
      Scheduling.record_appointment_triage!(appointment, urgency, opts)
    end)
  end

  def invoke("check_in", ctx) do
    run(ctx, &(&1.status != :scheduled), &Scheduling.check_in_appointment!/2)
  end

  def invoke("mark_no_show", ctx) do
    run(ctx, &(&1.status == :no_show), &Scheduling.mark_appointment_no_show!/2)
  end

  def invoke("discharge", ctx) do
    run(ctx, &(&1.discharged_at != nil), &Scheduling.discharge_appointment!/2)
  end

  def invoke("alert_emergency_team", ctx) do
    # The seam where a real clinic pages the crash team. The demo logs, because
    # a demo that sent a page would be a demo nobody could run twice.
    Logger.info("emergency triage on appointment #{inspect(subject_id(ctx))}")
    :ok
  end

  def invoke(action, _ctx), do: {:error, "unknown action #{inspect(action)}"}

  defp run(ctx, done?, fun) do
    case ctx[:subject] do
      %Appointment{} = appointment ->
        unless done?.(appointment), do: fun.(appointment, actor: ctx[:actor])
        :ok

      nil ->
        {:error, "the visit process has no appointment to act on"}

      other ->
        {:error, "expected an appointment, got #{inspect(other)}"}
    end
  end

  defp subject_id(ctx), do: ctx[:subject] && ctx[:subject].id
end
