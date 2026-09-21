# Drives bin/serena-mcp over stdio, the way an MCP client would, so that the
# answers in docs/evidence are reproducible from a shell.
#
# Serena is the generic symbol half of this repository's agent wiring. Its
# tools are only meaningful through a client session, and the point of this
# script is that "a client session" is not a requirement: initialize,
# notifications/initialized, tools/list and tools/call over stdio are the whole
# protocol. The conversation recorded in docs/evidence is this script's output.
#
#     elixir docs/evidence/bin/serena-mcp-smoke.exs probe
#     elixir docs/evidence/bin/serena-mcp-smoke.exs read
#     elixir docs/evidence/bin/serena-mcp-smoke.exs rename
#
# Stages:
#   probe   initialize, notifications/initialized, tools/list
#   read    symbols overview + find_symbol with body, find_referencing_symbols
#           immediately and again after the cross-file wait, then find_symbol
#           for `complete` -- the Ash action that is not a symbol
#   rename  rename_symbol decide -> evaluate (the caller then captures the
#           git diff and reverts; this script edits the working tree)
#
# Requires the project to be compiled (Serena answers from _build) and OTP 27
# or newer for :json. Every payload the server sends is echoed, with elapsed
# time, so the waits are visible rather than documented.

defmodule SerenaSmoke do
  # First contact makes Expert index the project. This is the honest timeout,
  # not an optimistic one; a cold index is minutes.
  @timeout_ms 600_000

  # Serena's own number for cross-file referencing is ten seconds after the
  # language server is up. Twelve gives it margin.
  @cross_file_wait_ms 12_000

  @resolver "lib/clinic_demo/decisions/resolver.ex"

  def main(argv) do
    stage = case argv do
      [stage] when stage in ["probe", "read", "rename"] -> stage
      _ -> die("usage: serena-mcp-smoke.exs probe|read|rename")
    end

    root = Path.expand("../../..", __DIR__)
    script = Path.join(root, "bin/serena-mcp")

    unless File.exists?(script), do: die("no such script: #{script}")

    t0 = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, script}, [
        {:args, []},
        {:cd, root},
        {:env, env()},
        :binary,
        :exit_status
      ])

    log(t0, "spawned #{script} (bin/serena-mcp; uvx -> serena start-mcp-server --transport stdio)")

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "clinic-demo-evidence", "version" => "0.1.0"}
      }
    })

    log(t0, "-> initialize (Serena runs its activation_command, then boots Expert; first contact indexes the project)")
    {:ok, init, _} = await_response(port, 1, "")
    log(t0, "<- initialize ok after #{elapsed(t0)}ms")
    log(t0, "   serverInfo: " <> encode(Map.get(init, "serverInfo", %{})))
    log(t0, "   protocolVersion: " <> encode(Map.get(init, "protocolVersion", "")))

    notify(port, "notifications/initialized", %{})
    log(t0, "-> notifications/initialized")

    buffer = ""
    id = 2

    {buffer, id} =
      if stage == "probe" do
        # `tools/list` is a JSON-RPC request of its own, not a tools/call.
        send_message(port, %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}})
        started = System.monotonic_time(:millisecond)

        case await_response(port, id, "") do
          {:ok, result, rest} ->
            ms = System.monotonic_time(:millisecond) - started
            log(t0, "<- tools/list (#{ms}ms)")
            tools = Map.get(result, "tools", [])
            names = for %{"name" => n} <- tools, do: n
            log(t0, "   #{length(names)} tools: " <> Enum.join(names, ", "))

            Enum.each(tools, fn %{"name" => n} = schema ->
              log(t0, "   -- " <> n <> " " <> encode(Map.get(schema, "inputSchema", %{})))
            end)

            {rest, id + 1}

          {:error, reason} ->
            die(reason)
        end
      else
        log(t0, "-- tools/list elided in stage #{stage}; see probe transcript")
        {buffer, id}
      end

    case stage do
      "probe" ->
        :ok

      "read" ->
        {buffer, id} =
          call_tool(port, t0, "get_symbols_overview", %{"relative_path" => @resolver},
            buffer, id, label: "get_symbols_overview #{@resolver}")

        {buffer, _id} =
          call_tool(port, t0, "find_symbol",
            %{"name_path_pattern" => "decide", "relative_path" => @resolver, "include_body" => true},
            buffer, id, label: "find_symbol decide (include_body)")

        log(t0, "-- now the wait that is not a hang: find_referencing_symbols right away,")
        log(t0, "-- against Serena's own guidance of ~10s of indexing before it is right")

        {buffer, _} =
          call_tool(port, t0, "find_referencing_symbols",
            %{"name_path" => "decide", "relative_path" => @resolver},
            buffer, id, label: "find_referencing_symbols decide (IMMEDIATE)")

        log(t0, "-- sleeping #{@cross_file_wait_ms}ms before asking again")
        Process.sleep(@cross_file_wait_ms)

        {buffer, _} =
          call_tool(port, t0, "find_referencing_symbols",
            %{"name_path" => "decide", "relative_path" => @resolver},
            buffer, id, label: "find_referencing_symbols decide (after #{div(@cross_file_wait_ms, 1000)}s wait)")

        {_, _} =
          call_tool(port, t0, "find_symbol", %{"name_path_pattern" => "complete"},
            buffer, id, label: "find_symbol complete (the boundary: an Ash action is not a symbol)")

        :ok

      "rename" ->
        {buffer, id} =
          call_tool(port, t0, "find_symbol", %{"name_path_pattern" => "decide", "relative_path" => @resolver},
            buffer, id, label: "find_symbol decide (before rename)")

        {_buffer, _} =
          call_tool(port, t0, "rename_symbol",
            %{"name_path" => "decide", "relative_path" => @resolver, "new_name" => "evaluate"},
            buffer, id, label: "rename_symbol decide -> evaluate")

        :ok
    end

    Port.close(port)
    log(t0, "OK stage=#{stage} total #{elapsed(t0)}ms")
  end

  # --- tools/call, with the tool result decoded out of the envelope --------

  defp call_tool(port, t0, tool, args, buffer, id, opts) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => args}
    })

    started = System.monotonic_time(:millisecond)
    label = Keyword.fetch!(opts, :label)
    log(t0, "-> tools/call #{tool} #{encode(args)}")

    case await_response(port, id, buffer) do
      {:ok, result, rest} ->
        ms = System.monotonic_time(:millisecond) - started

        cond do
          result == false || Map.get(result, "isError") == true ->
            log(t0, "<- tools/call #{tool} ERROR after #{ms}ms")
            log_result(t0, result, opts)
            die("tool call failed: #{tool}")

          Keyword.get(opts, :raw?, false) ->
            log(t0, "<- #{label} (#{ms}ms)")
            log(t0, encode(result))

          true ->
            log(t0, "<- #{label} (#{ms}ms)")
            log_result(t0, result, opts)
        end

        {rest, id + 1}

      {:error, reason} ->
        die("#{tool}: #{reason}")
    end
  end

  # Serena's tool results arrive as MCP content parts. The text parts are the
  # answer -- find_symbol's is pretty-printed JSON -- and are what the
  # evidence transcripts quote.
  defp log_result(t0, result, _opts) do
    content = Map.get(result, "content", [])

    Enum.each(List.wrap(content), fn
      %{"type" => "text", "text" => text} ->
        log(t0, text)

      other ->
        log(t0, encode(other))
    end)

    case Map.get(result, "structuredContent") do
      nil -> :ok
      structured -> log(t0, "structuredContent: " <> encode(structured))
    end
  end

  # --- environment ---------------------------------------------------------

  # uvx must be findable, elixir must be findable (Serena refuses to start its
  # Elixir backend without it, and the activation_command is `mix compile`).
  # ELIXIR_BIN_DIR is bin/serena-mcp's own contract. Everything else is a
  # whitelist, deliberately: Port env replaces the whole environment, and a
  # child of this script has no business holding this shell's API keys.
  defp env do
    # Wherever Elixir lives on the reader's machine (a Nix store hash is
    # per-machine); ELIXIR_BIN_DIR is the same escape hatch bin/ash-agent
    # and bin/serena-mcp accept.
    elixir_bin =
      System.get_env("ELIXIR_BIN_DIR") ||
        Path.dirname(System.find_executable("elixir") || "/usr/bin/elixir")

    source = System.get_env()

    keep = [
      "HOME", "USER", "LOGNAME", "LANG", "TMPDIR",
      "NIX_SSL_CERT_FILE", "NIX_PROFILES",
      "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME",
      "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "no_proxy"
    ]

    base =
      source
      |> Map.take(keep)
      |> Map.put("ELIXIR_BIN_DIR", elixir_bin)
      |> Map.update("PATH", elixir_bin, &("#{elixir_bin}:" <> &1))
      # The system directories, for `env bash`, git, and everything else a
      # language server shells out to.
      |> Map.update!("PATH", &(&1 <> ":/usr/local/bin:/usr/bin:/bin"))

    # Wherever uvx came from on this machine, it stays reachable.
    base =
      case System.find_executable("uvx") do
        nil -> base
        uvx -> Map.update(base, "PATH", "", &("#{Path.dirname(uvx)}:" <> &1))
      end

    Enum.map(base, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  # --- JSON-RPC over newline-delimited stdio -------------------------------
  # MCP's stdio transport is one JSON-RPC message per line -- not LSP framing.
  # Requests FROM the server get answered: roots/list with the project root,
  # anything else with a null result, so the server never mistakes this client
  # for one that has hung.

  defp send_message(port, message) do
    Port.command(port, [:json.encode(message), "\n"])
  end

  defp notify(port, method, params) do
    send_message(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp await_response(port, id, buffer) do
    case take_message(buffer) do
      {:ok, message, rest} ->
        case :json.decode(message) do
          %{"id" => ^id, "result" => result} ->
            {:ok, result, rest}

          %{"id" => ^id, "error" => error} ->
            {:error, "server returned an error: #{encode(error)}"}

          %{"id" => other_id, "method" => method} ->
            reply =
              if method == "roots/list" do
                root = Path.expand("../../..", __DIR__)

                %{"roots" => [%{"uri" => "file://" <> root, "name" => "clinic_demo"}]}
              else
                :null
              end

            debug("<- request #{method} (##{other_id}); replying " <> encode(reply))
            send_message(port, %{"jsonrpc" => "2.0", "id" => other_id, "result" => reply})
            await_response(port, id, rest)

          %{"method" => method} = notification when is_binary(method) ->
            snippet = notification |> Map.delete("method") |> Map.delete("jsonrpc") |> encode()
            debug("<- #{method} #{byte_size(snippet)} bytes")
            await_response(port, id, rest)

          _other ->
            await_response(port, id, rest)
        end

      :more ->
        receive do
          {^port, {:data, data}} -> await_response(port, id, buffer <> data)
          {^port, {:exit_status, status}} -> {:error, "serena-mcp exited with status #{status}"}
        after
          @timeout_ms -> {:error, "no response to request #{id} within #{div(@timeout_ms, 1000)}s"}
        end
    end
  end

  defp take_message(buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] when byte_size(line) > 0 -> {:ok, line, rest}
      ["", rest] -> take_message(rest)
      _ -> :more
    end
  end

  # --- plumbing ------------------------------------------------------------

  defp encode(term) do
    IO.iodata_to_binary(:json.encode(term))
  rescue
    _ -> inspect(term)
  end

  defp elapsed(t0), do: System.monotonic_time(:millisecond) - t0

  defp log(t0, line), do: IO.puts(:stderr, "[#{format_elapsed(elapsed(t0))}] " <> line)
  defp debug(line), do: if(System.get_env("SERENA_SMOKE_DEBUG"), do: IO.puts(:stderr, "    " <> line))

  defp format_elapsed(ms) when ms < 1000, do: "#{ms}ms"
  defp format_elapsed(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  defp die(reason) do
    IO.puts(:stderr, "serena-mcp-smoke: " <> reason)
    System.halt(1)
  end
end

SerenaSmoke.main(System.argv())
