defmodule ClinicDemo.SystemOneSpike.ModelsTest do
  # Not async: the resolver reads System env, which is global to the VM.
  use ExUnit.Case, async: false

  alias ClinicDemo.SystemOneSpike.Models
  alias ClinicDemo.SystemOneSpike.Transport

  # Every variable the resolver reads, so each test starts from a known,
  # empty environment and the operator's real endpoints file never leaks in.
  @env_vars [
    "OLLAYA_BASE_URL",
    "S1_OLLAYA_GPU_BASE_URL",
    "S1_OLLAYA_ROUTES",
    "OLLAYA_API_KEY",
    "S1_SPIKE_RECEIVE_TIMEOUT_MS"
  ]

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})

    for var <- @env_vars, do: System.delete_env(var)

    on_exit(fn ->
      for {var, value} <- saved do
        case value do
          nil -> System.delete_env(var)
          value -> System.put_env(var, value)
        end
      end
    end)

    :ok
  end

  describe "ollaya_base_url/1 with S1_OLLAYA_ROUTES unset" do
    test "every model uses OLLAYA_BASE_URL, with a trailing / trimmed" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435/")

      assert Models.ollaya_base_url("laya:typed-decisions") == "http://cpu.test:11435"
      assert Models.ollaya_base_url("winnow:e4b") == "http://cpu.test:11435"
    end

    test "unset OLLAYA_BASE_URL is an error naming the variable" do
      assert_raise ArgumentError, ~r/OLLAYA_BASE_URL/, fn ->
        Models.ollaya_base_url("winnow:e4b")
      end
    end
  end

  describe "ollaya_base_url/1 with S1_OLLAYA_ROUTES set" do
    test "a CPU entry reads OLLAYA_BASE_URL" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU,winnow:e4b=GPU")

      assert Models.ollaya_base_url("laya:typed-decisions") == "http://cpu.test:11435"
    end

    test "a GPU entry reads S1_OLLAYA_GPU_BASE_URL, trailing / trimmed" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.test:11435/")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU,winnow:e4b=GPU")

      assert Models.ollaya_base_url("winnow:e4b") == "http://gpu.test:11435"
    end

    test "a model with no entry raises, naming the model and the variable" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU")

      error =
        assert_raise ArgumentError, fn ->
          Models.ollaya_base_url("winnow:e4b")
        end

      assert Exception.message(error) =~ "winnow:e4b"
      assert Exception.message(error) =~ "S1_OLLAYA_ROUTES"
    end

    test "an entry with an unknown host raises, naming the model and the variable" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b=drone")

      error =
        assert_raise ArgumentError, fn ->
          Models.ollaya_base_url("winnow:e4b")
        end

      assert Exception.message(error) =~ "winnow:e4b"
      assert Exception.message(error) =~ "S1_OLLAYA_ROUTES"
    end

    test "a GPU entry with S1_OLLAYA_GPU_BASE_URL unset raises, naming the variable" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "winnow:e4b=GPU")

      assert_raise ArgumentError, ~r/S1_OLLAYA_GPU_BASE_URL/, fn ->
        Models.ollaya_base_url("winnow:e4b")
      end
    end

    test "an empty routes variable behaves as unset" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "")

      assert Models.ollaya_base_url("winnow:e4b") == "http://cpu.test:11435"
    end
  end

  describe "spec/3 threads the per-model URL" do
    test "live carries the routed base URL" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU,winnow:e4b=GPU")

      assert {:typesafe, "winnow:e4b", opts} = Models.spec(:winnow, :live)
      assert opts[:base_url] == "http://gpu.test:11435"
    end

    test "record forwards to the routed host as the transport's upstream" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU,winnow:e4b=GPU")

      assert {:typesafe, "winnow:e4b", opts} = Models.spec(:winnow, {:record, "test-set"}, "cold")
      assert opts[:base_url] == Transport.placeholder_base_url()

      assert {Transport, plug_opts} = opts[:req_http_options][:plug]
      assert plug_opts[:mode] == :record
      assert plug_opts[:upstream] == "http://gpu.test:11435"
      assert plug_opts[:model] == "winnow:e4b"
      assert plug_opts[:tag] == "cold"
    end

    test "live without a usable host raises rather than dialling nowhere" do
      assert_raise ArgumentError, ~r/OLLAYA_BASE_URL/, fn ->
        Models.spec(:laya, :live)
      end
    end
  end

  describe "live_configured?/0" do
    test "true when every spec resolves to a base URL" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://gpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU,winnow:e4b=GPU")

      assert Models.live_configured?()
    end

    test "false when a routed model's host variable is missing" do
      System.put_env("OLLAYA_BASE_URL", "http://cpu.test:11435")
      System.put_env("S1_OLLAYA_ROUTES", "laya:typed-decisions=CPU,winnow:e4b=GPU")

      refute Models.live_configured?()
    end

    test "false when the single host variable is missing" do
      refute Models.live_configured?()
    end
  end
end
