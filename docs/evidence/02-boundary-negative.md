# 02 — The boundary: an Ash action is not a symbol

The structural claim underneath this repository's two-server wiring, tested
from both sides with the same name: `complete`, the update action on
`ClinicDemo.Scheduling.Appointment`.

## Side one: the language server

`find_symbol` across the whole project — no `relative_path`, so everything the
Elixir backend indexes is in scope:

```
$ elixir docs/evidence/bin/serena-mcp-smoke.exs read    # last call of the run
[36.5s] -> tools/call find_symbol {"name_path_pattern":"complete"}
[37.0s] <- find_symbol complete (the boundary: an Ash action is not a symbol) (486ms)
[]
```

Empty. There is no symbol called `complete` and there cannot be one: in the
source it is an `update :complete do` block, data in a DSL. Expert indexes
compiled modules; the action exists only as introspectable state *inside* the
compiled module. (Full run context in
[`transcripts/serena-read.txt`](transcripts/serena-read.txt); the same run
found `decide` — a function — immediately.)

## Side two: the declarative tool

```
$ bin/ash-agent describe ClinicDemo.Scheduling.Appointment complete --pretty
{
  "input": {
    "private": [],
    "required": [
      "notes"
    ],
    "optional": []
  },
  "name": "complete",
  "type": "update",
  "accept": [],
  "description": "The visit happened. Clinical notes are mandatory.",
  "arguments": [
    {
      "default": null,
      "name": "notes",
      "type": "string",
      "description": "What was found and what was done.",
      "source": {
        "line": 215,
        "file": "/home/lukegalea/capstone-demo/lib/clinic_demo/scheduling/appointment.ex"
      },
      "required?": true,
      "public?": true,
      "allow_nil?": false
    }
  ],
  "resource": "Elixir.ClinicDemo.Scheduling.Appointment",
  "source": {
    "line": 208,
    "file": "/home/lukegalea/capstone-demo/lib/clinic_demo/scheduling/appointment.ex"
  },
  "returns": {
    "type": "Elixir.ClinicDemo.Scheduling.Appointment",
    "kind": "record"
  },
  "code_interfaces": []
}
```

Full transcript: [`transcripts/ash-agent-describe-complete.txt`](transcripts/ash-agent-describe-complete.txt).

Same name, asked of the other tool: the action's type, its description, its
one required argument with its type and its ten-character constraint's home
(`accept: []` — the only way in is the argument), and the file and line to
read next. The language server could not even see the question.

This is the boundary as a rule: **a name, a function, a module, a caller →
Serena. An action, an attribute, an argument, a policy → `bin/ash-agent`.**
Neither tool can answer the other's question, and nothing above was tuned to
make that true — it falls out of what an action *is*.
