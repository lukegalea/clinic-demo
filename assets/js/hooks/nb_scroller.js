/**
 * NbScroller LiveView hook — stick-to-bottom for the console transcript.
 *
 * The nb_message_scroller renders a stream (phx-update="stream"); new
 * messages arrive as keyed children. The hook keeps the view pinned to the
 * newest message UNLESS the person has scrolled up to read history (more
 * than one message-height away from the bottom) — scroll back to the
 * bottom and pinning resumes. MutationObserver because stream patches
 * replace children without any LiveView event to listen for.
 */
export const NbScroller = {
  mounted() {
    this.pinned = true;

    this.onScroll = () => {
      const nearBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48;
      this.pinned = nearBottom;
    };
    this.el.addEventListener("scroll", this.onScroll, {passive: true});

    this.observer = new MutationObserver(() => {
      if (this.pinned) this.el.scrollTop = this.el.scrollHeight;
    });
    this.observer.observe(this.el, {childList: true, subtree: false});

    this.el.scrollTop = this.el.scrollHeight;
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);
    this.observer?.disconnect();
    this.observer = null;
  },
};

export default NbScroller;
