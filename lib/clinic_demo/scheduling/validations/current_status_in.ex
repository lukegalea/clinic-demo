defmodule ClinicDemo.Scheduling.Validations.CurrentStatusIn do
  @moduledoc """
  Guards a status transition by checking the status the record *had*, not the
  one the action is about to set.

  This reads `changeset.data`, so it cannot be expressed atomically; the
  actions that use it declare `require_atomic? false` and say why.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if is_list(opts[:from]) and opts[:from] != [] do
      {:ok, opts}
    else
      {:error, "`:from` must be a non-empty list of statuses"}
    end
  end

  @impl true
  def describe(opts) do
    [
      message: "cannot be done to an appointment that is %{current}",
      vars: [from: Enum.join(opts[:from], ", ")]
    ]
  end

  @impl true
  def validate(changeset, opts, _context) do
    current = Map.get(changeset.data, :status)

    if current in opts[:from] do
      :ok
    else
      {:error,
       field: :status,
       message: "cannot be done to an appointment that is %{current}",
       vars: [current: to_string(current)]}
    end
  end
end
