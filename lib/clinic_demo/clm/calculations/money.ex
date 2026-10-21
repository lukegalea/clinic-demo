defmodule ClinicDemo.Clm.Calculations.Money do
  @moduledoc """
  A decimal attribute or calculation as whole dollars ("$86,400"). Nil stays
  nil. Currency is assumed CAD/USD dollars, as in the design.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, fn record ->
      case Map.get(record, opts[:field]) do
        nil -> nil
        amount -> "$" <> group(amount |> Decimal.round(0) |> Decimal.to_integer())
      end
    end)
  end

  defp group(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
