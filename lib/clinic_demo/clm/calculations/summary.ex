defmodule ClinicDemo.Clm.Calculations.Summary do
  @moduledoc """
  One field across a contract's lines, as the hub shows it: the first distinct
  value and how many more ("Harbourfront Tower +3 more"). Nil without lines.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def load(_query, opts, _context), do: [lines: [opts[:field]]]

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, fn record ->
      case record.lines |> Enum.map(&Map.get(&1, opts[:field])) |> Enum.uniq() |> Enum.sort() do
        [] -> nil
        [one] -> one
        [first | rest] -> "#{first} +#{length(rest)} more"
      end
    end)
  end
end
