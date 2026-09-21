# The never-opened-document case, by hand.
#
# The rc.6 release Serena would download crashes with a FunctionClauseError in
# Expert.EngineApi.document_symbols/2 when asked for the symbols of a document
# it cannot resolve -- which is every file Serena indexes without opening
# first; its own test suite carries an xfail for it. The fork this repository
# installs (commit 537338b) answers honestly instead. This script is the
# proof, in the order that makes it honest:
#
#   1. initialize, initialized, then `didOpen` one file and poll
#      `documentSymbol` until it answers with symbols -- which is how a client
#      knows the engine has finished indexing (it does not announce it);
#   2. only then ask `documentSymbol` for a file that exists but was never
#      opened -- and for a path that does not exist at all -- and record what
#      comes back, server still up;
#   3. ask again for the file that WAS opened, proving the answers in (2) were
#      about the documents, not about a server falling over.
#
#     elixir docs/evidence/bin/expert-unopened.exs ~/.local/bin/expert
#
# Run bin/expert-smoke.exs first if the index cache may be cold: this script
# assumes a compile that matches the source, and a stale `.expert` index makes
# every answer slow rather than wrong. Same framing rules as
# bin/expert-smoke.exs: LSP Content-Length framing over stdio, and
# server->client requests (capability registration, progress) are answered,
# because Expert waits for them and an ignoring client looks exactly like a
# hang.

defmodule ExpertUnopened do
  # Honest, not optimistic: first contact indexes the project.
  @timeout_ms 240_000
  @symbol_attempts 12
  @symbol_interval_ms 10_000

  def main(argv) do
    binary =
      case argv do
        [binary | _] -> Path.expand(binary)
        [] -> System.find_executable("expert") || die("no expert on PATH; pass one")
      end

    File.exists?(binary) || die("not executable: #{binary}")

    root = Path.expand("../../..", __DIR__)
    opened = Path.join(root, "lib/clinic_demo/scheduling/appointment.ex")
    # A real file in the repository -- but one this client never didOpen's.
    unopened = Path.join(root, "lib/clinic_demo/rules.ex")
    # And one that does not exist anywhere.
    nonexistent = Path.join(root, "lib/clinic_demo/no/such/module.ex")

    log("binary       #{binary}")
    log("root         #{root}")
    log("opened       #{opened}")
    log("unopened     #{unopened}")
    log("nonexistent  #{nonexistent}")

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

    log("initialize sent (Expert compiles/indexes on first contact)")
    {:ok, _, buffer} = await_response(port, 1, "")
    log("initialize ok")
    notify(port, "initialized", %{})

    # Step 1: open one file and wait until the engine has indexed. documentSymbol
    # answers null, not an error, until indexing finishes.
    notify(port, "textDocument/didOpen", %{
      "textDocument" => %{
        "uri" => "file://" <> opened,
        "languageId" => "elixir",
        "version" => 1,
        "text" => File.read!(opened)
      }
    })

    log("-- didOpen #{Path.relative_to(opened, root)}; polling documentSymbol until symbols return (indexing done)")
    {names, buffer} = poll_symbols(port, "file://" <> opened, buffer, 2, @symbol_attempts)
    names != [] || die("documentSymbol never returned symbols for the opened file")
    log("indexing complete: #{length(names)} top-level symbol(s) for the opened file")

    # Step 2: now the never-opened and the nonexistent documents.
    {buffer, _} = ask(port, "unopened (exists, never didOpen'd)", unopened, buffer, 4)
    {buffer, _} = ask(port, "nonexistent path", nonexistent, buffer, 5)

    # Step 3: the opened file answers again -- same server, still up.
    {_, _} = ask(port, "opened again (server health check)", opened, buffer, 6)

    Port.close(port)
    log("OK")
  end

  defp ask(port, label, path, buffer, id) do
    log("-- documentSymbol #{label}: #{path}")

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "textDocument/documentSymbol",
      "params" => %{"textDocument" => %{"uri" => "file://" <> path}}
    })

    case await_response(port, id, buffer) do
      {:ok, result, rest} ->
        log("   <- result: " <> encode(result))
        {rest, id + 1}

      {:error, error, rest} ->
        log("   <- structured error (server still up): " <> encode(error))
        {rest, id + 1}
    end
  end

  defp poll_symbols(port, uri, buffer, id, attempts_left) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "textDocument/documentSymbol",
      "params" => %{"textDocument" => %{"uri" => uri}}
    })

    case await_response(port, id, buffer) do
      {:ok, result, rest} ->
        names =
          case result do
            :null -> []
            list when is_list(list) -> Enum.map(list, &symbol_name/1)
          end

        cond do
          names != [] ->
            {names, rest}

          attempts_left <= 1 ->
            {[], rest}

          true ->
            log("   documentSymbol null; waiting #{div(@symbol_interval_ms, 1000)}s (#{attempts_left - 1} left)")
            Process.sleep(@symbol_interval_ms)
            poll_symbols(port, uri, rest, id + 1, attempts_left - 1)
        end

      {:error, error, _rest} ->
        die("opened file got an error: " <> :json.encode(error))
    end
  end

  defp symbol_name(%{"name" => name, "children" => children}) when is_list(children),
    do: "#{name} (#{length(children)} children)"

  defp symbol_name(%{"name" => name}), do: name
  defp symbol_name(other), do: inspect(other)

  # --- LSP framing ---------------------------------------------------------

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
          %{"id" => ^id, "result" => result} -> {:ok, result, rest}
          %{"id" => ^id, "error" => error} -> {:error, error, rest}

          %{"id" => other_id, "method" => _method} ->
            send_message(port, %{"jsonrpc" => "2.0", "id" => other_id, "result" => :null})
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

  # :json.encode/1 returns iodata; string concatenation wants a binary.
  defp encode(term), do: IO.iodata_to_binary(:json.encode(term))

  defp log(line), do: IO.puts(:stderr, line)

  defp die(reason) do
    IO.puts(:stderr, "expert-unopened: " <> reason)
    System.halt(1)
  end
end

ExpertUnopened.main(System.argv())
