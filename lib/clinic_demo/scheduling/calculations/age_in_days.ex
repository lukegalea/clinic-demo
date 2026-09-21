defmodule ClinicDemo.Scheduling.Calculations.AgeInDays do
  @moduledoc """
  Days since the patient's date of birth, or nil when it is unknown.

  A module calculation rather than an expression: Ash has no `date_diff`
  expression, and pushing this into a Postgres fragment would make the
  resource untestable without a database.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:date_of_birth]

  @impl true
  def calculate(records, _opts, _context) do
    today = Date.utc_today()

    Enum.map(records, fn
      %{date_of_birth: nil} -> nil
      %{date_of_birth: dob} -> Date.diff(today, dob)
    end)
  end
end
