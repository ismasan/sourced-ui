// Pan and zoom for the boundaries map filling the window (/topology/map).
//
// Each svg.boundary-map in a [data-pan-zoom] container gets its own view,
// kept in its viewBox: dragging pans it, the wheel (or a trackpad's pinch)
// zooms around the pointer, and double-clicking fits it again. Fitting shows
// the whole map, but never larger than it's drawn, and is redone as the
// window resizes or a switch shows the map, until it's moved. The toolbar's
// [data-zoom] buttons and the keys + - 0 act on the map showing; f and the
// [data-fullscreen] button toggle the browser's full screen.
//
// A drag that pans doesn't click what it started on, so a reactor's link
// still opens on a plain click.
(() => {
  const ZOOM_IN = 8;      // how far in from fitting the whole map
  const ZOOM_OUT = 4;     // and out
  const STEP = 1.25;      // per button press or key
  const DRAG = 4;         // pixels moved before a press pans instead of clicking
  const views = new WeakMap();

  function view(svg) {
    let v = views.get(svg);
    if (v) return v;

    const [x, y, w, h] = svg.getAttribute('viewBox').split(/[\s,]+/).map(Number);
    const drawn = { x, y, w, h };
    let home = { ...drawn };
    let box = { ...home };
    let moved = false; // panned or zoomed since it was last fitted
    const apply = () => svg.setAttribute('viewBox', `${box.x} ${box.y} ${box.w} ${box.h}`);

    // The whole map, never larger than drawn: a small map sits in the middle
    // at its own size rather than blown up to fill the window.
    const fitted = () => {
      const cw = svg.clientWidth;
      const ch = svg.clientHeight;
      if (!cw || !ch) return { ...drawn };
      const scale = Math.max(drawn.w / cw, drawn.h / ch, 1);
      const fw = cw * scale;
      const fh = ch * scale;
      return { x: drawn.x - (fw - drawn.w) / 2, y: drawn.y - (fh - drawn.h) / 2, w: fw, h: fh };
    };

    // A point on the screen, in the map's coordinates.
    const toMap = (cx, cy) => {
      const point = new DOMPoint(cx, cy).matrixTransform(svg.getScreenCTM().inverse());
      return { x: point.x, y: point.y };
    };

    v = {
      // factor > 1 zooms in, around (cx, cy) on the screen, or the middle.
      zoom(factor, cx, cy) {
        const at = cx == null ? { x: box.x + box.w / 2, y: box.y + box.h / 2 } : toMap(cx, cy);
        const w = Math.min(Math.max(box.w / factor, home.w / ZOOM_IN), home.w * ZOOM_OUT);
        const f = box.w / w;
        box = { x: at.x - (at.x - box.x) / f, y: at.y - (at.y - box.y) / f, w: box.w / f, h: box.h / f };
        moved = true;
        apply();
      },
      // By (dx, dy) screen pixels.
      pan(dx, dy) {
        const scale = svg.getScreenCTM().a;
        box = { ...box, x: box.x - dx / scale, y: box.y - dy / scale };
        moved = true;
        apply();
      },
      fit() {
        home = fitted();
        box = { ...home };
        moved = false;
        apply();
      },
      // Its size changed (the window, or a switch showing it): fitted again,
      // unless it's been moved.
      resized() {
        if (!moved) this.fit();
      }
    };
    views.set(svg, v);
    return v;
  }

  function attach(svg) {
    new ResizeObserver(() => view(svg).resized()).observe(svg);
    svg.addEventListener('wheel', (e) => {
      e.preventDefault();
      // Pinches come as wheel events with ctrlKey, and smaller deltas.
      view(svg).zoom(Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015)), e.clientX, e.clientY);
    }, { passive: false });

    let press = null;
    svg.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      press = { x: e.clientX, y: e.clientY, id: e.pointerId, panning: false };
    });
    svg.addEventListener('pointermove', (e) => {
      if (!press || e.pointerId !== press.id) return;
      const dx = e.clientX - press.x;
      const dy = e.clientY - press.y;
      if (!press.panning) {
        if (Math.hypot(dx, dy) < DRAG) return;
        press.panning = true;
        svg.setPointerCapture(e.pointerId);
        svg.classList.add('is-panning');
      }
      view(svg).pan(dx, dy);
      press.x = e.clientX;
      press.y = e.clientY;
    });
    const release = () => {
      if (press?.panning) {
        svg.classList.remove('is-panning');
        // The click a drag ends with isn't one.
        svg.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); }, { capture: true, once: true });
      }
      press = null;
    };
    svg.addEventListener('pointerup', release);
    svg.addEventListener('pointercancel', release);
    svg.addEventListener('dblclick', (e) => {
      e.preventDefault();
      view(svg).fit();
    });
  }

  // The map the switches show now.
  const showing = (root) => [...root.querySelectorAll('svg.boundary-map')].find((svg) => svg.getClientRects().length > 0);

  function toggleFullscreen(root) {
    if (document.fullscreenElement) document.exitFullscreen();
    else root.requestFullscreen?.();
  }

  function init(root) {
    root.querySelectorAll('svg.boundary-map').forEach(attach);

    root.addEventListener('click', (e) => {
      const button = e.target.closest('[data-zoom], [data-fullscreen]');
      if (!button) return;
      if (button.hasAttribute('data-fullscreen')) return toggleFullscreen(root);

      const svg = showing(root);
      if (!svg) return;
      const v = view(svg);
      ({ in: () => v.zoom(STEP), out: () => v.zoom(1 / STEP), fit: () => v.fit() })[button.dataset.zoom]?.();
    });

    document.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('input, textarea, select, [contenteditable]')) return;
      const svg = showing(root);
      const v = svg && view(svg);
      switch (e.key) {
        case '+': case '=': v?.zoom(STEP); break;
        case '-': case '_': v?.zoom(1 / STEP); break;
        case '0': v?.fit(); break;
        case 'f': toggleFullscreen(root); break;
        default: return;
      }
      e.preventDefault();
    });
  }

  const start = () => document.querySelectorAll('[data-pan-zoom]').forEach(init);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
