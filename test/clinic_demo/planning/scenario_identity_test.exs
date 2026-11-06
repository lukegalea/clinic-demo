defmodule ClinicDemo.Planning.ScenarioIdentityTest do
  @moduledoc """
  The planning evaluation identity on `BusinessEvents.Scenarios.generate!/1`.

  A scenario that evaluates a planning candidate is identified by the five-tuple
  `(candidate_id, snapshot_digest, model_hash, random_stream_id, replication_id)`;
  the label is presentation only. These tests pin, in the pure draw and end to end:

    * the seed is `(visit_id, identity-tuple)` when the planning fields are present:
      the same five draw identically whatever the label, any one differing draws
      independently;
    * with no planning field the seed is `(visit_id, label)` exactly as before (the
      existing scenario suite holds that pin; here it is restated against the
      identity-aware entry point);
    * the five go together; a partial identity raises;
    * the identity rides each twin event's structural context, simulated events
      stay in the simulation twin, and the real ledger gains nothing.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.Scenarios
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  @identity %{
    candidate_id: "00000000-0000-0000-0000-00000000c001",
    snapshot_digest: String.duplicate("a", 64),
    model_hash: String.duplicate("b", 64),
    random_stream_id: "stream-1",
    replication_id: 0
  }

  defp visit_ids,
    do: Enum.map(1..40, &"00000000-0000-0000-0000-#{String.pad_leading(to_string(&1), 12, "0")}")

  defp next_week,
    do: DateTime.utc_now() |> DateTime.add(7 * 86_400, :second) |> DateTime.truncate(:second)

  defp visits do
    at = next_week()

    Enum.map(visit_ids(), fn id ->
      %{
        id: id,
        appointment_type_id: nil,
        clinician_id: nil,
        scheduled_at: at,
        amount: Decimal.new("100"),
        duration_minutes: 30
      }
    end)
  end

  defp rates,
    do: %{
      cell: %{},
      type_weekday: %{},
      type: %{},
      weekday: %{},
      global: %{completed: 5, cancelled: 3, no_show: 2}
    }

  defp kinds(planned), do: Enum.map(planned, &{&1.appointment_id, &1.kind})

  describe "the pure draw with a planning identity" do
    test "the same five draw the identical multiset, whatever the label is called" do
      one = Scenarios.plan(visits(), "label-one", rates(), Decimal.new("0.5"), @identity)
      two = Scenarios.plan(visits(), "label-two", rates(), Decimal.new("0.5"), @identity)

      assert kinds(one) == kinds(two)
      assert Enum.all?(one, &(&1.identity == @identity))
    end

    test "any one of the five differing draws independently" do
      base = Scenarios.plan(visits(), "same-label", rates(), Decimal.new("0.5"), @identity)

      for change <- [
            %{candidate_id: "00000000-0000-0000-0000-00000000c002"},
            %{snapshot_digest: String.duplicate("c", 64)},
            %{model_hash: String.duplicate("d", 64)},
            %{random_stream_id: "stream-2"},
            %{replication_id: 1}
          ] do
        other =
          Scenarios.plan(
            visits(),
            "same-label",
            rates(),
            Decimal.new("0.5"),
            Map.merge(@identity, change)
          )

        refute kinds(base) == kinds(other),
               "changing #{inspect(Map.keys(change))} must change the draw"
      end
    end

    test "with no identity the seed is (visit_id, label), unchanged" do
      by_label = Scenarios.plan(visits(), "label-one", rates(), Decimal.new("0.5"))
      same_label = Scenarios.plan(visits(), "label-one", rates(), Decimal.new("0.5"), nil)
      other_label = Scenarios.plan(visits(), "label-two", rates(), Decimal.new("0.5"))

      assert kinds(by_label) == kinds(same_label)
      refute kinds(by_label) == kinds(other_label)
      assert Enum.all?(by_label, &is_nil(&1.identity))
    end

    test "an identity draw is not the label draw: the label no longer seeds it" do
      with_identity =
        Scenarios.plan(visits(), "label-one", rates(), Decimal.new("0.5"), @identity)

      by_label = Scenarios.plan(visits(), "label-one", rates(), Decimal.new("0.5"))

      refute kinds(with_identity) == kinds(by_label)
    end

    test "raising the multiplier still only moves a visit toward completion" do
      low = Scenarios.plan(visits(), "m", rates(), Decimal.new("0.2"), @identity)
      high = Scenarios.plan(visits(), "m", rates(), Decimal.new("0.9"), @identity)

      completed = fn planned ->
        for %{kind: :visit_completed, appointment_id: id} <- planned, into: MapSet.new(), do: id
      end

      assert MapSet.subset?(completed.(low), completed.(high))
    end
  end

  describe "generate!/1 with a planning identity" do
    setup do
      BusinessEvents.install!()
      :ok
    end

    defp fixtures(count) do
      staff = %{id: "00000000-0000-0000-0000-0000000000d4", role: :veterinarian}

      vet =
        Scheduling.hire_clinician!(
          %{
            full_name: "Dr. Identity Vet",
            role: :veterinarian,
            license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
          },
          actor: staff
        )

      type =
        AppointmentType
        |> Ash.Changeset.for_create(:create, %{
          name: "Identity Visit #{System.unique_integer([:positive])}",
          base_price: Decimal.new("80"),
          default_duration_minutes: 30
        })
        |> Ash.create!(authorize?: false)

      for day <- 1..count do
        patient =
          Scheduling.register_patient!(
            %{
              name: "Identity Animal #{System.unique_integer([:positive])}",
              species: :dog,
              owner_email: "identity-#{System.unique_integer([:positive])}@example.com"
            },
            actor: staff
          )

        Scheduling.book_appointment!(
          %{
            patient_id: patient.id,
            clinician_id: vet.id,
            appointment_type_id: type.id,
            scheduled_at:
              DateTime.utc_now()
              |> DateTime.add(day * 86_400, :second)
              |> DateTime.truncate(:second),
            duration_minutes: 30,
            reason: "Identity bait"
          },
          actor: staff
        )
      end
    end

    defp identity_opts(overrides \\ %{}), do: @identity |> Map.merge(overrides) |> Map.to_list()

    test "the identity is the run's identity: returned, content-addressed into the label, recorded on every twin row" do
      fixtures(5)
      real_before = length(Ledger.by_region!(:clinic))

      result = Scenarios.generate!([multiplier: Decimal.new("99")] ++ identity_opts())

      assert result.identity == @identity
      assert result.generated == 5
      assert String.starts_with?(result.run, "scenario:plan-")

      rows =
        Ledger.SimulationEvent
        |> Ash.Query.filter(simulation_run == ^result.run)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 5

      for row <- rows do
        assert row.context["evaluation"] == %{
                 "candidate_id" => @identity.candidate_id,
                 "snapshot_digest" => @identity.snapshot_digest,
                 "model_hash" => @identity.model_hash,
                 "random_stream_id" => "stream-1",
                 "replication_id" => 0
               }
      end

      # Simulated events live only in the twin; the real ledger gained nothing.
      assert length(Ledger.by_region!(:clinic)) == real_before
    end

    test "two candidates are two runs with separate labels; regenerating one appends nothing" do
      fixtures(4)

      first = Scenarios.generate!([multiplier: Decimal.new("99")] ++ identity_opts())

      second =
        Scenarios.generate!(
          [multiplier: Decimal.new("99")] ++
            identity_opts(%{candidate_id: "00000000-0000-0000-0000-00000000c002"})
        )

      refute first.run == second.run

      again = Scenarios.generate!([multiplier: Decimal.new("99")] ++ identity_opts())
      assert again.run == first.run
      assert again.appended == 0
    end

    test "an explicit label is presentation: it names the run, the draw is the identity's" do
      fixtures(6)

      named =
        Scenarios.generate!(
          [multiplier: Decimal.new("0.5"), label: "scenario:friendly"] ++ identity_opts()
        )

      other =
        Scenarios.generate!(
          [multiplier: Decimal.new("0.5"), label: "scenario:other"] ++ identity_opts()
        )

      assert named.run == "scenario:friendly"
      assert other.run == "scenario:other"

      draw = fn run ->
        Ledger.SimulationEvent
        |> Ash.Query.filter(simulation_run == ^run)
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.subject_external_id, to_string(&1.action)})
      end

      assert draw.("scenario:friendly") == draw.("scenario:other")
    end

    test "a partial identity raises instead of seeding two evaluations alike" do
      assert_raise ArgumentError, ~r/missing/, fn ->
        Scenarios.generate!(
          candidate_id: @identity.candidate_id,
          snapshot_digest: @identity.snapshot_digest
        )
      end
    end

    test "an ill-typed identity raises" do
      assert_raise ArgumentError, ~r/replication_id/, fn ->
        Scenarios.generate!(identity_opts(%{replication_id: "zero"}))
      end

      for bad <- [
            %{model_hash: ""},
            %{model_hash: "abc"},
            %{snapshot_digest: String.duplicate("A", 64)},
            %{candidate_id: "not-a-uuid"},
            %{random_stream_id: ""},
            %{random_stream_id: "x" <> <<0>> <> "y"},
            %{replication_id: -1}
          ] do
        assert_raise ArgumentError, ~r/invalid/, fn ->
          Scenarios.generate!(identity_opts(bad))
        end
      end
    end

    test "distinct five-tuples cannot collide through the key's separator" do
      # Before validation, "x\0y" + "z" and "x" + "y\0z" joined to the same key.
      for stream <- ["x" <> <<0>> <> "y", "y" <> <<0>> <> "z"] do
        assert_raise ArgumentError, ~r/random_stream_id/, fn ->
          Scenarios.generate!(identity_opts(%{random_stream_id: stream}))
        end
      end
    end
  end
end
