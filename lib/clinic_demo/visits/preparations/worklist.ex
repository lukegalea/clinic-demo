defmodule ClinicDemo.Visits.Preparations.Worklist do
  @moduledoc """
  Scopes `ClinicDemo.Visits.HumanTask`'s `:worklist` read to the actor: open
  tasks they are a candidate for (the candidacy rows materialised when the
  task was created) and claimed tasks they hold.

  A preparation rather than the read's own `filter`, because Ash refuses a
  read whose action filter references the actor when there is none. Nobody
  acting is a normal state for the board (the "No one is acting" chip), and
  it reads nothing rather than failing.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, %{actor: %{id: actor_id}}) when not is_nil(actor_id) do
    Ash.Query.filter(
      query,
      (status == :open and
         exists(candidates, principal_type == :user and principal_id == ^actor_id)) or
        (status == :claimed and assignee_id == ^actor_id)
    )
  end

  def prepare(query, _opts, _context), do: Ash.Query.filter(query, false)
end
