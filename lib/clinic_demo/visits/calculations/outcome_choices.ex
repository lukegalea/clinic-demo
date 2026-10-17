defmodule ClinicDemo.Visits.Calculations.OutcomeChoices do
  @moduledoc """
  The outcomes a task's step declares, as the worklist card reads them:
  `"Arrived or No show"`. Built from the engine's `:outcomes` calculation,
  which reads them from the definition the visit's instance pinned; `nil`
  when the step declares none.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:outcomes]

  @impl true
  def calculate(tasks, _opts, _context), do: Enum.map(tasks, &phrase(&1.outcomes))

  @doc ~S|`["arrived", "no_show"]` as `"Arrived or No show"`; `nil` for none.|
  @spec phrase([String.t()] | nil) :: String.t() | nil
  def phrase([_ | _] = outcomes) do
    outcomes
    |> Enum.map_join(", ", &label/1)
    |> String.replace(~r/, (?=[^,]*$)/, " or ")
  end

  def phrase(_none), do: nil

  defp label(outcome), do: outcome |> String.replace("_", " ") |> String.capitalize()
end
