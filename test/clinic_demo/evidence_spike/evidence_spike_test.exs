defmodule ClinicDemo.EvidenceSpikeTest do
  # Not async: the Wire mode is application config, shared by every process.
  use ExUnit.Case, async: false

  alias ClinicDemo.EvidenceSpike.{
    Certificates,
    Extraction,
    Extractor,
    Models,
    Observation,
    Runner,
    Wire
  }

  setup do
    previous = Application.get_env(:clinic_demo, Wire)
    on_exit(fn -> Application.put_env(:clinic_demo, Wire, previous || []) end)
    :ok
  end

  defp mode(mode, set \\ "stub"),
    do: Application.put_env(:clinic_demo, Wire, mode: mode, set: set)

  defp keys_anywhere(%{} = map),
    do: Map.keys(map) ++ Enum.flat_map(Map.values(map), &keys_anywhere/1)

  defp keys_anywhere(list) when is_list(list), do: Enum.flat_map(list, &keys_anywhere/1)
  defp keys_anywhere(_), do: []

  defp enums(%{} = map) do
    own = if is_list(map["enum"]), do: [map["enum"]], else: []
    own ++ Enum.flat_map(Map.values(map), &enums/1)
  end

  defp enums(list) when is_list(list), do: Enum.flat_map(list, &enums/1)
  defp enums(_), do: []

  describe "UPD-EXTRACT-VERIFY/AC-3: the schema sent" do
    test "has no confidence field anywhere" do
      for schema <- [Extractor.static_schema(), Extractor.enum_schema(["a01", "a02"])] do
        refute "confidence" in keys_anywhere(schema)
      end
    end

    test "every value enum carries an abstention value" do
      value_enums =
        Extractor.static_schema()
        |> enums()
        |> Enum.uniq()

      assert ["found", "not_found", "ambiguous"] in value_enums

      for enum <- value_enums do
        assert Enum.any?(enum, &(&1 in ["not_found", "ambiguous", "not_stated"])),
               "enum #{inspect(enum)} has no abstention value"
      end
    end

    test "the per-call schema narrows every source_ids to the packet's ids, and the empty list abstains" do
      schema = Extractor.enum_schema(["a01", "a02"])

      for {_field, prop} <- schema["properties"]["result"]["properties"] do
        ids = prop["properties"]["source_ids"]
        assert ids["type"] == "array"
        assert ids["items"]["enum"] == ["a01", "a02"]
        refute Map.has_key?(ids, "minItems")
      end
    end

    test "the static schema is the one ash_ai's prompt action sends" do
      # The committed stub set was keyed by Wire from the payload the prompt
      # action really built. If static_schema/0 drifted from it, this key
      # would not be in the set.
      [cert] = Certificates.generate(1)

      key =
        Wire.key(Models.extractor(), %{
          op: "generate_object",
          messages: Wire.messages(Extractor.messages(cert.atoms)),
          schema: Extractor.static_schema()
        })

      assert Map.has_key?(Wire.load("stub"), key)
    end
  end

  describe "UPD-EXTRACT-VERIFY/AC-2: casting" do
    test "a regex-violating reply is rejected, recorded, and not repaired" do
      mode(:stub)
      # Certificate 9 is where the stub plants a malformed policy number.
      {_summary, _} = Runner.run(n: 9, paths: [:static], verifiers: ["laya:typed-decisions"])

      [row | _] =
        Observation.list!(query: [filter: [certificate_id: "cert-009", kind: :extraction]])
        |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})

      refute row.passed
      assert row.detail =~ "match"
      assert get_in(row.raw_reply, ["reply", "result", "policy_number", "value"]) == "CLV-12AB"

      assert Observation.list!(
               query: [filter: [run_id: row.run_id, certificate_id: "cert-009", kind: :proposal]]
             ) == []
    end

    test "a length-violating field is rejected by the cast" do
      constraints = Extractor.return_constraints()
      field = %{"value" => nil, "status" => "not_found", "source_ids" => []}

      reply =
        Map.new(Certificates.fields(), &{to_string(&1), field})
        |> Map.put("insured_name", %{
          "value" => String.duplicate("x", 121),
          "status" => "found",
          "source_ids" => ["a03"]
        })

      # The same two steps the prompt action takes; either may reject.
      result =
        with {:ok, cast} <- Ash.Type.cast_input(Extraction, reply, constraints) do
          Ash.Type.apply_constraints(Extraction, cast, constraints)
        end

      assert {:error, %{field: :value, vars: [max: 120]}} = result
    end
  end

  describe "UPD-EXTRACT-VERIFY/AC-1: citations (harness, on the committed stub set)" do
    test "N >= 20: the per-call enum fabricates no citation; the static rate is reported" do
      mode(:replay, "stub")
      {summary, _} = Runner.run(n: 20)

      assert summary.certificates >= 20
      assert summary.provenance == ["stub"]
      assert summary.paths.enum.fabricated_citation_rate == 0.0
      assert is_float(summary.paths.static.fabricated_citation_rate)
    end
  end

  describe "the wire" do
    setup do
      System.put_env("S1_GEN_BASE_URL", "http://gen.invalid:8080/v1")
      System.put_env("OLLAYA_BASE_URL", "http://ollaya.invalid:11435")
      System.put_env("S1_GEN_API_KEY", "test-key-not-real")

      on_exit(fn ->
        Enum.each(~w(S1_GEN_BASE_URL OLLAYA_BASE_URL S1_GEN_API_KEY), &System.delete_env/1)
      end)
    end

    defp capture(reply) do
      parent = self()

      fn req ->
        send(
          parent,
          {:request, URI.to_string(req.url), req.body && IO.iodata_to_binary(req.body)}
        )

        {req,
         Req.Response.new(
           status: 200,
           body: JSON.encode!(reply),
           headers: %{"content-type" => ["application/json"]}
         )}
      end
    end

    defp completion_reply do
      %{
        "id" => "x",
        "object" => "chat.completion",
        "created" => 0,
        "model" => "qwen3.8-27b",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => ~s({"result":{}})}
          }
        ]
      }
    end

    test "the per-call enum reaches an OpenAI-compatible server as a json_schema response format" do
      mode(:live, "wire-test")

      reply = %{
        "id" => "x",
        "object" => "chat.completion",
        "created" => 0,
        "model" => "qwen3.8-27b",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => ~s({"result":{}})}
          }
        ]
      }

      _ =
        Wire.generate_object(
          Models.extractor(),
          Extractor.messages([%{id: "a01", text: "x"}]),
          Extractor.enum_schema(["a01", "a02"]),
          req_http_options: [adapter: capture(reply)]
        )

      assert_received {:request, "http://gen.invalid:8080/v1/chat/completions", body}
      body = JSON.decode!(body)
      refute Map.has_key?(body, "tools")
      assert body["response_format"]["type"] == "json_schema"

      assert get_in(body, ~w(response_format json_schema schema properties result properties
                               insurer properties source_ids items enum)) == ["a01", "a02"]
    end

    test "a verifier call goes to Ollaya's TypeSafe endpoint" do
      mode(:live, "wire-test")

      _ =
        Wire.evaluate(
          Models.verifier("laya:typed-decisions"),
          %{atoms: %{"a01" => "x"}},
          %{"q" => %{type: :boolean, instructions: "?"}},
          req_http_options: [adapter: capture(%{})]
        )

      assert_received {:request, "http://ollaya.invalid:11435/v1/systemone", _body}
    end

    test "S1_GEN_REASONING_EFFORT reaches the wire as reasoning_effort" do
      mode(:live, "wire-test")
      System.put_env("S1_GEN_REASONING_EFFORT", "none")

      on_exit(fn -> System.delete_env("S1_GEN_REASONING_EFFORT") end)

      _ =
        Wire.generate_object(
          Models.extractor(),
          Extractor.messages([%{id: "a01", text: "x"}]),
          Extractor.enum_schema(["a01", "a02"]),
          req_http_options: [adapter: capture(completion_reply())]
        )

      assert_received {:request, "http://gen.invalid:8080/v1/chat/completions", body}
      assert JSON.decode!(body)["reasoning_effort"] == "none"
    end

    test "an unset S1_GEN_REASONING_EFFORT sends no reasoning_effort" do
      mode(:live, "wire-test")
      System.delete_env("S1_GEN_REASONING_EFFORT")

      _ =
        Wire.generate_object(
          Models.extractor(),
          Extractor.messages([%{id: "a01", text: "x"}]),
          Extractor.enum_schema(["a01", "a02"]),
          req_http_options: [adapter: capture(completion_reply())]
        )

      assert_received {:request, "http://gen.invalid:8080/v1/chat/completions", body}
      refute Map.has_key?(JSON.decode!(body), "reasoning_effort")
    end

    test "replay reports a miss instead of answering" do
      mode(:replay, "no-such-set")

      assert {:error, message} =
               Wire.evaluate(Models.verifier("laya:typed-decisions"), %{}, %{}, [])

      assert message =~ "no fixture"
    end

    test "fixture labels never carry endpoint details" do
      assert Wire.model_label(Models.extractor()) == "openai:qwen3.8-27b"
      body = File.read!(Wire.fixture_path("stub"))
      refute body =~ "base_url"
      refute body =~ "api_key"
      refute body =~ "test-key-not-real"
    end
  end

  describe "the extractor's reasoning effort" do
    test "a value outside the allow-list fails loud" do
      System.put_env("S1_GEN_REASONING_EFFORT", "sometimes")

      on_exit(fn -> System.delete_env("S1_GEN_REASONING_EFFORT") end)

      assert_raise ArgumentError, ~r/S1_GEN_REASONING_EFFORT/, fn -> Models.extractor() end
    end
  end

  describe "per-model host routing (S1_OLLAYA_ROUTES)" do
    setup do
      System.put_env("OLLAYA_BASE_URL", "http://ollaya.invalid:11435")

      on_exit(fn ->
        Enum.each(
          ~w(OLLAYA_BASE_URL S1_OLLAYA_ROUTES S1_OLLAYA_GPU_BASE_URL),
          &System.delete_env/1
        )
      end)

      :ok
    end

    test "with the routes variable unset, every verifier stays on OLLAYA_BASE_URL" do
      System.delete_env("S1_OLLAYA_ROUTES")

      assert {:typesafe, "winnow:e4b", opts} = Models.verifier("winnow:e4b")
      assert opts[:base_url] == "http://ollaya.invalid:11435"
    end

    test "with no host URLs at all (stub and CI), a verifier still builds, unrouted" do
      System.delete_env("S1_OLLAYA_ROUTES")
      System.delete_env("OLLAYA_BASE_URL")

      assert {:typesafe, "laya:typed-decisions", opts} = Models.verifier("laya:typed-decisions")
      refute Keyword.has_key?(opts, :base_url)
    end

    test "a GPU-routed verifier goes to S1_OLLAYA_GPU_BASE_URL, a CPU-routed one to OLLAYA_BASE_URL" do
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU, winnow:e4b=GPU")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.invalid:11435")

      assert {:typesafe, "winnow:e4b", opts} = Models.verifier("winnow:e4b")
      assert opts[:base_url] == "http://gpu.invalid:11435"

      assert {:typesafe, "laya:typed-decisions", laya} = Models.verifier("laya:typed-decisions")
      assert laya[:base_url] == "http://ollaya.invalid:11435"
    end

    test "routing never changes the fixture label" do
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b=GPU")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.invalid:11435")

      assert Wire.model_label(Models.verifier("winnow:e4b")) == "typesafe:winnow:e4b"
    end

    test "the routes variable set without an entry for the model fails loud" do
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b=GPU")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.invalid:11435")

      assert_raise ArgumentError,
                   ~r/S1_OLLAYA_ROUTES is set but has no entry for laya:typed-decisions/,
                   fn ->
                     Models.verifier("laya:typed-decisions")
                   end
    end

    test "a GPU route without S1_OLLAYA_GPU_BASE_URL fails loud" do
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b=GPU")
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")

      assert_raise ArgumentError, ~r/S1_OLLAYA_GPU_BASE_URL/, fn ->
        Models.verifier("winnow:e4b")
      end
    end

    test "a malformed route entry fails loud" do
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b@GPU")

      assert_raise ArgumentError, ~r/not model=CPU or model=GPU/, fn ->
        Models.verifier("winnow:e4b")
      end
    end

    test "a route host other than CPU or GPU fails loud" do
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b=TPU")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.invalid:11435")

      assert_raise ArgumentError, ~r/must be CPU or GPU/, fn ->
        Models.verifier("winnow:e4b")
      end
    end
  end
end
