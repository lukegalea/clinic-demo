defmodule ClinicDemo.Visits.Calculations.SubjectLabel do
  @moduledoc """
  What the instance is about, as a person reads it: the patient's name and
  the booking reason. Instances in this demo are always about appointments;
  anything else is named honestly rather than guessed at.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:subject_id, :subject_type]

  @impl true
  def calculate(records, _opts, _context) do
    subject_ids =
      records
      |> Map.new(&{&1.subject_id, nil})
      |> Map.keys()

    appointment_by_id =
      ClinicDemo.Scheduling.Appointment
      |> Ash.Query.filter(id in ^subject_ids)
      |> Ash.Query.load(:patient)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1})

    Enum.map(records, fn record ->
      case appointment_by_id[record.subject_id] do
        %ClinicDemo.Scheduling.Appointment{} = appointment ->
          "#{appointment.patient.name} — #{appointment.reason}"

        _ ->
          "#{record.subject_type} #{String.slice(record.subject_id, 0..7)}"
      end
    end)
  end
end
