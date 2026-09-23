// Host-side combobox instrumentation hook, per the sketch in
// AshA2ui.Combobox's moduledoc (deps/ash_a2ui/lib/ash_a2ui/combobox.ex).
//
// The catalog's <ash-a2ui-column> element does the actual combobox
// enhancement — its detectPicker keys on the extension's frozen id
// contract (context_<name>_body / form_select_<field> and the
// _label/_selected/_options/_option_button/_search_input/_search_button/
// _clear_button descendants). This hook only OBSERVES the composite: it
// reads the data-ash-a2ui-combobox-* attributes a host element is given
// (from AshA2ui.Combobox.data_attrs/1), resolves the ids they name, and
// reports what it found — the seam for focus hand-off, analytics, or a
// host-side affordance next to the picker. It never enhances anything
// itself; a composite that does not fully match the contract is left to
// the catalog's plain column rendering.
//
// data-ash-a2ui-combobox-* reads back through the standard camelCase
// dataset conversion, e.g. data-ash-a2ui-combobox-body-id is
// dataset.ashA2uiComboboxBodyId.
export const AshA2uiCombobox = {
  mounted() {
    const {
      ashA2uiCombobox: kind,
      ashA2uiComboboxName: name,
      ashA2uiComboboxBodyId: bodyId,
      ashA2uiComboboxLabelId: labelId,
      ashA2uiComboboxSelectedId: selectedId,
      ashA2uiComboboxOptionsId: optionsId,
      ashA2uiComboboxOptionButtonId: optionButtonId,
      ashA2uiComboboxClearButtonId: clearButtonId,
      ashA2uiComboboxSearchInputId: searchInputId,
      ashA2uiComboboxSearchButtonId: searchButtonId,
      ashA2uiComboboxOptionsPath: optionsPath,
    } = this.el.dataset

    if (!kind || !name || !bodyId) return

    this.combobox = {
      kind,
      name,
      optionsPath,
      body: document.getElementById(bodyId),
      label: labelId && document.getElementById(labelId),
      selected: selectedId && document.getElementById(selectedId),
      options: optionsId && document.getElementById(optionsId),
      optionButton: optionButtonId && document.getElementById(optionButtonId),
      clearButton: clearButtonId && document.getElementById(clearButtonId),
      searchInput: searchInputId && document.getElementById(searchInputId),
      searchButton: searchButtonId && document.getElementById(searchButtonId),
    }

    // The composite may hydrate after this hook mounts (the surface
    // bootstrap is async), so re-resolve on the next tick as well.
    if (!this.combobox.body) {
      setTimeout(() => {
        if (this.combobox) this.combobox.body = document.getElementById(bodyId)
      }, 0)
    }
  },

  updated() {
    // LiveView re-renders of the surrounding chrome do not re-run mounted;
    // keep the resolution honest.
    if (this.combobox && !this.combobox.body) {
      const bodyId = this.el.dataset.ashA2uiComboboxBodyId
      if (bodyId) this.combobox.body = document.getElementById(bodyId)
    }
  },

  destroyed() {
    this.combobox = null
  },
}
