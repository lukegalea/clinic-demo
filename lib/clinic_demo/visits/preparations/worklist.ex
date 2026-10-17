defmodule ClinicDemo.Visits.Preparations.Worklist do
  @moduledoc """
  Scopes `ClinicDemo.Visits.HumanTask`'s `:worklist` read to the actor: open
  tasks they are a candidate for and claimed tasks they hold, leaving out any
  task whose maker-checker exclusions name them. The same set as the
  engine's `:awaiting_actor` read, for the clinic's principals, which are
  all clinicians (`:user` rows).

  The worklist does not read through `:awaiting_actor` because that read
  narrows in a `before_action` hook, and `Ash.count/2` does not run
  `before_action` hooks. The board's lane counts and its pager total are
  `Ash.count/2` over the read, so through `:awaiting_actor` they counted
  every open or claimed task in the clinic, whoever was acting. A filter
  applied here narrows reads and counts alike.

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
      not fragment("? = ANY(?)", type(^actor_id, :uuid), excluded_principal_ids) and
        ((status == :open and
            exists(candidates, principal_type == :user and principal_id == ^actor_id)) or
           (status == :claimed and assignee_type == :user and assignee_id == ^actor_id))
    )
  end

  def prepare(query, _opts, _context), do: Ash.Query.filter(query, false)
end
