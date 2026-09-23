[
  # Tidewave is declared `runtime: false` (dev-only MCP plug), which keeps it
  # out of dialyxir's PLT app set while endpoint.ex still references the
  # plug — dialyzer therefore reports its call/2 + init/1 as unknown. Both
  # functions exist at deps/tidewave/lib/tidewave.ex (init/1 at :30, call/2
  # at :45) and the plug is exercised end-to-end by the dev-server probes
  # (POST /tidewave/mcp tools/list). If a future dialyxir/dep setup includes
  # runtime-false deps in the PLT, dialyzer will flag these as unnecessary
  # skips and they can go.
  {"lib/clinic_demo_web/endpoint.ex", :unknown_function},
]
