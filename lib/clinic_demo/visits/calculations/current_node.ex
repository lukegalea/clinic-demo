defmodule ClinicDemo.Visits.Calculations.CurrentNode do
  @moduledoc """
  The node id of the instance's live token — where the visit stands — or nil
  once it has ended. One live token is the norm; when several are alive the
  earliest parked wins, so the answer is deterministic.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(records, _opts, _context) do
    ids = Enum.map(records, & &1.id)

    node_by_instance =
      ClinicDemo.Visits.Token
      |> Ash.Query.filter(instance_id in ^ids and status in [:active, :executing, :waiting])
      |> Ash.Query.sort(parked_at: :asc)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.instance_id, &1.node_id})

    Enum.map(records, &Map.get(node_by_instance, &1.id))
  end
end
