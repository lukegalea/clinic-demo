defmodule ClinicDemo.Planning.Model do
  @moduledoc """
  What a clinic planning model is to the planning runtime.

  `ClinicDemo.Planning` runs several models (the weekly staffing roster, the mobile
  visits route) through **one** loop: install and bind
  (`ClinicDemo.Planning.Install`), prepare a snapshot
  (`ClinicDemo.Planning.SnapshotBuilder`), solve (`SolveRunner`), check
  (`CheckPipeline`), sign off (`FourEyes`), apply (`Changes.ApplyCandidate`). Each
  model supplies what is its own; this behaviour is the whole list:

    * `definition/0` — the declaration: key, purpose, the reviewed artifacts and
      their hashes, the parameter decision (if any), capabilities and limits;
    * `scope/1` — what a plan is *about* (a week; a day and a clinician), as the
      structural stats a run records;
    * `build/4` — read the model's declared inputs as of the cutoff and lower them:
      the snapshot's inputs, the model data, the id maps and the domain-level
      problem the independent validator reads;
    * `decode/2`, `summarize/3`, `obligations/1`, `validate/2` — read a model answer
      back to domain-level assignments, summarise it for a reader, name what it
      leaves unresolved, and check it independently of the model;
    * `current_inputs/1` and `apply_plan/3` — the freshness recheck and the writes
      of `Candidate.apply`.

  The loop owns everything that must be the same for every model: the pinned
  definitions, the snapshot envelope and its digest, the honest outcome axes, the two
  independent verdicts, the four-eyes gate.
  """

  alias AshOpenLineage.Snapshot.{Definition, Input}

  @type built :: %{
          effective_at: DateTime.t(),
          inputs: [Input.t()],
          reasons: %{optional(String.t()) => String.t()},
          body: map(),
          stats: map()
        }

  @callback definition() :: map()
  @callback scope(keyword()) :: map()
  @callback build(struct(), keyword(), DateTime.t(), [Definition.t()]) ::
              {:ok, built()} | {:error, term()}
  @callback decode(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback summarize(map(), map(), map()) :: map()
  @callback obligations(map()) :: [map()]
  @callback validate(map(), map()) :: :ok | {:error, [AshPlanning.Violation.t()]}
  @callback current_inputs(map()) :: {:ok, [Input.t()]} | {:error, term()}
  @callback apply_plan(struct(), map(), map()) :: {:ok, map()} | {:error, term()}

  @models [ClinicDemo.Planning.Models.WeeklyRoster, ClinicDemo.Planning.Models.MobileVisits]

  @doc "Every model the clinic runs."
  @spec all() :: [module()]
  def all, do: @models

  @doc ~S[The model declared under `key` (`"weekly_roster"`, `"mobile_visits"`).]
  @spec for_key(String.t()) :: {:ok, module()} | :error
  def for_key(key) do
    case Enum.find(@models, &(&1.definition().key == key)) do
      nil -> :error
      model -> {:ok, model}
    end
  end

  @doc "Like `for_key/1`, raising for a key no model declares."
  @spec for_key!(String.t()) :: module()
  def for_key!(key) do
    case for_key(key) do
      {:ok, model} -> model
      :error -> raise ArgumentError, "no planning model is declared as #{inspect(key)}"
    end
  end

  @doc "The snapshot purposes the clinic's models seal, as atoms."
  @spec purposes() :: [atom()]
  def purposes, do: Enum.map(@models, & &1.definition().purpose_atom)
end
