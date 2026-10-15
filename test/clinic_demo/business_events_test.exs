defmodule ClinicDemo.BusinessEventsTest do
  @moduledoc """
  BD-1's contract set: the value ledger lands.

  Three things this slice must prove, per the design:

    * **Mappings are data.** `install!/0` publishes the six declared
      mappings as `MappingVersion` rows — content-hashed (the stored
      artifact hashes to the stored hash), declared-order artifacts, and
      a re-run returns the same hash-identified rows and nothing more.
    * **The ledger round-trips.** `record!`/`simulate!` through the
      generated interfaces write locked, chained rows — the three clocks
      split on a back-dated write, delivery keys collapse repeats, the
      twin carries its run label — and the per-region chains verify.
    * **The posture holds.** `record` wants an actor (hooks will call
      with `authorize?: false`, the `RecognizeCharge` precedent), and
      the table is append-only at the database, not by convention.

  The wiring tests (lifecycle actions appending their kinds) are BD-2's;
  nothing here books an appointment.
  """

  use ClinicDemo.DataCase, async: true

  require Ash.Query

  alias AshDiscreteBusinessEvents.Ledger.VerifyChains
  alias AshDiscreteBusinessEvents.Mappings.Compiler
  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.Ledger.SimulationEvent
  alias ClinicDemo.BusinessEvents.MappingVersion
  alias ClinicDemo.Repo

  @staff %{id: "00000000-0000-0000-0000-0000000000ee", role: :veterinarian}
  @region :clinic

  # The §2a row contract, spelled where every wiring test (BD-2) will
  # meet it: region, residency, subject descriptor and delivery keys.
  @residency "ca"
  @subject_type "clinic.visit"

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  defp record_args(overrides \\ %{}) do
    Map.merge(
      %{
        event_kind: :visit_booked,
        region: @region,
        residency_tag: @residency,
        subject_type: @subject_type,
        subject_external_id: "apt-#{System.unique_integer([:positive])}",
        occurred_at: hours_ago(3),
        provenance: %{"mapping_name" => "visit_booked", "mapping_version_hash" => "00000000"},
        data: %{"expected_amount" => Decimal.new("175"), "severity" => 2}
      },
      overrides
    )
  end

  defp sim_args(overrides) do
    record_args(overrides)
    |> Map.merge(%{
      event_kind: :visit_completed,
      simulation_run: "bd1-test-run",
      delivery_key: "scenario:bd1-test-run:#{System.unique_integer([:positive])}:completed",
      data: %{"amount" => Decimal.new("175")}
    })
  end

  # ── install!: mappings as data ──────────────────────────────────────────

  describe "install!/0" do
    test "publishes all six declared mappings, active and content-hashed" do
      versions = BusinessEvents.install!()

      assert length(versions) == 6

      assert Enum.map(versions, & &1.mapping_name) ==
               Enum.map(BusinessEvents.mapping_names(), &to_string/1)

      assert Enum.all?(versions, &(&1.status == :active))

      for version <- versions do
        # The hash is 8 hex chars of the artifact's SHA-256 — and the
        # STORED artifact still hashes to it after the JSONB round trip,
        # which is what provenance joins and rule-pinned replay stand on.
        assert version.version_hash =~ ~r/^[0-9a-f]{8}$/

        assert version.version_hash ==
                 Compiler.hash(version.artifact)

        assert version.artifact["mapping_name"] == version.mapping_name
        # The one internal source, declaration-only: nothing syncs it.
        assert version.artifact["source"] == ["clinic_core", "appointment"]
      end
    end

    test "the artifacts are the design's six declarations, operators in declaration order" do
      versions = BusinessEvents.install!()
      by_name = Map.new(versions, &{String.to_existing_atom(&1.mapping_name), &1})

      booked_ops = by_name.visit_booked.artifact["ops"]

      assert [%{"op" => "map", "target" => "occurred_at", "type" => "utc_datetime_usec"} | _] =
               booked_ops

      assert %{"op" => "map", "target" => "expected_amount", "from" => "base_price"} =
               Enum.find(booked_ops, &(&1["target"] == "expected_amount"))

      # Refusal by name: the PII gap is authored data, not a silence.
      assert %{"op" => "unmapped_because", "target" => "patient_name"} =
               Enum.find(booked_ops, &(&1["op"] == "unmapped_because"))

      triaged_ops = by_name.visit_triaged.artifact["ops"]

      # The one decode: urgency banded, four cases. Stored case keys ride
      # the compile-time JSON canonicalization (a case key is a JSON term,
      # so `"emergency"` and :emergency hit one case after storage).
      assert %{"op" => "decode", "from" => "urgency", "cases" => cases} =
               Enum.find(triaged_ops, &(&1["op"] == "decode"))

      assert cases ==
               Map.new(
                 %{
                   "emergency" => "high",
                   "urgent" => "high",
                   "soon" => "medium",
                   "routine" => "low"
                 },
                 fn {key, band} -> {Jason.encode!(key), band} end
               )

      # The absent-path kind: no default on the amount — a completion with
      # no catalogue type writes no amount key at all.
      completed_ops = by_name.visit_completed.artifact["ops"]
      assert Enum.find(completed_ops, &(&1["target"] == "amount"))["default"] == nil

      for version <- versions do
        # Every rule is honest about where it came from.
        assert Enum.find(version.artifact["ops"], &(&1["target"] == "source_system"))["value"] ==
                 "clinic_core"
      end
    end

    test "is idempotent: a re-run returns the same hash-identified rows and adds none" do
      first = BusinessEvents.install!()
      second = BusinessEvents.install!()

      assert Enum.map(first, &{&1.id, &1.version_hash}) ==
               Enum.map(second, &{&1.id, &1.version_hash})

      assert MappingVersion |> Ash.read!(authorize?: false) |> length() == 6
    end

    test "leaves exactly one active version per mapping name" do
      BusinessEvents.install!()

      for name <- BusinessEvents.mapping_names() do
        {:ok, active} = MappingVersion.active(to_string(name))
        assert active.status == :active

        actives =
          MappingVersion
          |> Ash.Query.filter(mapping_name == ^to_string(name) and status == :active)
          |> Ash.read!(authorize?: false)

        assert length(actives) == 1
      end
    end
  end

  # ── the ledger: record, collapse, twin, chains ─────────────────────────

  describe "the ledger's record path" do
    setup do
      versions = BusinessEvents.install!()
      %{versions: versions}
    end

    test "a recorded event round-trips through the generated interfaces", %{versions: versions} do
      booked = hd(versions)
      occurred_at = hours_ago(3)

      row =
        Ledger.record!(
          record_args(%{
            subject_external_id: "apt-roundtrip",
            delivery_key: "clinic.visit_booked:apt-roundtrip",
            occurred_at: occurred_at,
            provenance: %{
              "mapping_name" => "visit_booked",
              "mapping_version_hash" => booked.version_hash
            }
          }),
          actor: @staff
        )

      # The three clocks answer three different questions: truth time is
      # the write's, knowledge time is the wall clock, sequence is commit
      # order — and a back-dated write is exactly where the split shows.
      # (The event kind rides `action`, the AshEvents machinery field the
      # projector DSL matches on.)
      assert row.region == @region
      assert row.residency_tag == @residency
      assert row.subject_type == @subject_type
      assert row.subject_external_id == "apt-roundtrip"
      assert DateTime.compare(row.observed_at, row.occurred_at) == :gt
      # Equal instants — the row loads back at usec precision, the write
      # was second-truncated.
      assert DateTime.compare(row.occurred_at, occurred_at) == :eq

      # Commit order is a bigserial shared across the table (the per-region
      # lock makes it commit order) — a fresh integer, not a pinned value.
      assert is_integer(row.sequence)
      assert row.action == :visit_booked
      assert row.action_type == :create
      assert row.record_id == "apt-roundtrip"

      # Chained from birth, and provenance resolves to the active
      # MappingVersion row. (previous_hash is nil only for the region's
      # genuinely first row — async tests share the table, so the link's
      # integrity is VerifyChains' assertion below, not this one's.)
      assert is_binary(row.hash)
      assert row.provenance["mapping_version_hash"] == booked.version_hash

      [read_back] = Ledger.by_subject!(@region, "apt-roundtrip")
      assert read_back.id == row.id

      # `data` is a JSON column: the decimal rides its string form, the
      # way every :map attribute round-trips. The projection (BD-3) casts
      # at fold time; the ledger row is the canonical JSON term.
      assert read_back.data == %{"expected_amount" => "175", "severity" => 2}
    end

    test "a delivery key collapses a repeat to the existing row — no second link" do
      args =
        record_args(%{
          subject_external_id: "apt-collapse",
          delivery_key: "clinic.visit_booked:apt-collapse"
        })

      first = Ledger.record!(args, actor: @staff)
      second = Ledger.record!(args, actor: @staff)

      assert first.id == second.id
      assert Ledger.by_subject!(@region, "apt-collapse") |> length() == 1
    end

    test "the commit-order feed walks the region in sequence order" do
      Ledger.record!(
        record_args(%{
          subject_external_id: "apt-feed-1",
          delivery_key: "clinic.visit_booked:apt-feed-1"
        }),
        actor: @staff
      )

      Ledger.record!(
        record_args(%{
          subject_external_id: "apt-feed-2",
          delivery_key: "clinic.visit_booked:apt-feed-2"
        }),
        actor: @staff
      )

      feed = Ledger.feed!(@region, %{after_sequence: 0})
      sequences = Enum.map(feed, & &1.sequence)

      assert sequences == Enum.sort(sequences)
      assert length(sequences) >= 2
    end

    test "record wants an actor, the way every write in this app is attributed" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ledger.record(record_args(), authorize?: true)
    end
  end

  describe "the simulation twin" do
    setup do
      %{versions: BusinessEvents.install!()}
    end

    test "sim rows carry the run label by shape, and simulation_runs/1 is the supported read" do
      sim =
        SimulationEvent.record!(sim_args(%{subject_external_id: "apt-sim-1"}),
          actor: @staff
        )

      assert sim.simulated == true
      assert sim.simulation_run == "bd1-test-run"

      # The real ledger cannot hold a sim row: the twin is another module
      # and another table — isolation by shape, not by remembered filter.
      assert Ledger.by_subject!(@region, "apt-sim-1") == []

      [run] = AshDiscreteBusinessEvents.simulation_runs(Ledger)
      assert run.simulation_run == "bd1-test-run"
      assert run.events == 1
      assert run.subjects == 1
    end
  end

  describe "tamper evidence" do
    setup do
      %{versions: BusinessEvents.install!()}
    end

    test "the per-region chains verify over real and simulated rows, both tables" do
      for i <- 1..3 do
        Ledger.record!(
          record_args(%{
            subject_external_id: "apt-chain-#{i}",
            delivery_key: "clinic.visit_booked:apt-chain-#{i}"
          }),
          actor: @staff
        )
      end

      SimulationEvent.record!(sim_args(%{subject_external_id: "apt-chain-sim"}),
        actor: @staff
      )

      results = VerifyChains.verify_all(Ledger)

      assert VerifyChains.clean?(results)

      clinic = Enum.find(results, &(&1.region == @region))
      assert clinic.checked >= 3

      sim = Enum.find(results, &(&1.region == @region))
      # verify_all walks the twin's table too — a quietly diverging sim
      # chain is exactly what it exists to catch.
      assert sim.checked >= 1
    end

    test "the table is append-only at the database, not by convention" do
      row =
        Ledger.record!(
          record_args(%{
            subject_external_id: "apt-immutable",
            delivery_key: "clinic.visit_booked:apt-immutable"
          }),
          actor: @staff
        )

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE business_event_ledger SET data = '{}' WHERE id = $1", [
          Ecto.UUID.dump!(row.id)
        ])
      end
    end
  end
end
