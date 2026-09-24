# Maximalist IDE Architecture for Ash, Serena, and Tidewave

## Executive answer

The strongest setup is **VS Code Insiders as the human IDE, connected to Linux (preferably Remote SSH into the Ubuntu VM, optionally followed by Reopen in Container), with ElixirLS as the editor language server, Serena running its own Expert index, Ash Studio for DSL-aware navigation, Tidewave attached to the running Phoenix node, and `ash_agent_tools` exposed both in-VM through Tidewave and through its compile-only daemon**.

The key is not choosing one intelligence engine. It is deliberately running four complementary navigation planes:

1. **ElixirLS** for human editor navigation, Spark/Ash DSL completion, debugger support, diagnostics, and tests.
2. **Serena + Expert** for symbol-level agent navigation and structured edits.
3. **`ash_agent_tools`** for Ash-native entities that neither a generic AST nor an LSP fully understands: resources, actions, inputs, policies, state transitions, BPMN, DMN, source-position context, and semantic name paths.
4. **Tidewave** for runtime truth, dependency-version-correct docs, module/function source locations, logs, SQL, and browser-element-to-source tracing.

This division matters because Spark's enhanced Ash DSL completion is currently specific to ElixirLS, while Serena's official Elixir integration uses Expert. Trying to force one language server to own both jobs loses capability; keeping the indexes separate avoids duplicate editor diagnostics while retaining both strengths.[^1]

## Recommended topology

```text
Windows desktop
┌──────────────────────────────────────────────────────────────┐
│ VS Code Insiders UI                                          │
│ Browser: Phoenix app + Tidewave Toolbar                      │
│ Optional: WezTerm / Windows Terminal                         │
└──────────────────────── SSH ─────────────────────────────────┘
                             │
Ubuntu development VM
┌──────────────────────────────────────────────────────────────┐
│ VS Code Server / remote extension host                       │
│   ├─ ElixirLS: editor-only LSP + DAP                         │
│   ├─ Ash Studio: Ash DSL outline/navigation                  │
│   ├─ Mermaid preview                                         │
│   └─ Git, test, diagnostics and task extensions              │
│                                                              │
│ Optional dev container, with one canonical workspace path    │
│   ├─ Phoenix + Ash app on :4000                              │
│   │    └─ Tidewave MCP at /tidewave/mcp                      │
│   ├─ Serena + its own Expert process                         │
│   ├─ ash_agent_tools compile-only daemon on :4100            │
│   ├─ Serena dashboard on :24282                              │
│   ├─ Postgres / services                                     │
│   └─ Livebook or attached IEx                                │
└──────────────────────────────────────────────────────────────┘
```

VS Code Remote SSH installs its server on the remote machine and runs workspace extensions and commands beside the remote files. That is the correct locality for ElixirLS, Mix, Serena, Tidewave, and the Ash semantic daemon; keeping those components on the same Linux filesystem prevents Windows/Linux path translation and version drift.[^2][^3]

### Network exposure

Forward only loopback-bound development ports through the IDE/SSH connection:

| Port | Service | Exposure |
|---|---|---|
| `4000` | Phoenix and Tidewave MCP | SSH/IDE forwarded only |
| `4100` | `mix ash_agent.serve` | Loopback only |
| `24282` | Serena dashboard | Loopback only |
| `8080` or configured port | Livebook, if used | Loopback plus token auth |

Tidewave's official setup points clients to the running Phoenix application's `/tidewave/mcp` endpoint and notes additional networking considerations when Docker changes what “localhost” means.[^4] The `ash_agent_tools` daemon is intentionally loopback-only and unauthenticated, so it should never be published through a LAN reverse proxy or production ingress.

## Why VS Code wins

| Criterion | VS Code Insiders | JetBrains + Gateway | Neovim | Zed |
|---|---|---|---|---|
| Ash-specific human navigation | **Best:** Ash Studio sidebar, outline, section search, Mermaid CodeLens[^5] | No equivalent verified | Must be custom-built | No equivalent verified |
| Ash DSL completion | **ElixirLS + Spark plugin**[^1] | Plugin-dependent | ElixirLS works, but manual setup | Multiple LSP choices, but ElixirLS still needed for Spark completion |
| Remote Ubuntu workflow | **Mature Remote SSH and containers**[^2][^3] | Strong Gateway backend over SSH[^6][^7] | Excellent over terminal SSH | Less suitable for this remote/container stack |
| Elixir debugging | ElixirLS VS Code integration exposes full language-server/debugger functionality[^8] | Plugin-dependent | Possible through `nvim-dap`, more assembly required | LSP-oriented |
| Serena fit | Standard MCP client pattern; separate Expert index | Potentially strongest Serena backend through the JetBrains plugin, but more moving parts | Excellent terminal-agent pairing | Good LSP host |
| Maximalist extensibility | **Best overall combination** | Best alternative if Serena's JetBrains backend is the top priority | Best keyboard-first alternative | Cleanest lightweight alternative |

The winner is therefore **VS Code Insiders**, not because it has the strongest generic indexer, but because it is the only option in this comparison with a verified Ash-specific navigation extension plus mature remote-host execution and ElixirLS's full VS Code feature surface.[^5][^2][^9]

### JetBrains exception

JetBrains becomes attractive if the primary objective shifts from *human Ash navigation* to *maximal Serena semantic power*. Serena offers a JetBrains-backed alternative to its LSP backend, and JetBrains Gateway runs the IDE backend on the remote Linux machine over SSH.[^10][^6][^11] However, the absence of an equivalent to Ash Studio and uncertainty around Spark DSL-aware completion make it the secondary workstation, not the primary recommendation.

A genuinely maximal setup could keep a JetBrains EAP/Gateway profile available for difficult cross-language refactors while using VS Code Insiders for day-to-day Ash work. Both should not write the same tree simultaneously during refactors.

## Language-server strategy

### Human editor: ElixirLS

Use **ElixirLS only inside the editor**. Ash's development documentation says Spark's DSL and option-list completion is automatically picked up by ElixirLS and does not work with other language servers.[^1] ElixirLS also supplies the Debug Adapter Protocol, test lenses, auto-build, incremental Dialyzer options, references, definitions, and diagnostics.[^8][^9]

Recommended workspace settings:

```jsonc
{
  "elixirLS.autoBuild": true,
  "elixirLS.dialyzerEnabled": true,
  "elixirLS.incrementalDialyzer": true,
  "elixirLS.fetchDeps": false,
  "elixirLS.enableTestLenses": true,
  "elixirLS.mixEnv": "test",
  "elixirLS.mixTarget": "host",
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll": "explicit"
  },
  "files.watcherExclude": {
    "**/_build/**": true,
    "**/deps/**": true,
    "**/.elixir_ls/**": true,
    "**/cover/**": true
  },
  "search.exclude": {
    "**/_build": true,
    "**/deps": true,
    "**/.elixir_ls": true,
    "**/cover": true
  }
}
```

Keep dependency fetching outside the LSP and run it explicitly in bootstrap tasks. ElixirLS documents `fetchDeps`, auto-build, Dialyzer, and test-lens controls; explicit dependency management also avoids indexer/build races.[^9][^12]

### Serena: Expert

Let Serena launch **its own Expert process**, rather than enabling the Expert VS Code extension beside ElixirLS. Serena's official integration downloads Expert if needed, runs it with `expert --stdio`, ignores `_build`, `deps`, `.elixir_ls`, and `cover`, and recommends compiling the project first for complete cross-file references and symbol information.

This creates two non-conflicting indexes:

- ElixirLS speaks to VS Code and knows Spark's completion plugin.
- Expert speaks to Serena and provides its symbol graph.

Do not enable both the ElixirLS and Expert editor extensions in the same VS Code workspace. That produces duplicate completion, diagnostics, formatting, and build traffic without improving Ash DSL semantics. If Expert needs direct human evaluation, create a separate VS Code Profile named `Elixir Expert Lab`, or use Zed, which can switch explicitly among Expert, ElixirLS, Next LS, Dexter, and Lexical.[^13][^14]

### Version pinning

Pin all of the following as project infrastructure, not workstation state:

- Elixir and OTP in `.tool-versions` or `mise.toml`.
- Node and Mermaid CLI for diagrams.
- Serena version or Git revision.
- Expert version in Serena configuration when reproducibility matters.
- Extension recommendations in `.vscode/extensions.json`.
- Container image digest or devcontainer feature versions.

Serena supports an `expert_version` override and otherwise manages its own Expert download.[^15] A controlled pin is preferable for a long-lived enterprise codebase; a scheduled “bleeding edge” profile can track Serena main and Expert nightly separately from the stable daily-driver profile.

## Human Ash navigation

### Install Ash Studio

Ash Studio supplies four human-facing features that generic LSP navigation does not: an Ash section sidebar, quick section search, document-outline integration, and Mermaid diagram CodeLens. It recognizes core resource/domain sections and a set of Ash ecosystem extensions including AshAuthentication, AshGraphql, AshJsonApi, AshPostgres, and AshAdmin.[^5]

Use its sidebar as the intra-file view and ElixirLS as the inter-file view:

- `Go to Ash Section` for movement within a resource.
- VS Code workspace symbol search for modules and ordinary functions.
- `Go to Definition` and `Find References` for code interfaces, modules, and callable functions.
- `ash_agent_tools` for attributes, actions, policies, relationships, transitions, BPMN elements, DMN decisions, and custom Spark entities.

### Add an Ash Navigator extension

The maximalist setup should add a thin, non-AI VS Code extension over `ash_agent_tools`. This is the largest missing piece in the current ecosystem. The repository already exposes the semantic operations and stable name paths; the extension only needs to turn JSON into standard VS Code providers.

Recommended provider mapping:

| VS Code surface | `ash_agent_tools` operation | Result |
|---|---|---|
| Tree View | `list_domains`, `list_resources`, `describe_resource` | Domain → resource → action/relationship/policy hierarchy |
| Workspace Symbol Provider | `semantic_search` | Ash entities appear in `Ctrl+T` alongside normal symbols |
| Definition Provider | `resolve` or search result source location | Jump from an Ash entity name/path to its declaration |
| Reference Provider | `context` / `resolve` references | Actions accepting an attribute, interfaces calling an action, relationships using a field |
| Hover Provider | `describe_action`, `describe_resource` | Inputs, types, constraints, return shape, code interfaces |
| CodeLens | `can`, `explain_forbidden`, transitions/diagrams | Policy and transition affordances above DSL entities |
| Code Action | semantic edit dry-run | Preview a safe DSL-native edit before applying it |
| Virtual Document | trace/runtime/process/decision report | Readable, refreshable JSON/Markdown views |
| Status Bar | `ash_daemon_status`, `availability` | Reload state and optional integrations |

The extension should use the long-running `mix ash_agent.serve` endpoint for fast compile-only reads, invoke `ash_reload` after save if the watcher misses an event, and open returned `file:line:column` locations with `vscode.open`. The daemon pays the compile cost once, caches descriptions by checksum, watches `lib/` and `config/`, and serializes reloads so navigation cannot race recompilation.

This is more useful than adding another AI feature: it turns the same Ash semantic model used by agents into native **human** IDE primitives.

## Three navigation loops

### Static code loop

Use this order when starting from a symbol or unfamiliar code path:

1. Ash Studio outline for the current resource.
2. ElixirLS definition/reference navigation for ordinary Elixir symbols.
3. Serena for agent-side symbol overview, declaration, implementation, and reference queries.
4. `ash_agent_tools.semantic_search/2` when the concept is an Ash entity rather than a conventional function.
5. `AshAgentTools.context/3` when starting from a file and line.

`ash_agent_tools` can identify the declaring Ash module, matched symbol, nearby symbols, and semantic references at a source position. Its name-path grammar addresses entities such as `MyApp.Post/actions/by_tag`, `MyApp.Post/attributes/title`, and ordinal policies.

### Runtime loop

Use this order for “what is actually loaded and happening?” questions:

1. Tidewave `get_source_location` for a known module/function, including dependency code.
2. Tidewave `get_docs` or package-doc search for APIs matching the exact locked versions.
3. Tidewave `project_eval` to call `AshAgentTools.eval_docs()` and then direct introspection functions in the running node.
4. Tidewave logs/SQL/runtime tools to validate observed behavior.
5. `AshAgentTools.explain_trace/2` plus `Runtime.snapshot/top/tree` for trace and BEAM-state correlation.

Tidewave evaluates code inside the running application and can retrieve source locations and documentation against the project's installed dependency versions.[^16][^4] `ash_agent_tools` explicitly recommends in-VM calls through a running node or Tidewave-style `project_eval` over repeated Mix boots.

### Browser-to-source loop

For UI work, keep the Phoenix application in a browser beside the editor and use Tidewave Toolbar:

1. Inspect the rendered element.
2. Copy the source-enriched prompt/context, even if no AI generation is used.
3. Open the supplied HEEx/component location in VS Code.
4. Use ElixirLS references to trace the component and event handler.
5. Use `ash_context` on the relevant resource/action line.
6. Exercise the flow and inspect logs/runtime state through Tidewave.

Tidewave Toolbar maps inspected DOM elements back to source and includes page, framework entry-point, source-location, and related-reference context.[^17][^18][^19] Even with AI features ignored, this is a high-value navigation bridge between rendered UI and Phoenix source.

## `ash_agent_tools` deployment

Run it in two modes because they answer different operational needs.

### In the Phoenix VM

This is the preferred path while the application is running:

```elixir
AshAgentTools.eval_docs()
AshAgentTools.describe_resource(MyApp.Accounts.User)
AshAgentTools.describe_action(MyApp.Accounts.User, :register)
AshAgentTools.context("lib/my_app/accounts/user.ex", 120)
AshAgentTools.can(MyApp.Accounts.User, :update, actor_spec, params)
```

This path has zero extra Mix boot, sees loaded modules, and can pair static Ash metadata with the running node. `project_eval` is the clean bridge because Tidewave exposes an IEx-like runtime tool inside the application.[^16]

### Compile-only daemon

Start the semantic daemon as a persistent development process:

```bash
mix ash_agent.serve --port 4100
```

Use it for IDE tree views, symbol providers, action hovers, policy inspection, and navigation that must remain available when the Phoenix app is stopped. It compiles and loads configured domains without starting the application, avoiding side effects from queues, projectors, and endpoints.

The daemon should not replace Tidewave:

- The daemon is the **compiled Ash model plane**.
- Tidewave is the **running application plane**.
- Serena is the **generic code-symbol plane**.
- ElixirLS is the **human editing plane**.

## Workspace composition

Recommended repository files:

```text
.devcontainer/
  devcontainer.json
  docker-compose.yml
.vscode/
  extensions.json
  settings.json
  tasks.json
  launch.json
  my_app.code-workspace
.serena/
  project.yml
  memories/
.tool-versions or mise.toml
AGENTS.md
usage-rules.md
```

### Extension set

Keep the extension list intentionally narrow despite the maximalist architecture:

- ElixirLS.
- Ash Studio.
- Remote SSH, Dev Containers, and Remote Explorer.
- Mermaid Markdown Preview or Mermaid editor support.
- GitLens, Error Lens, and a focused test explorer if desired.
- YAML, TOML, JSON, Docker, and PostgreSQL syntax/client support.
- A custom `Ash Navigator` extension over port 4100.

Do **not** install multiple Elixir formatters or multiple active editor language servers. “Maximalist” should mean maximum orthogonal capability, not duplicated ownership.

### Tasks

Add deterministic tasks for the semantic services and common views:

```jsonc
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "dev: phoenix+tidewave",
      "type": "shell",
      "command": "iex -S mix phx.server",
      "isBackground": true,
      "problemMatcher": []
    },
    {
      "label": "dev: ash semantic daemon",
      "type": "shell",
      "command": "mix ash_agent.serve --port 4100",
      "isBackground": true,
      "problemMatcher": []
    },
    {
      "label": "ash: diagrams",
      "type": "shell",
      "command": "mix ash.generate_resource_diagrams --format svg"
    },
    {
      "label": "quality",
      "type": "shell",
      "command": "mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix test"
    }
  ]
}
```

Ash ships a task that generates Mermaid resource diagrams per domain in ER or class form and can emit SVG, PDF, PNG, Markdown, or plain Mermaid text.[^20] Generate SVGs into a disposable workspace directory and surface them through Ash Studio or an IDE webview rather than committing them unless they are architectural documentation.

## Remote versus local Linux

| Topology | Advantages | Costs | Recommendation |
|---|---|---|---|
| Windows → Remote SSH → Ubuntu VM | Keeps source and toolchain off the desktop; matches existing Proxmox model; extensions and commands run remotely[^2] | SSH latency; port forwarding; container/network localhost subtleties | **Best fit for the current architecture** |
| Windows → WSL2 | Lowest latency; simple localhost/browser integration; native Linux toolchain | Development state lives on the desktop; less isolation | Best raw IDE responsiveness |
| Native Linux workstation | Fewest layers and path problems | Requires changing primary desktop workflow | Technical ideal, operationally unnecessary |
| JetBrains Gateway → Ubuntu VM | Strong remote backend/indexing; Serena JetBrains option | Higher resource use and weaker verified Ash-specific UI | Keep as an advanced secondary profile |

For the current Proxmox setup, use **Remote SSH first, then Reopen in Container on the remote host**. VS Code's remote model runs workspace extensions in the environment that owns the files, while the local Windows process remains the UI.[^2][^3] Give the VM enough RAM for two language-server indexes, Mix compilation, Phoenix, Postgres, and optional JetBrains indexing; otherwise the “maximalist” stack will spend its time contending for memory.

### Canonical paths

Use one stable in-container path such as `/workspaces/my_app` for all of:

- ElixirLS workspace root.
- Serena project root.
- Phoenix current directory.
- `ash_agent_tools` source paths.
- Test/debug launch configurations.

The most common integration failure in a multi-plane setup is semantically correct source data carrying a path that the receiving editor cannot open. Avoid bind-mounting the same repository at different paths in different sidecars.

## Bleeding-edge profile

Maintain two profiles rather than making every experiment part of the daily driver.

### Daily driver

- VS Code stable or Insiders pinned to a known build.
- Released ElixirLS.
- Released Ash Studio.
- Pinned Serena revision and Expert release candidate.
- Released Tidewave and `ash_agent_tools` revision.

### Lab profile

- VS Code Insiders.
- Expert nightly through its VS Code extension, with ElixirLS disabled in that profile; the Expert extension supports a nightly channel.[^13]
- Serena main and optional REPL interface; Serena supports both one-tool-per-operation and a newer single REPL tool for composed operations.[^15]
- JetBrains EAP + Serena JetBrains backend.
- Zed with Expert as an independent reference implementation.[^14]

This split makes it possible to compare navigation correctness and latency without destabilizing the Ash DSL completion path.

## Navigation keymap

A practical keyboard model:

| Intent | Binding | Backend |
|---|---|---|
| Definition | `F12` | ElixirLS |
| References | `Shift+F12` | ElixirLS |
| Workspace symbol | `Ctrl+T` | ElixirLS plus Ash symbol provider |
| Ash section | `Ctrl+K A` | Ash Studio |
| Ash entity search | `Ctrl+K S` | `ash_search` QuickPick |
| Context at cursor | `Ctrl+K C` | `ash_context(file, line)` |
| Resource/action details | `Ctrl+K D` | `ash_describe` hover/virtual doc |
| Policy explanation | `Ctrl+K P` | `ash_forbidden` / `ash_can` |
| Resource diagram | `Ctrl+K G` | Ash Mermaid task/webview |
| Open runtime source | `Ctrl+K R` | Tidewave `get_source_location` bridge |
| Test at cursor | CodeLens / shortcut | ElixirLS DAP/test lens |

The important design choice is making **Ash entity search and context-at-cursor first-class editor commands**, rather than relegating them to an agent chat. That is where `ash_agent_tools` can materially improve IDE navigation.

## Implementation sequence

1. **Stabilize locality:** Remote SSH into the Ubuntu VM; optionally reopen in the remote devcontainer; establish one canonical workspace path.
2. **Install ElixirLS and Ash Studio:** verify Spark DSL completion inside `attributes`, `actions`, `relationships`, and policies.
3. **Compile once:** run `mix deps.get`, `mix compile`, and test compilation before starting Serena; Expert's reference quality improves when the project is compiled.
4. **Start Serena separately:** use the IDE-assistant context, retain its own Expert process, and forward the dashboard port if desired; Serena's dashboard exposes configuration, logs, and tool-usage information.[^21][^22]
5. **Mount Tidewave only in development:** connect to `/tidewave/mcp`; verify source, docs, logs, and `project_eval` against the running app.[^16][^4]
6. **Add `ash_agent_tools`:** sync usage rules, confirm `availability/0`, and test direct calls through Tidewave `project_eval`.
7. **Start the compile-only daemon:** verify `ash_daemon_status`, file-watch reload, `ash_search`, and `ash_context` on port 4100.
8. **Build the thin Ash Navigator extension:** begin with QuickPick search and context-at-cursor, then add tree, hover, references, diagrams, and policy views.
9. **Add runtime views:** attached IEx or Livebook, Phoenix LiveDashboard, and `AshAgentTools.Runtime`/trace views.
10. **Create a lab profile:** evaluate Expert nightly, Zed, and Serena's JetBrains backend without touching the daily editor profile.

## Bottom line

The maximal setup is not “the IDE with the most plugins.” It is a **layered semantic workstation**:

- VS Code Insiders is the human shell.
- ElixirLS owns editor intelligence because Ash/Spark completion depends on it.
- Ash Studio owns human DSL structure.
- Serena owns generic symbol-level agent navigation through a separate Expert index.
- `ash_agent_tools` owns the compiled Ash semantic graph and safe name-path operations.
- Tidewave owns runtime truth and browser-to-source context.
- A thin Ash Navigator extension converts `ash_agent_tools` from an agent API into native human IDE navigation.

For this codebase, that final extension is the cutting-edge move: the repository already contains most of the difficult semantic work, including source locations, context, references, stable entity paths, policy explanations, diagrams, and guarded semantic edits. The IDE should become a projection of that model rather than attempting to infer Ash semantics from text alone.

---

## References

1. [ash/documentation/topics/development/development-utilities.md at main · ash-project/ash](https://github.com/ash-project/ash/blob/main/documentation/topics/development/development-utilities.md) - A declarative, extensible framework for building Elixir applications. - ash-project/ash

2. [Remote Development using SSH - Visual Studio Code](https://code.visualstudio.com/docs/remote/ssh) - Developing on Remote Machines or VMs using Visual Studio Code Remote Development and SSH

3. [VS Code Remote Development](https://code.visualstudio.com/docs/remote/remote-overview) - Visual Studio Code Remote Development

4. [Set up Tidewave MCP](https://tidewave.hexdocs.pm/mcp.html)

5. [Ash Studio VS Code Extension](https://marketplace.visualstudio.com/items?itemName=ketupia.ash-studio) - Extension for Visual Studio Code - Ash Studio enhances your workflow by enabling quick navigation be...

6. [Install JetBrains Gateway | IntelliJ IDEA Documentation](https://www.jetbrains.com/help/idea/jetbrains-gateway.html)

7. [Remote development overview | IntelliJ IDEA - JetBrains](https://www.jetbrains.com/help/idea/remote-development-overview.html)

8. [elixir-ls/README.md at master · elixir-lsp/elixir-ls](https://github.com/elixir-lsp/elixir-ls/blob/master/README.md) - A frontend-independent IDE "smartness" server for Elixir. Implements the "Language Server Protocol" ...

9. [elixir-lsp/elixir-ls: A frontend-independent IDE "smartness ... - GitHub](https://github.com/elixir-lsp/elixir-ls) - A frontend-independent IDE "smartness" server for Elixir. Implements the "Language Server Protocol" ...

10. [Language Support — Serena Documentation](https://oraios.github.io/serena/01-about/020_programming-languages.html) - Serena incorporates a powerful abstraction layer for the integration of language servers that implem...

11. [JetBrains Integration | oraios/serena | DeepWiki](https://deepwiki.com/oraios/serena/6.9-jetbrains-integration) - This document covers Serena's alternative backend for semantic code operations that integrates with ...

12. [Installation and Configuration | elixir-lsp/elixir-ls | DeepWiki](https://deepwiki.com/elixir-lsp/elixir-ls/1.2-installation-and-configuration) - This page explains how to install ElixirLS in various editors/IDEs and how to configure it for optim...

13. [Expert LSP](https://marketplace.visualstudio.com/items?itemName=ExpertLSP.expert) - Extension for Visual Studio Code - Elixir language support for Visual Studio Code

14. [Using Next Ls](https://zed.dev/docs/languages/elixir)

15. [Configuration — Serena Documentation](https://oraios.github.io/serena/02-usage/050_configuration.html)

16. [Available Mcp Tools](https://github.com/tidewave-ai/tidewave_phoenix) - MCP server with runtime-level tools for Phoenix development - tidewave-ai/tidewave_phoenix

17. [The future of coding agents is vertical integration (and why ...](https://tidewave.ai/blog/the-future-of-coding-agents-is-vertical-integration) - A look at the limitations of generic agents and MCPs, through the lens of building Tidewave, and wha...

18. [A new way to use Tidewave: from your terminal or editor](https://tidewave.ai/blog/tidewave-connect) - Tidewave adds a small toolbar to every page of your running app. Click an element, write your prompt...

19. [Tidewave Toolbar](https://tidewave.ai/toolbar) - Inspect, debug, and improve your UI with framework-aware context for your coding agent.

20. [mix ash.generate_resource_diagrams — ash v3.32.3](https://hexdocs.pm/ash/Mix.Tasks.Ash.GenerateResourceDiagrams.html) - Generates a Mermaid Resource Diagram for each Ash domain. Prerequisites This mix task requires the M...

21. [The Dashboard and GUI Tool — Serena Documentation](https://oraios.github.io/serena/02-usage/060_dashboard.html) - The dashboard provides detailed information on your Serena session, the current configuration and pr...

22. [serena/README.md at main · oraios/serena · GitHub](https://github.com/oraios/serena/blob/main/README.md) - A powerful coding agent toolkit providing semantic retrieval and editing capabilities (MCP server & ...

