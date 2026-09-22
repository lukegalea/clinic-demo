defmodule ClinicDemo.Decisions.Calculations.VisitLabel do
  @moduledoc """
  The evidence trail's "which visit was this?" answer: the patient and the
  reason, resolved from the evaluation's correlation_id (the visit instance's
  id) through to the appointment it was about. Cross-domain by nature —
  Evaluation to Instance to Appointment to Patient — which is why this is a
  module calculation rather than an expression.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:correlation_id]

  @impl true
  def calculate(records, _opts, _context) do
    instances =
      records
      |> Enum.map(& &1.correlation_id)
      |> Enum.reject(&is_nil/1)
      |> then(fn ids ->
        if ids == [] do
          %{}
        else
          ClinicDemo.Visits.Instance
          |> Ash.Query.filter(id in ^ids)
          |> Ash.read!(authorize?: false)
          |> Map.new(fn instance -> {instance.id, instance} end)
        end
      end)

    labels =
      Enum.map(records, fn record ->
        case Map.get(instances, record.correlation_id) do
          nil ->
            "standalone decision"

          instance ->
            visit_subject_label(instance)
        end
      end)

    {:ok, labels}
  end

  # The Instance's subject is the Appointment; resolve to the patient name
  # and reason — the same words the board and schedule lead with.
  defp visit_subject_label(instance) do
    require Ash.Query

    case ClinicDemo.Scheduling.Appointment
         |> Ash.Query.filter(id == ^instance.subject_id)
         |> Ash.Query.load(:patient)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = appointment} ->
        "#{appointment.patient.name} — #{appointment.reason}"

      _ ->
        "visit #{String.slice(instance.id || "", 0..7)}"
    end
  end
end
