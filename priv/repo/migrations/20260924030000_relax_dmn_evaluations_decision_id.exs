defmodule ClinicDemo.Repo.Migrations.RelaxDmnEvaluationsDecisionId do
  @moduledoc """
  CLIN-7 follow-up: `decision_id` on `dmn_evaluations` relaxes to nullable.

  The host migration declared it `null: false`, but ash_decisions' Evaluation
  resource declares it "nullable on purpose": a failed evaluation is exactly
  the row an auditor most needs, and some failures (an ambiguous document, a
  document with no decision at all) happen before any decision could be
  resolved — there is no decision id to record. The stricter column turned
  every such evidence row into a refused write.

  The down path restores the old posture (safe only while every row carries
  a decision id, which the resource now declines to guarantee).
  """

  use Ecto.Migration

  def up do
    alter table(:dmn_evaluations) do
      modify :decision_id, :text, null: true, from: :text
    end
  end

  def down do
    alter table(:dmn_evaluations) do
      modify :decision_id, :text, null: false, from: :text
    end
  end
end
