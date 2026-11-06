# Publishes the mobile-visits model as a ModelVersion and binds it, and seeds a
# synthetic map for it in the clinic's dev database: the clinic, three farms and one
# version of the "clinic_van" travel matrix between them. Synthetic data only: the
# model, its checker, the places and the driving times describe no real clinic or road.
#
#     mix run priv/planning/seed_mobile_visits.exs
#
# Idempotent. Prerequisite: `mix seed` (it publishes the four-eyes process through
# `ClinicDemo.Rules.install!/0`, which the approval of a mobile plan runs on).

alias ClinicDemo.Planning.Install
alias ClinicDemo.Planning.Models.MobileVisits
alias ClinicDemo.Scheduling

%{model_version: model_version, binding: binding} = Install.install!(MobileVisits)

IO.puts("""
Planning model:
  #{model_version.key} v#{model_version.version} (#{model_version.status})
    model   #{model_version.model_sha256}
    checker #{model_version.checker_sha256}
  bound as #{binding.selector}
""")

actor = %{id: "00000000-0000-0000-0000-0000000000aa", role: :veterinarian}

existing = Scheduling.list_service_locations!(actor: actor) |> Map.new(&{&1.name, &1})

# {name, kind, address, latitude, longitude, gate/stairs buffer in minutes}
places = [
  {"Synthetic Clinic", :clinic, "1 Test Street", "45.0000", "-75.0000", 0},
  {"Farm A", :client_site, "10 Synthetic Lane", "45.0500", "-75.0500", 0},
  {"Farm B", :client_site, "20 Synthetic Lane", "45.1000", "-75.1000", 5},
  {"Farm C", :client_site, "30 Synthetic Lane", "45.1500", "-75.1500", 0}
]

locations =
  for {name, kind, address, latitude, longitude, buffer} <- places, into: %{} do
    location =
      Map.get(existing, name) ||
        Scheduling.register_service_location!(
          %{
            name: name,
            kind: kind,
            address_line: address,
            city: "Testville",
            latitude: latitude,
            longitude: longitude,
            access_buffer_minutes: buffer,
            access_constraints: if(buffer > 0, do: [:gated_entry], else: [])
          },
          actor: actor
        )

    {name, location}
  end

has_matrix? =
  Scheduling.list_travel_matrices!(actor: actor) |> Enum.any?(&(&1.key == "clinic_van"))

unless has_matrix? do
  # Minutes of driving, the same each way.
  minutes = [
    {"Synthetic Clinic", "Farm A", 20},
    {"Synthetic Clinic", "Farm B", 30},
    {"Synthetic Clinic", "Farm C", 45},
    {"Farm A", "Farm B", 25},
    {"Farm A", "Farm C", 35},
    {"Farm B", "Farm C", 15}
  ]

  entries =
    for {from, to, duration} <- minutes, {origin, destination} <- [{from, to}, {to, from}] do
      %{
        origin_id: locations[origin].id,
        destination_id: locations[destination].id,
        reachable: true,
        duration_minutes: duration,
        distance_m: duration * 800
      }
    end

  matrix =
    Scheduling.publish_travel_matrix!(
      %{
        key: "clinic_van",
        provider: "synthetic",
        collected_at: DateTime.utc_now() |> DateTime.truncate(:second),
        entries: entries
      },
      actor: actor
    )

  IO.puts("  travel matrix clinic_van v#{matrix.version} #{matrix.content_hash}")
end

IO.puts("  #{map_size(locations)} places (the clinic and three farms)")
