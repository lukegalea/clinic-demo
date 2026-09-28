defmodule ClinicDemo.SystemOneSpikeTest do
  # Not async: the replay tests write and delete a fixture set, and the
  # transport caches sets in :persistent_term.
  use ExUnit.Case, async: false

  alias ClinicDemo.SystemOneSpike
  alias ClinicDemo.SystemOneSpike.Band
  alias ClinicDemo.SystemOneSpike.Runner
  alias ClinicDemo.SystemOneSpike.Transport

  # No test here reaches a network. Every request is answered by a Req plug:
  # the stub, a replay set, or a capturing plug.

  defp run(action, state, transport, spec \\ :laya, tag \\ "r1") do
    SystemOneSpike
    |> Ash.ActionInput.for_action(action, state,
      context: %{system_one_spike: %{spec: spec, transport: transport, tag: tag}}
    )
    |> Ash.run_action()
  end

  describe "the three actions, over the stubbed TypeSafe wire" do
    test "notes_follow_up returns a noul probability and the reported model" do
      assert {:ok, %AshAi.Actions.Result{result: %AshAi.Evaluate.Noul{probability: p}} = result} =
               run(:notes_follow_up, %{notes: "Recheck booked in 14 days."}, :stub)

      assert p >= 0.0 and p <= 1.0
      assert result.model == "laya:typed-decisions+stub"
      assert is_integer(result.usage[:input_tokens])
    end

    test "presenting_urgency returns one of the triage options or an abstention" do
      assert {:ok, %AshAi.Actions.Result{result: %AshAi.Evaluate.Choice{} = choice}} =
               run(
                 :presenting_urgency,
                 %{reason: "He collapsed on his walk.", species: "dog", age_band: "adult"},
                 :stub,
                 :winnow
               )

      assert choice.value in SystemOneSpike.urgency_options()

      assert Map.keys(choice.probabilities) |> Enum.sort() ==
               Enum.sort(SystemOneSpike.urgency_options())
    end

    test "the choice options are the appointment's triage options plus abstention" do
      assert SystemOneSpike.urgency_options() ==
               [:emergency, :urgent, :soon, :routine, :insufficient_information]
    end

    test "both asks the two questions in one request" do
      assert {:ok, %AshAi.Actions.Result{result: %{follow_up: noul, urgency: choice}}} =
               run(
                 :both,
                 %{
                   notes: "Discharged.",
                   reason: "Annual booster.",
                   species: "cat",
                   age_band: "adult"
                 },
                 :stub
               )

      assert %AshAi.Evaluate.Noul{} = noul
      assert %AshAi.Evaluate.Choice{} = choice
    end

    test "an action with no spec in its context refuses rather than guessing a model" do
      assert_raise Ash.Error.Unknown, ~r/system_one_spike/, fn ->
        SystemOneSpike
        |> Ash.ActionInput.for_action(:notes_follow_up, %{notes: "x"})
        |> Ash.run_action!()
      end
    end
  end

  describe "what reaches the wire" do
    test "one POST to /v1/systemone carrying the model id, the state and a typed question" do
      test_pid = self()

      plug = fn conn ->
        send(
          test_pid,
          {:request, conn.method, conn.request_path, conn.req_headers, conn.body_params}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{
            "model" => "laya:typed-decisions@sha256:abc",
            "answers" => %{"notes_follow_up" => %{"type" => "noul", "noul" => 0.25}},
            "usage" => %{"input_tokens" => 12, "output_tokens" => 1}
          })
        )
      end

      assert {:ok, result} = run(:notes_follow_up, %{notes: "No recheck needed."}, {:plug, plug})
      assert result.result.probability == 0.25
      assert result.model == "laya:typed-decisions@sha256:abc"

      assert_received {:request, "POST", "/v1/systemone", headers, body}
      assert {"authorization", "Bearer local"} in headers
      assert body["model"] == "laya:typed-decisions"
      assert body["state"] == %{"notes" => "No recheck needed."}

      assert %{"type" => "noul", "instructions" => instructions, "criteria" => criteria} =
               body["questions"]["notes_follow_up"]

      assert instructions =~ "`notes`"
      assert Map.keys(criteria) |> Enum.sort() == ["false", "true"]
    end

    test "a reply without usage is refused by ReqLLM as an invalid TypeSafe response" do
      # If Ollaya omits `usage`, nothing casts. The live run checks this.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{
            "model" => "laya:typed-decisions",
            "answers" => %{"notes_follow_up" => %{"type" => "noul", "noul" => 0.25}}
          })
        )
      end

      assert {:error, error} = run(:notes_follow_up, %{notes: "x"}, {:plug, plug})
      described = Runner.describe_error(error)
      assert described["status"] == 200
      assert described["message"] =~ "Invalid TypeSafe evaluation response"
    end
  end

  describe "a state past the context window (AC-5, wire level)" do
    test "a 422 STATE_TRUNCATED arrives as a structured error, not a crash" do
      long = String.duplicate("Weight stable, coat good, eating well. ", 150)

      assert {:error, error} = run(:notes_follow_up, %{notes: long}, :stub, :laya)

      described = Runner.describe_error(error)
      assert described["kind"] == "Ash.Error.Unknown"
      assert described["cause"] == "ReqLLM.Error.API.Request"
      assert described["status"] == 422
      assert get_in(described, ["response_body", "error", "code"]) == "STATE_TRUNCATED"
    end
  end

  describe "record and replay" do
    setup do
      set = "test-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = File.rm(Transport.fixture_path(set))
        Transport.forget(set)
      end)

      %{set: set}
    end

    test "a recorded exchange replays to the same answer, per repeat tag", %{set: set} do
      state = %{notes: "Suture removal booked for the 14th."}

      {:ok, r1} = run(:notes_follow_up, state, {:stub_record, set}, :laya, "r1")
      {:ok, r2} = run(:notes_follow_up, state, {:stub_record, set}, :laya, "r2")

      assert {:ok, replay1} = run(:notes_follow_up, state, {:replay, set}, :laya, "r1")
      assert {:ok, replay2} = run(:notes_follow_up, state, {:replay, set}, :laya, "r2")

      assert replay1.result == r1.result
      assert replay2.result == r2.result
      refute r1.result == r2.result
    end

    test "fixtures never hold request headers", %{set: set} do
      {:ok, _} = run(:notes_follow_up, %{notes: "x y z"}, {:stub_record, set})
      body = File.read!(Transport.fixture_path(set))

      refute body =~ "authorization"
      refute body =~ "Bearer"

      assert [%{"provenance" => "stub", "request" => request}] =
               body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert Map.keys(request) |> Enum.sort() == ["model", "questions", "state"]
    end

    test "a changed question is a replay miss, reported as an error rather than a stale answer",
         %{set: set} do
      {:ok, _} = run(:notes_follow_up, %{notes: "one"}, {:stub_record, set})

      assert {:error, error} = run(:notes_follow_up, %{notes: "two"}, {:replay, set})

      assert %{"status" => 599, "response_body" => %{"replay_miss" => miss}} =
               Runner.describe_error(error)

      assert miss =~ "re-record"
    end

    test "the committed stub set replays every item" do
      rows = Runner.run(specs: [:laya], transport: {:replay, "stub"}, repeats: 1)[:rows]
      misses = Enum.filter(rows, &(&1["provenance"] == "replay-miss"))

      assert misses == [],
             "stale stub fixtures; regenerate with mix clinic.spike0 --transport stub --record-stub --set stub --cold"
    end
  end

  describe "the urgency suggestion band (AC-7)" do
    test "the publish-time verifier finds no overlap, no gap and owes nothing" do
      assert {:ok, %{findings: [], obligations: []}} = Band.verify()
    end

    test "the verifier would catch an overlap" do
      overlapping = String.replace(Band.xml(), "<text>&lt; 0.8</text>", "<text>&lt; 0.9</text>")
      assert {:ok, %{findings: findings}} = Band.verify(overlapping)
      assert Enum.any?(findings, &(&1.kind == :overlap))
    end

    test "suggests only a peaked, clear answer, and never an abstention" do
      assert {:ok, "suggest", _} = Band.decide(:urgent, %{urgent: 0.9, soon: 0.05, routine: 0.05})
      assert {:ok, "ask_human", _} = Band.decide(:urgent, %{urgent: 0.82, soon: 0.6})
      assert {:ok, "ask_human", _} = Band.decide(:urgent, %{urgent: 0.6, soon: 0.4})

      assert {:ok, "ask_human", _} =
               Band.decide(:insufficient_information, %{
                 insufficient_information: 0.99,
                 soon: 0.01
               })
    end
  end

  describe "the runner" do
    test "stub results are never given a verdict" do
      %{rows: rows, summary: summary} =
        Runner.run(specs: [:laya], transport: :stub, repeats: 2, limit: 3, cold: true)

      assert Enum.any?(rows, &(&1["tag"] == "cold"))
      assert Enum.all?(rows, &(&1["provenance"] == "stub"))
      assert summary["verdict"]["evaluable"] == false
      assert summary["specs"]["laya"]["noul"]["n_items"] == 3
      assert summary["specs"]["laya"]["noul"]["repeat_stddev"]["items"] == 3
    end
  end

  describe "the labelled items" do
    setup do
      %{items: Runner.items()}
    end

    test "at least 24 per question, with unique ids", %{items: items} do
      counts = Enum.frequencies_by(items, & &1["question"])
      assert counts["notes_follow_up"] >= 24
      assert counts["presenting_urgency"] >= 24
      assert items |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(items)
    end

    test "the noul strata meet the ticket's minimums", %{items: items} do
      strata =
        items
        |> Enum.filter(&(&1["question"] == "notes_follow_up"))
        |> Enum.frequencies_by(& &1["stratum"])

      for stratum <- ~w(clear_positive clear_negative hard_negative length_probe) do
        assert strata[stratum] >= 6, "#{stratum}: #{inspect(strata[stratum])}"
      end
    end

    test "the length probes straddle laya's 1,024-token context", %{items: items} do
      tokens = for %{"stratum" => "length_probe", "approx_tokens" => t} <- items, do: t
      assert Enum.any?(tokens, &(&1 < 1024))
      assert Enum.any?(tokens, &(&1 > 1024 and &1 < 1200))
      assert Enum.any?(tokens, &(&1 > 1500))
    end

    test "choice gold labels are all offered options", %{items: items} do
      options = Enum.map(SystemOneSpike.urgency_options(), &Atom.to_string/1)

      for %{"question" => "presenting_urgency", "gold" => gold} <- items do
        assert gold in options
      end
    end
  end

  test "no moving model alias appears in the spike code" do
    sources =
      [
        "lib/clinic_demo/system_one_spike.ex"
        | Path.wildcard("lib/clinic_demo/system_one_spike/**/*.ex")
      ]

    assert length(sources) > 1

    for path <- sources do
      refute File.read!(path) =~ "-latest", "#{path} names a -latest alias"
    end
  end
end
