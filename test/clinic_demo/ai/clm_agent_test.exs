defmodule ClinicDemo.AI.ClmAgentTest do
  @moduledoc """
  The CLM POC on the agent's two paths, without a model: the interpreter's
  `plan/2` seam for a declared surface, and `AshA2ui.Dynamic.resolve/2` under
  the same allowlist the interpreter composes with.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.AI.{Intent, Interpreter}
  alias ClinicDemoWeb.A2ui.Surfaces

  test "\"show me the contracts\" opens the declared contracts hub" do
    intent = %Intent{kind: :show_surface, surface: "contracts"}

    assert {:ok, {:surface, %{ui: ClinicDemoWeb.A2ui.ContractsHubUI}}} =
             Interpreter.plan(intent, "show me the contracts")
  end

  test "a composed contracts table resolves under the agent's allowlist" do
    spec = %{
      "resource" => "contract",
      "title" => "Contracts by expiry",
      "components" => [
        %{
          "kind" => "table",
          "fields" => ["name", "vendor_name", "expires_on", "verification", "to_check_count"],
          "read_action" => "read"
        }
      ]
    }

    assert {:ok, surface} = AshA2ui.Dynamic.resolve(spec, allowlist: Surfaces.dynamic_allowlist())
    assert surface.title == "Contracts by expiry"
  end

  test "the allowlist still refuses what it does not list" do
    spec = %{
      "resource" => "contract_secret",
      "title" => "Nope",
      "components" => [%{"kind" => "table", "fields" => ["name"], "read_action" => "read"}]
    }

    assert {:error, [_ | _]} =
             AshA2ui.Dynamic.resolve(spec, allowlist: Surfaces.dynamic_allowlist())
  end

  test "the model is told about the CLM resources" do
    descriptions = ClinicDemo.AI.RequestClassifier.resource_descriptions()

    for name <- ~w(contract contract_line extracted_value scheduled_work contract_document) do
      assert descriptions =~ ~s("resource":"#{name}")
    end
  end
end
