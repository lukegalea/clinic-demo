# Publishes the weekly roster model as a ModelVersion and binds it, in the clinic's
# dev database. Synthetic data only: the model, its checker and the shift templates
# below describe no real clinic.
#
#     mix run priv/planning/seed_weekly_roster.exs
#
# Idempotent. Prerequisite: `mix seed` (it publishes the `staffing.policy`
# decision and the four-eyes process through `ClinicDemo.Rules.install!/0`).

alias ClinicDemo.Planning.Install
alias ClinicDemo.Scheduling

%{model_version: model_version, binding: binding} = Install.install!()

IO.puts("""
Planning model:
  #{model_version.key} v#{model_version.version} (#{model_version.status})
    model   #{model_version.model_sha256}
    checker #{model_version.checker_sha256}
  bound as #{binding.selector}
""")

# The shift patterns the staffing policy names ("early", "late", "weekend"), one
# per role. Minutes after UTC midnight; half-open.
actor = %{id: "00000000-0000-0000-0000-0000000000aa", role: :veterinarian}

existing =
  Scheduling.list_shift_templates!(actor: actor)
  |> MapSet.new(&{&1.name, &1.role})

patterns = [
  {"early", 8 * 60, 16 * 60, [1, 2, 3, 4, 5]},
  {"late", 10 * 60, 18 * 60, [1, 2, 3, 4, 5]},
  {"weekend", 9 * 60, 13 * 60, [6]}
]

for role <- [:veterinarian, :technician, :nurse],
    {name, from, to, days} <- patterns,
    not MapSet.member?(existing, {name, role}) do
  Scheduling.define_shift_template!(
    %{name: name, role: role, start_offset_minutes: from, end_offset_minutes: to, allowed_days: days},
    actor: actor
  )

  IO.puts("  shift template #{name} (#{role})")
end
