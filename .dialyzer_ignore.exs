[
  # Injected by `use AshBpmn.Web.DesignerLive` at the `use` site: the
  # macro's optional {m, f, a} catalogue clauses (decisions / actions /
  # decision_editor) match against the nil this host never passes, and the
  # expansion yields the finding twice. The wrapper is the same three-line
  # shape the VPM spike mounts; the finding belongs to the framework's
  # expansion, not to this app's code. Track it upstream — and note the
  # sibling repos run dialyzer non-blocking for exactly this Spark/Ash
  # macro-noise class.
  {"lib/clinic_demo_web/live/bpmn/designer_live.ex", :pattern_match}
]
