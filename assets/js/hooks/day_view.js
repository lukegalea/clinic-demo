/**
 * Day view hooks — the thin bridge between the NB components
 * (nb-calendar, nb-sheet from ash_a2ui's priv/js) and this LiveView.
 *
 * The components own their behavior and emit composed events; the hooks
 * only translate them into LiveView pushes. Nothing else lives here — the
 * moment a hook grows logic, that logic belongs in the component.
 */

/**
 * Forwards the calendar's composed events:
 *   nb-select {date}        → "select_day"   (a day was picked)
 *   nb-month-change {month} → "select_month" (the grid paged months)
 */
export const DayCalendar = {
  mounted() {
    this.onSelect = (event) => this.pushEvent("select_day", {date: event.detail.date});
    this.onMonth = (event) => this.pushEvent("select_month", {month: event.detail.month});
    this.el.addEventListener("nb-select", this.onSelect);
    this.el.addEventListener("nb-month-change", this.onMonth);
  },

  destroyed() {
    this.el.removeEventListener("nb-select", this.onSelect);
    this.el.removeEventListener("nb-month-change", this.onMonth);
  },
};

/**
 * The sheet closes ITSELF client-side (Escape, backdrop — instant, zero
 * roundtrip) and emits a cancelable nb-close. This hook lets it happen and
 * tells the server to drop the assign, so the next patch agrees with the
 * DOM instead of re-opening the panel the user just dismissed.
 */
export const DaySheet = {
  mounted() {
    this.onClose = (event) => {
      if (event.defaultPrevented) return;
      this.pushEvent("close_detail", {});
    };
    this.el.addEventListener("nb-close", this.onClose);
  },

  destroyed() {
    this.el.removeEventListener("nb-close", this.onClose);
  },
};
