defmodule ClinicDemo.MobileFixtures do
  @moduledoc """
  Synthetic fixtures for the mobile-visits tests: a clinic and three client sites on
  an invented map, a travel matrix between them, mobile-capable visit types, visit
  requests and scripted backend answers.

  Nothing here is real: addresses, coordinates, names and durations are made up.
  The default map (minutes of driving, the same each way):

      clinic - farm A 20      clinic - farm B 30      clinic - farm C 45
      farm A - farm B 25      farm A - farm C 35      farm B - farm C 15
  """

  import ClinicDemo.PlanningFixtures, only: [staff: 0]

  alias ClinicDemo.Scheduling

  @doc """
  Registers the clinic and farms A, B and C. Returns `%{clinic:, a:, b:, c:}`
  (`ServiceLocation`s). Farm B has a gate (`access_buffer_minutes: 5`).
  """
  def places! do
    %{
      clinic: place!("Synthetic Clinic", :clinic, "1 Test Street", "45.0000", "-75.0000", 0),
      a: place!("Farm A", :client_site, "10 Synthetic Lane", "45.0500", "-75.0500", 0),
      b: place!("Farm B", :client_site, "20 Synthetic Lane", "45.1000", "-75.1000", 5),
      c: place!("Farm C", :client_site, "30 Synthetic Lane", "45.1500", "-75.1500", 0)
    }
  end

  defp place!(name, kind, address, lat, lon, buffer) do
    Scheduling.register_service_location!(
      %{
        name: name,
        kind: kind,
        address_line: address,
        city: "Testville",
        latitude: lat,
        longitude: lon,
        access_buffer_minutes: buffer,
        access_constraints: if(buffer > 0, do: [:gated_entry], else: [])
      },
      actor: staff()
    )
  end

  @default_minutes %{
    {:clinic, :a} => 20,
    {:clinic, :b} => 30,
    {:clinic, :c} => 45,
    {:a, :b} => 25,
    {:a, :c} => 35,
    {:b, :c} => 15
  }

  @doc """
  Publishes a version of matrix `key` over `places` (the map from `places!/0`).
  `overrides` replaces durations: `%{{:clinic, :a} => 25}` (both directions) or marks
  a pair unreachable (`%{{:a, :c} => :unreachable}`) or drops it (`:missing`).
  Returns the published `TravelMatrix`.
  """
  def publish_matrix!(places, key \\ "clinic_van", overrides \\ %{}) do
    entries =
      for {{from, to}, minutes} <- Map.merge(@default_minutes, overrides),
          {origin, destination} <- [{from, to}, {to, from}],
          minutes != :missing do
        entry(places[origin].id, places[destination].id, minutes)
      end

    Scheduling.publish_travel_matrix!(
      %{
        key: key,
        provider: "synthetic",
        collected_at: ~U[2026-11-01 12:00:00Z],
        entries: entries
      },
      actor: staff()
    )
  end

  defp entry(origin_id, destination_id, :unreachable),
    do: %{origin_id: origin_id, destination_id: destination_id, reachable: false}

  defp entry(origin_id, destination_id, minutes) do
    %{
      origin_id: origin_id,
      destination_id: destination_id,
      reachable: true,
      duration_minutes: minutes,
      distance_m: minutes * 800
    }
  end

  @doc "A mobile-capable catalogue entry (the visits' type). `equipment` is what it needs."
  def mobile_type!(name, equipment \\ []) do
    case Enum.find(Scheduling.list_appointment_types!(), &(&1.name == name)) do
      nil ->
        Ash.create!(
          ClinicDemo.Scheduling.AppointmentType,
          %{
            name: name,
            base_price: "50",
            default_duration_minutes: 30,
            mobile_capable: true,
            mobile_equipment: equipment
          },
          authorize?: false
        )

      type ->
        type
    end
  end

  @doc "Hires a veterinarian who carries `kit` on mobile visits."
  def mobile_vet!(name \\ "Dr. Mobi Moore", kit \\ []) do
    Scheduling.hire_clinician!(
      %{
        full_name: name,
        role: :veterinarian,
        license_number: "ON-#{:rand.uniform(899_999) + 100_000}",
        mobile_kit: kit
      },
      actor: staff()
    )
  end

  @doc """
  Asks for a mobile visit on `day` between `from` and `to` (`{hour, minute}`), at
  `place`, for a fresh patient. Options: `:type` (a mobile-capable type, default
  "Wellness exam"), `:minutes` (booked length, default 30).
  """
  def request_visit!(day, {from_h, from_m}, {to_h, to_m}, place, opts \\ []) do
    patient =
      Scheduling.register_patient!(
        %{
          name: "Patient #{System.unique_integer([:positive])}",
          species: :dog,
          owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
        },
        actor: staff()
      )

    type = opts[:type] || mobile_type!("Wellness exam")

    Scheduling.request_visit!(
      %{
        patient_id: patient.id,
        appointment_type_id: type.id,
        service_location_id: place.id,
        earliest_start_at: DateTime.new!(day, Time.new!(from_h, from_m, 0), "Etc/UTC"),
        latest_end_at: DateTime.new!(day, Time.new!(to_h, to_m, 0), "Etc/UTC"),
        duration_minutes: Keyword.get(opts, :minutes, 30),
        reason: Keyword.get(opts, :reason, "Synthetic farm call")
      },
      actor: staff()
    )
  end

  @doc "Books an in-clinic appointment for `vet` on `day` at `{hour, minute}`."
  def in_clinic!(day, {hour, minute}, vet, opts \\ []) do
    ClinicDemo.PlanningFixtures.book!(
      Date.beginning_of_week(day),
      Date.day_of_week(day),
      {hour, minute},
      vet,
      opts
    )
  end

  @doc """
  A scripted Fake-backend answer in the model's output shape (`st`, `succ`, `tin`):
  `starts` maps a visit request id to its start (`{hour, minute}`). Commitments sit
  where the payload says; `succ` and `tin` are derived from the time order and the
  payload's own travel numbers, so a scripted answer is exactly what the real model
  would say for these starts.
  """
  def fake_answer(payload, starts) do
    data = payload["data"]
    ids = payload["ids"]
    n_visit = length(ids["visits"])
    n_commit = length(ids["commitments"])
    start_node = n_visit + n_commit + 1
    end_node = n_visit + n_commit + 2
    n_loc = data["n_loc"]

    visit_starts =
      for id <- ids["visits"] do
        {h, m} = Map.fetch!(starts, id)
        h * 60 + m
      end

    commit_starts = Enum.take(data["c_from"], n_commit)
    node_start = visit_starts ++ commit_starts ++ [data["work_from"]]

    node_end =
      Enum.zip(0..(n_visit - 1)//1, visit_starts)
      |> Enum.map(fn {i, s} -> s + Enum.at(data["v_dur"], i) end)
      |> Kernel.++(
        Enum.zip(0..(n_commit - 1)//1, commit_starts)
        |> Enum.map(fn {j, _s} -> Enum.at(data["c_to"], j) end)
      )
      |> Kernel.++([data["work_from"]])

    node_loc =
      Enum.take(data["v_loc"], n_visit) ++
        Enum.take(data["c_loc"], n_commit) ++ [data["start_loc"]]

    ordered =
      Enum.to_list(1..(n_visit + n_commit)//1)
      |> Enum.sort_by(&Enum.at(node_start, &1 - 1))

    chain = [start_node | ordered] ++ [end_node]

    leg = fn from, to ->
      from_loc = if from == start_node, do: data["start_loc"], else: Enum.at(node_loc, from - 1)
      to_loc = if to == end_node, do: data["end_loc"], else: Enum.at(node_loc, to - 1)
      Enum.at(data["tt"], (from_loc - 1) * n_loc + to_loc - 1)
    end

    finish =
      case List.last(ordered) do
        nil -> data["work_from"] + leg.(start_node, end_node)
        last -> Enum.at(node_end, last - 1) + leg.(last, end_node)
      end

    succ =
      for node <- 1..end_node do
        cond do
          node == end_node -> start_node
          true -> Enum.at(chain, Enum.find_index(chain, &(&1 == node)) + 1)
        end
      end

    tin =
      for node <- 1..end_node do
        case Enum.find_index(chain, &(&1 == node)) do
          0 -> 0
          index -> leg.(Enum.at(chain, index - 1), node)
        end
      end

    st = Enum.take(node_start, n_visit + n_commit) ++ [data["work_from"], finish]
    %{"st" => st, "succ" => succ, "tin" => tin}
  end

  @doc """
  Plans `day` for `vet` through the Fake backend with scripted visit starts (a map from
  visit request id to `{hour, minute}`) or a function from the decoded payload to one.
  Options: `:fake` (merged into the scripted backend's data: `fake_outcome`, ...); every
  other option goes to `MobileVisits.plan/1`.
  """
  def plan_fake(day, vet, actor, starts, opts \\ []) do
    {fake, opts} = Keyword.pop(opts, :fake, %{})

    ClinicDemo.Planning.MobileVisits.plan(
      [
        day: day,
        clinician_id: vet.id,
        actor: actor,
        backend: AshPlanning.Backend.Fake,
        backend_data: fn payload ->
          if Map.get(fake, :fake_outcome) in [:infeasible, :unknown] do
            fake
          else
            starts = if is_function(starts, 1), do: starts.(payload), else: starts
            Map.merge(%{fake_candidates: [fake_answer(payload, starts)]}, fake)
          end
        end
      ] ++ opts
    )
  end
end
