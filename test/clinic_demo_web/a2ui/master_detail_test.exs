defmodule ClinicDemoWeb.A2ui.MasterDetailTest do
  @moduledoc """
  The a2ui reference features this app adopts, end to end against the real
  surfaces:

    * master/detail — the Patients and Clinicians tables pick a record into a
      context (`select_context`), and a related `:appointments` table reads
      that record's visits from `Appointment`, reading nothing until a pick;
    * deep links — `?ctx[patient]=<id>` arrives as that selection, through
      the same authorized read as a click; an unknown id is dropped;
    * reference links — the schedule's patient and clinician cells carry
      `_links` to the Patients and Clinicians surfaces, and opening one
      navigates there with the record selected.

  `async: false` because the LiveView surface bootstrap runs in a task that
  reads through the shared sandbox.
  """

  use ClinicDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshA2ui.{ActionHandler, Info}
  alias ClinicDemo.Scheduling
  alias ClinicDemoWeb.A2ui.{AppointmentUI, ClinicianUI, Links, PatientUI}

  # A UUID, because booking starts a visit process and the instance records
  # who started it in a uuid column.
  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  defp hire(name) do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: name,
          role: :veterinarian,
          license_number: "ON-#{System.unique_integer([:positive]) + 100_000}"
        },
        actor: @staff
      )

    vet
  end

  defp register(name) do
    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: name,
          species: :dog,
          owner_email: "md-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    patient
  end

  defp book(patient, vet, reason) do
    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          duration_minutes: 20,
          reason: reason,
          severity: 2
        },
        actor: @staff
      )

    appointment
  end

  # Two patients, two clinicians, crossed: each record's appointments table
  # must show exactly its own two visits.
  defp world do
    rex = register("Rex")
    tom = register("Tom")
    dr_a = hire("Dr. Ames")
    dr_b = hire("Dr. Burke")

    %{
      rex: rex,
      tom: tom,
      dr_a: dr_a,
      dr_b: dr_b,
      rex_a: book(rex, dr_a, "rex with ames"),
      rex_b: book(rex, dr_b, "rex with burke"),
      tom_a: book(tom, dr_a, "tom with ames")
    }
  end

  defp data_model(ui, opts) do
    %{"updateDataModel" => %{"path" => "/", "value" => value}} =
      Info.build_data_model(ui, [actor: @staff] ++ opts)

    value
  end

  defp appointment_reasons(%{"records" => %{"appointments" => rows}}),
    do: rows |> Enum.map(& &1["reason"]) |> Enum.sort()

  defp envelope(name, context) do
    %{
      "version" => "v0.9.1",
      "action" => %{"name" => name, "surfaceId" => "clinic_patients", "context" => context}
    }
  end

  defp value_at(messages, path) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => ^path, "value" => value}} -> {:ok, value}
      _other -> nil
    end)
    |> case do
      {:ok, value} -> value
      nil -> flunk("no updateDataModel at #{path} in #{inspect(messages, limit: 5)}")
    end
  end

  describe "Patients master/detail" do
    test "with no patient picked the appointments table reads nothing" do
      world()
      model = data_model(PatientUI, [])

      assert model["context"]["patient"]["value"] == ""
      assert model["records"]["appointments"] == []
      assert model["query"]["appointments"]["totalCount"] == 0
      assert model["records"]["patients"] != []
    end

    test "a picked patient scopes the appointments table to their visits" do
      %{rex: rex} = world()

      context_state = Info.context_state_for(PatientUI, %{"patient" => rex.id}, actor: @staff)
      model = data_model(PatientUI, context_state: context_state)

      assert model["context"]["patient"]["label"] == "Rex"
      assert appointment_reasons(model) == ["rex with ames", "rex with burke"]
    end

    test "the row select button round-trips through context_select" do
      %{tom: tom} = world()

      assert {:ok, messages} =
               ActionHandler.handle(
                 PatientUI,
                 envelope("context_select", %{"context" => "patient", "value" => tom.id}),
                 actor: @staff
               )

      assert value_at(messages, "/context")["patient"]["value"] == tom.id

      assert messages
             |> value_at("/records/appointments")
             |> Enum.map(& &1["reason"]) == ["tom with ames"]
    end

    test "the main table offers the select button; the related table offers no actions" do
      encoded = PatientUI |> Info.build_surface(actor: @staff) |> Jason.encode!()

      assert encoded =~ ~s("context_select")
      # Read-only by construction: the verifier refuses row actions on a
      # related table, so no lifecycle button rides along with the visits.
      refute encoded =~ ~s("check_in")
    end
  end

  test "Clinicians master/detail scopes the appointments table to the picked clinician" do
    %{dr_a: dr_a} = world()

    context_state = Info.context_state_for(ClinicianUI, %{"clinician" => dr_a.id}, actor: @staff)
    model = data_model(ClinicianUI, context_state: context_state)

    assert model["context"]["clinician"]["label"] == "Dr. Ames"
    assert appointment_reasons(model) == ["rex with ames", "tom with ames"]
  end

  describe "deep links" do
    test "?ctx[patient]=<id> opens the Patients surface with that patient picked",
         %{conn: conn} do
      %{rex: rex} = world()

      {:ok, view, _html} = live(conn, ~p"/patients?#{[ctx: [patient: rex.id]]}")
      render_async(view)

      assert_push_event(view, "a2ui:messages", %{messages: messages})
      encoded = Jason.encode!(messages)

      assert encoded =~ rex.id
      assert encoded =~ "rex with ames"
      refute encoded =~ "tom with ames"
    end

    test "an id that does not resolve is dropped: nothing picked, nothing read" do
      world()

      assert Info.context_state_for(PatientUI, %{"patient" => Ecto.UUID.generate()},
               actor: @staff
             )
             |> get_in(["patient", "value"])
             |> Kernel.in([nil, ""])
    end
  end

  describe "reference links" do
    test "schedule rows link the patient and clinician to their surfaces" do
      %{rex: rex, dr_b: dr_b, rex_b: rex_b} = world()

      row =
        AppointmentUI
        |> data_model([])
        |> Map.fetch!("records")
        |> Enum.find(&(&1["id"] == rex_b.id))

      assert %{"surface" => "patients", "recordId" => rex_id, "label" => "Rex"} =
               row["_links"]["patient_label"]

      assert rex_id == rex.id

      assert %{"surface" => "clinicians", "recordId" => dr_id, "label" => "Dr. Burke"} =
               row["_links"]["clinician_label"]

      assert dr_id == dr_b.id
    end

    test "opening a link navigates to that surface with the record picked", %{conn: conn} do
      %{rex: rex, dr_a: dr_a} = world()
      {:ok, view, _html} = live(conn, ~p"/schedule")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(view, "a2ui:open_surface", %{
                 "surface" => "patients",
                 "recordId" => rex.id
               })

      assert to == ~p"/patients?#{[ctx: [patient: rex.id]]}"

      assert Links.target_path("clinicians", dr_a.id) ==
               ~p"/clinicians?#{[ctx: [clinician: dr_a.id]]}"
    end

    test "a surface the app does not route is ignored" do
      assert Links.target_path("worklist", Ecto.UUID.generate()) == nil
      assert Links.surface_for({:resource, ClinicDemo.Visits.HumanTask}, %{}) == nil
    end
  end
end
