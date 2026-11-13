defmodule ClinicDemo.Scheduling.MobileResourcesTest do
  @moduledoc """
  The data the mobile-visits plan stands on: service locations, the versioned
  travel matrix artifact, visit requests and the appointment's location mode.
  """

  use ClinicDemo.DataCase, async: false

  import ClinicDemo.MobileFixtures
  import ClinicDemo.PlanningFixtures, only: [staff: 0, next_monday: 0]

  alias Ash.Resource.Info
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.{TravelMatrix, VisitRequest}

  describe "TravelMatrix" do
    test "a published version carries its entries in canonical order and a content hash" do
      places = places!()
      v1 = publish_matrix!(places)

      assert v1.version == 1
      assert v1.mode == :driving
      assert v1.content_hash =~ ~r/^[0-9a-f]{64}$/
      assert length(v1.entries) == 12
      assert v1.entries == TravelMatrix.sort_entries(v1.entries)
      assert TravelMatrix.content_hash(Map.from_struct(v1)) == v1.content_hash
    end

    test "a changed matrix is a new version with a different hash; the old one is untouched" do
      places = places!()
      v1 = publish_matrix!(places)
      v2 = publish_matrix!(places, "clinic_van", %{{:clinic, :a} => 25})

      assert v2.version == 2
      refute v2.content_hash == v1.content_hash

      assert [v1.id, v2.id] ==
               Scheduling.list_travel_matrices!()
               |> Enum.sort_by(& &1.version)
               |> Enum.map(& &1.id)

      assert Enum.find(Scheduling.list_travel_matrices!(), &(&1.id == v1.id)).content_hash ==
               v1.content_hash
    end

    test "versions are per key" do
      places = places!()
      publish_matrix!(places, "clinic_van")
      assert publish_matrix!(places, "bike_courier").version == 1
    end

    test "an unreachable pair is stored with no duration; the same pair as zero is refused" do
      places = places!()
      matrix = publish_matrix!(places, "clinic_van", %{{:a, :c} => :unreachable})

      pair =
        Enum.find(
          matrix.entries,
          &(&1["origin_id"] == places.a.id and &1["destination_id"] == places.c.id)
        )

      assert pair == %{
               "origin_id" => places.a.id,
               "destination_id" => places.c.id,
               "reachable" => false
             }

      assert {:error, error} =
               Scheduling.publish_travel_matrix(
                 %{
                   key: "bad",
                   provider: "synthetic",
                   collected_at: ~U[2026-11-01 12:00:00Z],
                   entries: [
                     %{
                       origin_id: places.a.id,
                       destination_id: places.c.id,
                       reachable: false,
                       duration_minutes: 0
                     }
                   ]
                 },
                 actor: staff()
               )

      assert Exception.message(error) =~ "never zero-cost"
    end

    test "malformed pairs are refused: self pairs, duplicates, missing durations" do
      places = places!()
      base = %{key: "bad", provider: "synthetic", collected_at: ~U[2026-11-01 12:00:00Z]}
      a = places.a.id
      b = places.b.id

      for {entries, fragment} <- [
            {[%{origin_id: a, destination_id: a, reachable: true, duration_minutes: 0}],
             "to itself"},
            {[
               %{origin_id: a, destination_id: b, reachable: true, duration_minutes: 5},
               %{origin_id: a, destination_id: b, reachable: true, duration_minutes: 6}
             ], "more than once"},
            {[%{origin_id: a, destination_id: b, reachable: true}], "duration_minutes"},
            {[%{origin_id: "nope", destination_id: b, reachable: true, duration_minutes: 1}],
             "UUIDs"}
          ] do
        assert {:error, error} =
                 Scheduling.publish_travel_matrix(Map.put(base, :entries, entries),
                   actor: staff()
                 )

        assert Exception.message(error) =~ fragment
      end
    end

    test "there is no way to edit or delete a published version" do
      actions =
        TravelMatrix |> Info.actions() |> Enum.map(& &1.name)

      assert Enum.sort(actions) == [:publish, :read]
    end
  end

  describe "VisitRequest" do
    test "a request names a window inside one day, a place and a type" do
      places = places!()
      request = request_visit!(next_monday(), {10, 0}, {12, 0}, places.a)

      assert request.state == :requested
      assert request.service_location_id == places.a.id
      assert request.appointment_id == nil
    end

    test "a window shorter than the visit, or crossing midnight, is refused" do
      places = places!()
      day = next_monday()

      assert_raise Ash.Error.Invalid, ~r/shorter than the visit/, fn ->
        request_visit!(day, {10, 0}, {10, 20}, places.a, minutes: 30)
      end

      patient =
        Scheduling.register_patient!(
          %{name: "Rex", species: :dog, owner_email: "owner@example.com"},
          actor: staff()
        )

      assert_raise Ash.Error.Invalid, ~r/must not cross midnight/, fn ->
        Scheduling.request_visit!(
          %{
            patient_id: patient.id,
            appointment_type_id: mobile_type!("Wellness exam").id,
            service_location_id: places.a.id,
            earliest_start_at: DateTime.new!(day, ~T[23:00:00], "Etc/UTC"),
            latest_end_at: DateTime.new!(Date.add(day, 1), ~T[00:30:00], "Etc/UTC"),
            duration_minutes: 30,
            reason: "Synthetic farm call"
          },
          actor: staff()
        )
      end
    end

    test "a request cannot be marked scheduled by hand: only applying a plan may" do
      places = places!()
      request = request_visit!(next_monday(), {10, 0}, {12, 0}, places.a)

      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.schedule_visit_request(request, Ecto.UUID.generate(), actor: staff())

      assert Scheduling.get_visit_request!(request.id).state == :requested
    end

    test "cancelling an open request ends it cancelled" do
      places = places!()
      request = request_visit!(next_monday(), {10, 0}, {12, 0}, places.a)

      cancelled = Scheduling.cancel_visit_request!(request, "owner called it off", actor: staff())
      assert cancelled.state == :cancelled
      assert cancelled.cancellation_reason == "owner called it off"

      assert {:error, _} = Scheduling.cancel_visit_request(cancelled, "again", actor: staff())
    end

    test "the schedule is temporal: a cancelled request is still readable as of before it" do
      places = places!()
      request = request_visit!(next_monday(), {10, 0}, {12, 0}, places.a)
      before = DateTime.utc_now()
      Process.sleep(20)
      Scheduling.cancel_visit_request!(request, "owner called it off", actor: staff())

      assert [%VisitRequest{state: :requested}] =
               VisitRequest
               |> Ash.Query.for_read(:read, %{})
               |> Ash.Query.as_of(before)
               |> Ash.read!(actor: staff())
    end
  end

  describe "Appointment location mode" do
    setup do
      vet = mobile_vet!()
      %{vet: vet, places: places!()}
    end

    defp book(vet, params) do
      patient = hd(Scheduling.list_patients!()) |> Map.fetch!(:id)

      Scheduling.book_appointment(
        Map.merge(
          %{
            patient_id: patient,
            clinician_id: vet.id,
            scheduled_at: DateTime.new!(next_monday(), ~T[10:00:00], "Etc/UTC"),
            duration_minutes: 30,
            reason: "Synthetic checkup"
          },
          params
        ),
        actor: staff()
      )
    end

    setup do
      Scheduling.register_patient!(
        %{name: "Rex", species: :dog, owner_email: "owner@example.com"},
        actor: staff()
      )

      :ok
    end

    test "defaults to in-clinic, with no place", %{vet: vet} do
      assert {:ok, appointment} = book(vet, %{})
      assert appointment.location_mode == :in_clinic
      assert appointment.service_location_id == nil
    end

    test "a mobile visit needs a place; the other modes refuse one", %{vet: vet, places: places} do
      assert {:ok, mobile} =
               book(vet, %{location_mode: :mobile, service_location_id: places.a.id})

      assert mobile.location_mode == :mobile
      assert mobile.service_location_id == places.a.id

      assert {:error, missing} = book(vet, %{location_mode: :mobile})
      assert Exception.message(missing) =~ "needs a service location"

      assert {:error, extra} =
               book(vet, %{location_mode: :telehealth, service_location_id: places.a.id})

      assert Exception.message(extra) =~ "only a mobile visit has a service location"

      assert {:ok, %{location_mode: :telehealth}} = book(vet, %{location_mode: :telehealth})
    end
  end

  describe "mobile equipment" do
    test "a clinician's kit and a type's equipment are plain lists, empty by default" do
      vet = mobile_vet!("Dr. Kit Kent", ["vaccine_cooler"])
      assert vet.mobile_kit == ["vaccine_cooler"]
      assert mobile_vet!().mobile_kit == []

      type = mobile_type!("Farm vaccination", ["vaccine_cooler"])
      assert type.mobile_capable
      assert type.mobile_equipment == ["vaccine_cooler"]

      plain =
        Ash.create!(
          ClinicDemo.Scheduling.AppointmentType,
          %{name: "Dental clean", base_price: "90"},
          authorize?: false
        )

      refute plain.mobile_capable
      assert plain.mobile_equipment == []
    end
  end
end
