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

  @type page_status :: :compliant | :noncompliant | :no_rules | :unknown

  @doc """
  The compliance status of a page of appointments, in one pass over the rows.

  The status surfaces' batch entry point. The expensive steps — the active
  bundle read and its IR decode — run once per call; each row is then
  evaluated in memory through `AshCompliance.status_for/2` with the shared
  pre-decoded bundle (its `:bundle` option bypasses the per-row bundle read,
  which is what would make a naive per-row loop N+1). Facts come from
  `ClinicDemo.Compliance.AppointmentFacts`; records are expected to have
  `:patient` preloaded (the badge calculation declares the load).

  Options:

    * `:transition_to` — the transition the rules are asked about (default
      `:checked_in`, the gate a row badge answers for).

  Returns one value per appointment, in order:

    * `:compliant` — the active bundle permits (including "no rule applied";
      the guard's own settle/1 treats that as a pass);
    * `:noncompliant` — a rule fired against it;
    * `:no_rules` — the organization has no active bundle: absence is
      meaningful, and the badge says so instead of pretending compliance;
    * `:unknown` — the bundle could not be read, decoded or evaluated: the
      guard's fail-closed posture, reported rather than refused.
  """
  @spec appointment_status_page([ClinicDemo.Scheduling.Appointment.t()], keyword()) :: [
          page_status()
        ]
  def appointment_status_page(appointments, opts \\ []) do
    transition_to = Keyword.get(opts, :transition_to, :checked_in)

    case AshCompliance.Domain.active_policy_bundle(organization_id(), authorize?: false) do
      {:ok, nil} ->
        Enum.map(appointments, fn _appointment -> :no_rules end)

      {:ok, bundle} ->
        decode =
          case AshRules.Ir.decode(bundle.rules_json) do
            {:ok, ir} -> ir
            {:error, _reason} -> :error
          end

        Enum.map(appointments, fn appointment ->
          appointment
          |> AshCompliance.status_for(
            organization: {__MODULE__, :organization_id, []},
            fact_builder: ClinicDemo.Compliance.AppointmentFacts,
            bundle: decode,
            transition_to: transition_to
          )
          |> page_status()
        end)

      {:error, _reason} ->
        Enum.map(appointments, fn _appointment -> :unknown end)
    end
  end

  # The outcome lattice to badge vocabulary. :not_applicable maps to
  # :compliant because that is the system's own semantic — the guard's
  # settle/1 refuses only :noncompliant, :unknown and :error, so a bundle
  # with nothing to say about a row permits it.
  defp page_status({:ok, %{status: overall}}), do: overall_to_badge(overall)
  defp page_status({:error, :no_active_bundle}), do: :no_rules
  defp page_status({:error, _reason}), do: :unknown

  defp overall_to_badge(:noncompliant), do: :noncompliant
  defp overall_to_badge(:unknown), do: :unknown
  defp overall_to_badge(:error), do: :unknown
  defp overall_to_badge(_permitted), do: :compliant

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
