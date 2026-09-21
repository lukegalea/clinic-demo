defmodule ClinicDemo.Scheduling.Calculations.AgeBand do
  @moduledoc """
  Which of four life stages the patient is in, as a string, or nil when the date
  of birth is unknown.

  Nil is the honest answer for a rescue with no papers, and it is also the useful
  one: the triage table's age column tests `"neonate", "senior"`, and a null
  input matches neither, so an animal of unknown age is triaged on its
  presenting signs alone rather than on a guess.

  The thresholds are species-neutral, which a real clinic's would not be — a
  ten-year-old rabbit and a ten-year-old labrador are not in the same place. The
  simplification is here rather than in the DMN on purpose: the band is a fact
  about the animal, and the rule that reads it is what a vet edits.
  """

  use Ash.Resource.Calculation

  @neonate_days 180
  @juvenile_days 365
  @senior_days 3650

  @impl true
  def load(_query, _opts, _context), do: [:date_of_birth]

  @impl true
  def calculate(records, _opts, _context) do
    today = Date.utc_today()

    Enum.map(records, fn
      %{date_of_birth: nil} -> nil
      %{date_of_birth: dob} -> band(Date.diff(today, dob))
    end)
  end

  defp band(days) when days < @neonate_days, do: "neonate"
  defp band(days) when days < @juvenile_days, do: "juvenile"
  defp band(days) when days < @senior_days, do: "adult"
  defp band(_days), do: "senior"
end
