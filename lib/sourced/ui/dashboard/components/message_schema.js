// Places the message schema dialog (the layout's #message-schema popover)
// beside the name that opened it, and keeps it there. A MessageName button's
// Datastar click calls showMessageSchema(el), then fetches the schema into the
// dialog; the popover closes itself on a click outside it, or Escape.
//
// Below the name if it fits, else above it, and kept inside the window across.
// It's placed again whenever anything scrolls, the window resizes, or the
// dialog's size changes (as the schema loads), so it stays with its name.
(() => {
  const GAP = 6;     // between the name and the dialog
  const MARGIN = 8;  // kept from the window's edges
  let anchor = null; // the name it's open for

  const dialog = () => document.getElementById('message-schema');

  function place() {
    const d = dialog();
    if (!d || !anchor || !d.matches(':popover-open')) return;

    const r = anchor.getBoundingClientRect();
    const w = d.offsetWidth;
    const h = d.offsetHeight;
    let top = r.bottom + GAP;
    if (top + h > innerHeight - MARGIN && r.top - GAP - h >= MARGIN) top = r.top - GAP - h;
    top = Math.max(MARGIN, Math.min(top, innerHeight - MARGIN - h));
    const left = Math.max(MARGIN, Math.min(r.left, innerWidth - MARGIN - w));
    d.style.top = `${top}px`;
    d.style.left = `${left}px`;
  }

  // Opens the dialog for +el+, a message's name, or moves it there if it's
  // open (for a name picked with the keyboard, which doesn't close it first
  // as a click outside it does).
  window.showMessageSchema = (el) => {
    const d = dialog();
    if (!d) return;

    anchor = el;
    if (!d.matches(':popover-open')) d.showPopover();
    place();
  };

  function watch() {
    const d = dialog();
    if (!d) return;

    new ResizeObserver(place).observe(d);
    d.addEventListener('toggle', (e) => { if (e.newState === 'closed') anchor = null; });
  }

  // Any scroll: the page's, or a panel's the name is in.
  addEventListener('scroll', place, { capture: true, passive: true });
  addEventListener('resize', place);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watch);
  else watch();
})();
