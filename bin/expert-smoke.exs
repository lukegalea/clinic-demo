# Does the Expert binary Serena will drive actually answer?
#
# Serena's Elixir backend is Expert: it launches `expert --stdio` with this
# repository as the working directory and asks it for document symbols. That
# is the whole seam, and it is the part of the wiring that can be checked
# without a client session -- so this script is exactly that conversation, by
# hand: initialize, initialized, didOpen, textDocument/documentSymbol.
#
#     ELIXIR_BIN_DIR=... elixir bin/expert-smoke.exs
#     elixir bin/expert-smoke.exs ~/.local/bin/expert lib/clinic_demo/rules.ex
#
# Exit 0 and a list of symbols means Serena's find_symbol has something to
# find. A crash or an empty list on a file with modules in it means it does
# not, and no amount of Serena configuration will fix that.
#
# Requires OTP 27 or newer for :json. Requires `mix compile` to have been run
# first -- Expert indexes the build, not the source.

defmodule ExpertSmoke do
  # Expert compiles the project on first contact. That is slow, and it is
  # slow for Serena too: this timeout is the honest one, not an optimistic one.
  @timeout_ms 300_000

  # How long to keep asking for symbols before calling it a failure.
  @symbol_attempts 12
  @symbol_interval_ms 10_000

  def main(argv) do
    root = Path.expand("..", __DIR__)

    {binary, file} =
      case argv do
        [] -> {default_binary(), "lib/clinic_demo/scheduling/appointment.ex"}
        [binary] -> {binary, "lib/clinic_demo/scheduling/appointment.ex"}
        [binary, file | _] -> {binary, file}
      end

    binary = resolve!(binary)
    path = Path.join(root, file)
    unless File.exists?(path), do: die("no such file: #{path}")

    log("binary   #{binary}")
    log("root     #{root}")
    log("file     #{file}")

    port =
      Port.open({:spawn_executable, binary}, [
        {:args, ["--stdio"]},
        {:cd, root},
        :binary,
        :exit_status
      ])

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        # :json renders the atom nil as the string "nil"; LSP wants null.
        "processId" => :null,
        "rootUri" => "file://" <> root,
        "capabilities" => %{
          "window" => %{"workDoneProgress" => true},
          "textDocument" => %{
            "documentSymbol" => %{"hierarchicalDocumentSymbolSupport" => true}
          }
        },
        "workspaceFolders" => [%{"uri" => "file://" <> root, "name" => "clinic_demo"}]
      }
    })

    log("initialize sent, waiting (Expert compiles the project on first contact)")
    {:ok, _result, buffer} = await_response(port, 1, "")
    log("initialize ok")

    notify(port, "initialized", %{})

    notify(port, "textDocument/didOpen", %{
      "textDocument" => %{
        "uri" => "file://" <> path,
        "languageId" => "elixir",
        "version" => 1,
        "text" => File.read!(path)
      }
    })

    # Expert answers documentSymbol with null until its engine has finished
    # indexing the project, and it does not announce when that is. This is the
    # same wait Serena builds in for Elixir, and the reason its own number is
    # ten seconds rather than zero: ask again rather than concluding the file
    # has no symbols in it.
    {names, _buffer} = poll_symbols(port, "file://" <> path, buffer, 2, @symbol_attempts)
    Port.close(port)

    if names == [] do
      die("documentSymbol returned no symbols for #{file} after #{@symbol_attempts} attempts")
    end

    log("documentSymbol returned #{length(names)} top-level symbol(s):")
    Enum.each(names, &log("  " <> &1))
    log("OK")
  end

  defp poll_symbols(port, uri, buffer, id, attempts_left) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "textDocument/documentSymbol",
      "params" => %{"textDocument" => %{"uri" => uri}}
    })

    {:ok, result, buffer} = await_response(port, id, buffer)

    names =
      case result do
        :null -> []
        list when is_list(list) -> Enum.map(list, &symbol_name/1)
        other -> [symbol_name(other)]
      end

    cond do
      names != [] ->
        {names, buffer}

      attempts_left <= 1 ->
        {[], buffer}

      true ->
        log("documentSymbol is still empty; waiting #{div(@symbol_interval_ms, 1000)}s (#{attempts_left - 1} left)")
        Process.sleep(@symbol_interval_ms)
        poll_symbols(port, uri, buffer, id + 1, attempts_left - 1)
    end
  end

  defp symbol_name(%{"name" => name, "children" => children}) when is_list(children),
    do: "#{name} (#{length(children)} children)"

  defp symbol_name(%{"name" => name}), do: name
  defp symbol_name(other), do: inspect(other)

  defp default_binary do
    System.get_env("EXPERT_BIN") || System.find_executable("expert") ||
      die("no `expert` on PATH; pass one as the first argument or set EXPERT_BIN")
  end

  defp resolve!(binary) do
    expanded = Path.expand(binary)

    cond do
      File.exists?(expanded) -> expanded
      found = System.find_executable(binary) -> found
      true -> die("not executable: #{binary}")
    end
  end

  # --- LSP framing -------------------------------------------------------

  defp send_message(port, message) do
    body = IO.iodata_to_binary(:json.encode(message))
    Port.command(port, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
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
            die("server returned an error: #{inspect(error)}")

          # A request from the server. Expert sends these -- progress
          # creation, capability registration -- and waits for an answer
          # before it will get on with indexing. An LSP client that ignores
          # them looks, from the outside, exactly like a hang.
          %{"id" => other_id, "method" => method} ->
            debug("<- request #{method} (##{other_id}), replying null")
            send_message(port, %{"jsonrpc" => "2.0", "id" => other_id, "result" => :null})
            await_response(port, id, rest)

          %{"method" => method} ->
            debug("<- #{method}")
            await_response(port, id, rest)

          _other ->
            await_response(port, id, rest)
        end

      :more ->
        receive do
          {^port, {:data, data}} -> await_response(port, id, buffer <> data)
          {^port, {:exit_status, status}} -> die("expert exited with status #{status}")
        after
          @timeout_ms -> die("no response to request #{id} within #{div(@timeout_ms, 1000)}s")
        end
    end
  end

  defp take_message(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, rest] ->
        length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(fn header ->
            case String.split(header, ":", parts: 2) do
              ["Content-Length", value] -> String.trim(value) |> String.to_integer()
              _ -> nil
            end
          end)

        if length && byte_size(rest) >= length do
          <<body::binary-size(length), remainder::binary>> = rest
          {:ok, body, remainder}
        else
          :more
        end

      _ ->
        :more
    end
  end

  defp log(line), do: IO.puts(:stderr, line)

  # Every message the server sends, when you need to see why nothing is
  # happening: EXPERT_SMOKE_DEBUG=1 elixir bin/expert-smoke.exs
  defp debug(line) do
    if System.get_env("EXPERT_SMOKE_DEBUG"), do: log(line)
  end

  defp die(reason) do
    IO.puts(:stderr, "expert-smoke: " <> reason)
    System.halt(1)
  end
end

ExpertSmoke.main(System.argv())
