defmodule ClinicDemo.SystemOneSpike.Transport do
  @moduledoc """
  Labelled record/replay for the TypeSafe wire, at the HTTP layer (DEC-REPLAY).

  This is a Plug that Req runs in place of the network when a model spec
  carries `req_http_options: [plug: {Transport, opts}]`
  (`ClinicDemo.SystemOneSpike.Models`). ReqLLM's TypeSafe provider still
  builds, encodes and decodes every request, so a replayed or stubbed run
  exercises the same code as a live one. Only the bytes on the wire are
  substituted.

  It is **not** a TypeSafe client. In `:record` mode it forwards the request
  body unchanged to the real Ollaya and writes down both sides. It does not
  know the wire format beyond "JSON in, JSON out".

  ## Modes

    * `:record` — forward to `upstream`, answer with what it said, and append
      the exchange to the set with provenance `"recorded"`.
    * `:replay` — answer from the set. A request with no recorded exchange is
      answered with status 599 and a body that says so. It never falls back to
      a live call.
    * `:stub` — answer with `ClinicDemo.SystemOneSpike.Stub`, provenance
      `"stub"`. With `record_stub?: true` in the options it also writes the
      exchange, which is how the committed stub set is produced.

  ## Fixtures

  A set is one JSONL file under `priv/fixtures/system_one/spike0/replay/`.
  Each line is one exchange. `key` hashes the decoded request body (model,
  state and questions) with map keys sorted, so a changed question or state is
  a fixture miss rather than a stale answer. `tag` separates repeats of the
  same request (`r1`, `r2`, `r3`, `cold`), so replay reproduces run-to-run
  variance instead of flattening it.

  **Nothing secret is written.** Request headers, including `authorization`,
  are never recorded. The upstream URL is never recorded.

  ## Telemetry

  Every exchange emits `[:clinic_demo, :system_one_spike, :exchange]` with
  `%{latency_us: n}` and the key, tag, provenance, status and model. In replay,
  `latency_us` is the latency recorded from the live model, which is what the
  runner reports. Req runs the plug in the calling process, so a handler can
  attribute the exchange to the action call that caused it.
  """

  @behaviour Plug

  alias ClinicDemo.SystemOneSpike.Stub

  @fixture_dir "priv/fixtures/system_one/spike0/replay"
  @placeholder "http://spike0-transport.invalid"
  @event [:clinic_demo, :system_one_spike, :exchange]

  @doc "The base URL model specs carry when this plug answers. It is never dialled."
  def placeholder_base_url, do: @placeholder

  @doc "The telemetry event name."
  def event, do: @event

  @doc "Path of a fixture set."
  def fixture_path(set) when is_binary(set) do
    unless Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]*\z/, set) do
      raise ArgumentError, "fixture set names are lower-case [a-z0-9_.-], got #{inspect(set)}"
    end

    Path.join(fixture_dir(), set <> ".jsonl")
  end

  # The source tree, not _build: fixtures are committed, and the spike runs
  # from the project root (mix task and tests alike).
  defp fixture_dir, do: Path.join(File.cwd!(), @fixture_dir)

  @impl Plug
  def init(opts), do: Map.new(opts)

  @impl Plug
  def call(conn, opts) do
    request = decode_request(conn)
    key = key(request)
    tag = Map.get(opts, :tag, "r1")

    {status, body, provenance, latency_us} =
      case opts.mode do
        :record -> forward(conn, opts, request, key, tag)
        :replay -> replay(opts.set, key, tag)
        :stub -> stub(opts, request, key, tag)
      end

    :telemetry.execute(@event, %{latency_us: latency_us}, %{
      key: key,
      tag: tag,
      provenance: provenance,
      status: status,
      model: request["model"],
      response: body
    })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, encode(body))
  end

  @doc "The stable key for a decoded request body."
  def key(request) do
    :crypto.hash(:sha256, JSON.encode!(canonical(request))) |> Base.encode16(case: :lower)
  end

  # ── modes ────────────────────────────────────────────────────────────────

  defp forward(conn, opts, request, key, tag) do
    started = System.monotonic_time(:microsecond)

    headers =
      Enum.filter(conn.req_headers, fn {name, _} -> name in ["authorization", "content-type"] end)

    reply =
      Req.post(opts.upstream <> conn.request_path,
        body: Req.Test.raw_body(conn),
        headers: headers,
        receive_timeout: Map.get(opts, :receive_timeout, 120_000),
        retry: false,
        decode_body: false
      )

    latency_us = System.monotonic_time(:microsecond) - started

    {status, body} =
      case reply do
        {:ok, %Req.Response{status: status, body: body}} -> {status, decode(body)}
        {:error, exception} -> {599, %{"transport_error" => Exception.message(exception)}}
      end

    append(opts.set, entry(key, tag, request, status, body, "recorded", latency_us))
    {status, body, "recorded", latency_us}
  end

  defp replay(set, key, tag) do
    entries = load(set)

    case Map.get(entries, {key, tag}) || Map.get(entries, {key, :any}) do
      nil ->
        {599,
         %{
           "replay_miss" =>
             "no recorded exchange for request #{key} (tag #{tag}) in #{fixture_path(set)}; " <>
               "the question, state or model changed since it was recorded, so re-record it"
         }, "replay-miss", 0}

      entry ->
        {entry["status"], entry["response"], entry["provenance"], entry["latency_us"] || 0}
    end
  end

  defp stub(opts, request, key, tag) do
    {status, body} = Stub.reply(request, tag)

    if Map.get(opts, :record_stub?, false) do
      append(opts.set, entry(key, tag, request, status, body, "stub", 0))
    end

    {status, body, "stub", 0}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp entry(key, tag, request, status, response, provenance, latency_us) do
    %{
      "key" => key,
      "tag" => tag,
      "model" => request["model"],
      "provenance" => provenance,
      "ollaya_version" => System.get_env("S1_OLLAYA_VERSION"),
      "request" => request,
      "status" => status,
      "response" => response,
      "latency_us" => latency_us,
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp append(set, entry) do
    path = fixture_path(set)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(entry) <> "\n", [:append])
    :persistent_term.erase({__MODULE__, set})
  end

  @doc "Drops the cached copy of a set, after it is rewritten on disk."
  def forget(set), do: :persistent_term.erase({__MODULE__, set})

  @doc false
  def load(set) do
    case :persistent_term.get({__MODULE__, set}, nil) do
      nil ->
        entries = read_set(set)
        :persistent_term.put({__MODULE__, set}, entries)
        entries

      entries ->
        entries
    end
  end

  # Each exchange is indexed by {key, tag} and, for the first one seen, by
  # {key, :any}: a repeat recorded fewer times than it is replayed is answered
  # with the first recording rather than a miss.
  defp read_set(set) do
    case File.read(fixture_path(set)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.reduce(%{}, fn entry, acc ->
          acc
          |> Map.put({entry["key"], entry["tag"]}, entry)
          |> Map.put_new({entry["key"], :any}, entry)
        end)

      {:error, _} ->
        %{}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp decode_request(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> decode(Req.Test.raw_body(conn))
      params when map_size(params) > 0 -> params
      _ -> decode(Req.Test.raw_body(conn))
    end
  end

  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => body}
    end
  end

  defp decode(body), do: body

  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: JSON.encode!(body)

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> [to_string(k), canonical(v)] end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other
end
