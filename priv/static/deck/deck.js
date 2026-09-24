// The deck's navigation: arrow keys (and friends), the HUD buttons, and a
// location hash that survives reloads. No dependencies; CSP-safe.
(() => {
  const deck = document.querySelector("main.deck");
  if (!deck) return;
  const slides = Array.from(deck.querySelectorAll(".slide"));
  const counter = document.querySelector(".deck-hud .counter");
  const prev = document.querySelector(".deck-hud [data-action=prev]");
  const next = document.querySelector(".deck-hud [data-action=next]");
  let index = 0;

  const apply = () => {
    slides.forEach((s, n) => s.classList.toggle("is-active", n === index));
    deck.setAttribute("data-current", String(index + 1));
    if (counter) counter.textContent = (index + 1) + " / " + slides.length;
    history.replaceState(null, "", index === 0 ? location.pathname : "#" + (index + 1));
    if (prev) prev.disabled = index === 0;
    if (next) next.disabled = index === slides.length - 1;
  };

  const go = (n) => {
    index = Math.max(0, Math.min(slides.length - 1, n));
    apply();
  };

  window.addEventListener("keydown", (event) => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    switch (event.key) {
      case "ArrowRight":
      case "PageDown":
      case " ":
        event.preventDefault();
        go(index + 1);
        break;
      case "ArrowLeft":
      case "PageUp":
        event.preventDefault();
        go(index - 1);
        break;
      case "Home":
        event.preventDefault();
        go(0);
        break;
      case "End":
        event.preventDefault();
        go(slides.length - 1);
        break;
    }
  });

  if (prev) prev.addEventListener("click", () => go(index - 1));
  if (next) next.addEventListener("click", () => go(index + 1));

  const fromHash = parseInt(location.hash.slice(1), 10);
  go(Number.isInteger(fromHash) ? fromHash - 1 : 0);
})();
