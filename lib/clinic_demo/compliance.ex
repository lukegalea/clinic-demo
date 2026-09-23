defmodule ClinicDemo.Compliance do
  @moduledoc """
  The compliance control plane's home in this app.

  This demo has no organizations, so every compliance row belongs to the one
  fixed org below. `activate_appointment_bundle!/1` is the whole seeding
  lifecycle — draft, validate, approve, activate the rule-set revision, then
  compile and activate the policy bundle — shared by the seeds and the test
  suite so there is exactly one spelling of "put the appointment rules in
  force".
  """

  alias ClinicDemo.Compliance.AppointmentRules

  @org "11111111-1111-1111-1111-111111111111"

  def organization_id, do: @org

  # The arity-1 spelling the compliance editor's MFA contract calls
  # (`module.function(args ++ [socket])`): same fixed org, socket ignored.
  def organization_id(_socket), do: @org

  @doc """
  Puts the appointment rule bundle in force for the demo org.

  Idempotent: an active policy bundle short-circuits the lifecycle, so
  reseeding never trips the `[organization_id, content_hash]` identity on
  policy bundles or re-drafts a revision that already exists. Returns the
  active bundle.
  """
  def activate_appointment_bundle!(label \\ "seeded") do
    case AshCompliance.Domain.active_policy_bundle(@org, authorize?: false) do
      {:ok, %AshCompliance.Resources.PolicyBundle{} = bundle} ->
        bundle

      {:ok, nil} ->
        activate!(label)
    end
  end

  defp activate!(label) do
    ir_bundle = AppointmentRules.__bundle__()

    AshCompliance.Domain.draft_rule_set_revision!(
      %{
        organization_id: @org,
        name: "clinic_appointment_rules",
        layer: :global_mandatory,
        combining: :deny_overrides,
        source_module: inspect(AppointmentRules),
        rules_json: AshRules.Ir.encode!(ir_bundle),
        content_hash: ir_bundle.content_hash
      },
      authorize?: false
    )
    |> AshCompliance.Domain.validate_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.approve_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.activate_rule_set_revision!(authorize?: false)

    AshCompliance.Domain.compile_policy_bundle!(
      %{organization_id: @org, label: label},
      authorize?: false
    )
    |> AshCompliance.Domain.activate_policy_bundle!(authorize?: false)
  end
end
