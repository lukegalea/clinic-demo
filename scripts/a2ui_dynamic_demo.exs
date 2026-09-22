# The agent-composed-surface workflow, executable: this is the loop an agent
# runs against `AshA2ui.Dynamic`, and it is the exact loop that produced
# `ClinicDemoWeb.A2ui.EmergencyBoardUI` (see that module's provenance).
#
# 1. The host declares what an agent may touch — the allowlist is host
#    configuration, never client input.
# 2. The agent grounds itself in what exists: describe_resources (fields,
#    actions, calculations) and spec_schema (the spec's own grammar).
# 3. The agent emits a spec — a declarative mirror of the DSL vocabulary,
#    never raw A2UI — and resolves it. Verifier errors come back structured
#    (path + message); the agent self-corrects and re-resolves.
# 4. Long-lived surfaces are promoted to checked-in code via to_dsl_source,
#    which re-resolves the spec as a promotion check.
#
#     mix run scripts/a2ui_dynamic_demo.exs

# 1. Host configuration: which resources an agent-composed surface may touch.
allowlist =
  AshA2ui.Dynamic.allowlist([
    ClinicDemo.Scheduling.Appointment,
    ClinicDemo.Scheduling.Patient,
    ClinicDemo.Visits.HumanTask,
    ClinicDemo.Visits.Instance
  ])

# 2. Grounding. `describe_resources/1` is what the agent reads instead of
# guessing at the domain.
described = AshA2ui.Dynamic.describe_resources(allowlist) |> List.wrap()
IO.puts("allowlist: #{map_size(allowlist)} resources, #{length(described)} described")

# 3. The agent's first attempt — with two real mistakes left in on purpose:
#    `"type"` is not the component key (it is `"kind"`), and the booking
#    reason is not called `chief_complaint`.
spec_v1 = %{
  "resource" => "Appointment",
  "title" => "Emergency board",
  "components" => [
    %{
      "type" => "table",
      "fields" => ["patient_label", "scheduled_at", "triage_urgency", "status", "chief_complaint"]
    }
  ]
}

show = fn
  {:ok, surface} -> {:ok, surface}
  {:error, errors} ->
    Enum.each(AshA2ui.Dynamic.Error.messages(errors), fn message ->
      IO.puts("  verifier: #{inspect(message)}")
    end)

    :error
end

IO.puts("\nresolve v1 (shape mistake):")
v1 = show.(AshA2ui.Dynamic.resolve(spec_v1, allowlist: allowlist))

# The correction REPLACES the key — adding "kind" while leaving "type" would
# trip the unknown-key verifier on the next round.
spec_v2 =
  spec_v1
  |> put_in(["components", Access.at(0), "kind"], "table")
  |> update_in(["components", Access.at(0)], &Map.delete(&1, "type"))

IO.puts("resolve v2 (unknown field):")
v2 = show.(AshA2ui.Dynamic.resolve(spec_v2, allowlist: allowlist))

spec_v3 =
  put_in(
    spec_v2,
    ["components", Access.at(0), "fields"],
    ["patient_label", "scheduled_at", "triage_urgency", "status", "reason"]
  )

IO.puts("resolve v3 (corrected):")
case show.(AshA2ui.Dynamic.resolve(spec_v3, allowlist: allowlist)) do
  {:ok, surface} ->
    IO.puts("  resolved — surface_id #{surface.surface_id}")

    # 4. Promotion: re-resolves the spec as a check, then emits checked-in
    # DSL source with provenance.
    case AshA2ui.Dynamic.to_dsl_source(surface,
           module: ClinicDemoWeb.A2ui.EmergencyBoardUI,
           allowlist: allowlist,
           spec_version: "1.0"
         ) do
      {:ok, source} ->
        IO.puts("  promotion source ready (#{length(String.split(source, "\n"))} lines)")

      error ->
        IO.puts("  to_dsl_source: #{inspect(error, pretty: true, limit: 20)}")
    end

  :error ->
    IO.puts("  unresolved; not promoting")
end
