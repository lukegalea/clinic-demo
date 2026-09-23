defmodule ClinicDemoWeb.AgentLiveTest do
  @moduledoc """
  The zero-jank contract of the agent console: submitting a request
  acknowledges immediately (thinking state on the wire), the interpreter
  runs off the LiveView process, and the outcome — plan, provider error, or
  a crash — clears the state without freezing anything else on the page.
  """

  use ClinicDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  # How long the async interpreter may take to land before the test gives
  # up. The no-key error path it exercises is a registry lookup, so this is
  # a generosity margin, not a wait. (The registry load alone is
  # seconds on a cold VM.)
  @tries 2_000

  describe "the async propose flow" do
    test "acking the submit shows the thinking state, then the outcome, and the console stays usable",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/agent")
      refute html =~ "Thinking…"

      view
      |> element("#agent-request")
      |> render_submit(%{request: "show me the patients"})

      # The event acked with the thinking state rendered; the interpreter's
      # model calls are running off the LiveView process, so this page never
      # froze waiting for them.
      assert render(view) =~ "Thinking…"

      # No API key is configured in tests, so the async completes with the
      # honest not-configured error — a flash in the error slot, not a
      # frozen page.
      assert eventually(view, "No API key")
      refute render(view) =~ "Thinking…"

      # And the console is still usable: the declared-surface path renders a
      # plan with no model involved at all.
      Sandbox.allow(ClinicDemo.Repo, self(), view.pid)

      view
      |> element("#open-patients")
      |> render_click()

      assert render(view) =~ "Patients"
    end

    test "the completion path clears the thinking state and renders the plan" do
      socket = socket(thinking: true)

      {:noreply, socket} =
        ClinicDemoWeb.AgentLive.handle_async(
          :interpret,
          {:ok, {:ok, {:answer, "Emergency means severity 5."}}},
          socket
        )

      refute socket.assigns.thinking
      assert socket.assigns.result == "Emergency means severity 5."
      assert socket.assigns.error == nil
    end

    test "a provider error lands in the error slot, not the result slot" do
      socket = socket(thinking: true)

      {:noreply, socket} =
        ClinicDemoWeb.AgentLive.handle_async(
          :interpret,
          {:ok, {:error, "No API key is configured."}},
          socket
        )

      refute socket.assigns.thinking
      assert socket.assigns.error =~ "No API key"
      assert socket.assigns.result == nil
    end

    test "an interpreter crash is a friendly non-blocking error" do
      socket = socket(thinking: true)

      {:noreply, socket} =
        ClinicDemoWeb.AgentLive.handle_async(:interpret, {:exit, :killed}, socket)

      refute socket.assigns.thinking
      assert socket.assigns.error =~ "stopped before answering"
    end
  end

  # The completion callbacks only touch assigns and the message stream, so
  # they are exercised directly through the real callbacks with a minimal
  # socket. The stream registry is built by the real `stream/3`, exactly as
  # mount builds it — but `stream/3` attaches a lifecycle hook, and
  # lifecycle state normally comes from the channel (`Channel.load_lifecycle/2`),
  # so the seed below is the channel's empty-hook starting point: the five
  # stages `Lifecycle.update_lifecycle/3` Map.update!s over, with no hooks.
  @lifecycle_stages [
    :handle_params,
    :handle_event,
    :handle_info,
    :handle_async,
    :after_render
  ]

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}, lifecycle: Map.new(@lifecycle_stages, &{&1, []})}
    }
    |> Phoenix.LiveView.stream(:messages, [])
    |> Map.update!(:assigns, fn stream_assigns ->
      Map.merge(
        %{
          request: "test request",
          error: nil,
          result: nil,
          thinking: false,
          presentation: nil,
          refresh_scheduled?: false,
          cue: nil,
          cue_ref: nil,
          a2ui_actor: nil,
          flash: %{}
        },
        Map.new(assigns)
      )
      |> Map.merge(stream_assigns)
    end)
  end

  # Polls the view because the async patch lands on its own schedule.
  defp eventually(view, pattern, tries \\ @tries)

  defp eventually(_view, _pattern, 0) do
    flunk("expected the async outcome to render, but it never did")
  end

  defp eventually(view, pattern, tries) do
    html = render(view)

    if html =~ pattern do
      html
    else
      Process.sleep(10)
      eventually(view, pattern, tries - 1)
    end
  end
end
