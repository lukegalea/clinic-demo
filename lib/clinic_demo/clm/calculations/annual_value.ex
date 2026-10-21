defmodule ClinicDemo.Clm.Calculations.AnnualValue do
  @moduledoc """
  The contract's total value spread over its term, per 365 days. Nil without a
  total value.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:total_value, :starts_on, :expires_on]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn
      %{total_value: nil} ->
        nil

      %{total_value: total, starts_on: starts_on, expires_on: expires_on} ->
        days = Date.diff(expires_on, starts_on) + 1

        total
        |> Decimal.mult(365)
        |> Decimal.div(days)
        |> Decimal.round(0)
    end)
  end
end
