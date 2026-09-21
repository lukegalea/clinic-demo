defmodule ClinicDemo.Decisions.TriageTest do
  @moduledoc """
  What the `appointment.triage` table answers, case by case.

  Every call here goes through `ClinicDemo.Decisions.Resolver`, which is the
  same seam the visit process's business rule task uses -- so these tests pin
  the integration and not just the table.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Decisions.Evaluation
  alias ClinicDemo.Decisions.Resolver

  defp urgency(severity, age_band, species) do
    {:ok, %{outputs: outputs}} =
      Resolver.decide(
        "appointment.triage",
        %{"severity" => severity, "ageBand" => age_band, "species" => species},
        %{}
      )

    outputs["urgency"]
  end

  describe "severity alone" do
    test "5 is an emergency whatever the animal" do
      assert urgency(5, "adult", "dog") == "emergency"
    end

    test "4 is an emergency whatever the animal" do
      assert urgency(4, "adult", "dog") == "emergency"
    end

    test "3 on an ordinary adult dog is urgent, not an emergency" do
      assert urgency(3, "adult", "dog") == "urgent"
    end

    test "2 is urgent" do
      assert urgency(2, "adult", "dog") == "urgent"
    end

    test "1 is routine" do
      assert urgency(1, "adult", "dog") == "routine"
    end
  end

  describe "age band raises the answer" do
    test "a moderately unwell neonate is an emergency" do
      assert urgency(3, "neonate", "dog") == "emergency"
    end

    test "a moderately unwell senior is an emergency" do
      assert urgency(3, "senior", "cat") == "emergency"
    end

    test "a barely unwell senior is seen soon rather than routinely" do
      assert urgency(1, "senior", "dog") == "soon"
    end

    test "a juvenile gets no lift" do
      assert urgency(1, "juvenile", "dog") == "routine"
    end
  end

  describe "prey species raise the answer" do
    test "a moderately unwell rabbit is an emergency" do
      assert urgency(3, "adult", "rabbit") == "emergency"
    end

    test "so is a ferret, a bird and a reptile" do
      for species <- ~w(ferret bird reptile) do
        assert urgency(3, "adult", species) == "emergency", species
      end
    end

    test "a barely unwell rabbit is seen soon" do
      assert urgency(1, "adult", "rabbit") == "soon"
    end

    test "a cat at the same severity is not lifted" do
      assert urgency(1, "adult", "cat") == "routine"
    end
  end

  describe "PRIORITY resolves the overlaps" do
    test "a severity-3 senior rabbit matches four rules and the most urgent wins" do
      # rule_fragile_age, rule_prey_species and rule_moderate all match, as
      # does rule_routine. PRIORITY picks by the order in the output's declared
      # values, not by where the rules sit in the document.
      assert urgency(3, "senior", "rabbit") == "emergency"
    end

    test "an unknown age band matches neither fragile rule" do
      # `age_band` is nil for an animal with no date of birth, and a null in
      # FEEL matches neither "neonate" nor "senior".
      assert urgency(1, nil, "dog") == "routine"
    end
  end

  describe "the evidence trail" do
    test "every evaluation writes a row carrying its inputs, outputs and version" do
      before = length(Ash.read!(Evaluation))

      assert urgency(4, "adult", "dog") == "emergency"

      rows = Ash.read!(Evaluation)
      assert length(rows) == before + 1

      row = rows |> Enum.sort_by(& &1.inserted_at, DateTime) |> List.last()
      assert row.definition_key == "appointment.triage"
      assert row.definition_version == 1
      assert row.inputs["species"] == "dog"
      assert row.outputs == %{"value" => "emergency"}
      assert row.duration_us > 0
    end
  end

  describe "an unknown decision" do
    test "is an error rather than a guess" do
      assert {:error, _} = Resolver.decide("appointment.nonsense", %{}, %{})
      refute Resolver.exists?("appointment.nonsense")
      assert Resolver.exists?("appointment.triage")
    end
  end
end
