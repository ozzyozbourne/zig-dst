// DST guide — shared helpers. Classic script (works without a build step).
// Load with: <script src="assets/dst.js"></script>, then call DST.page({ id: "ex03" }).
//
// API:
//   DST.page({id})                 builds top nav, footer, prev/next pager. Call once per page.
//   DST.text(id)                   raw captured program output (see tools/embed.py)
//   DST.data(id)                   JSON.parse of <script type="application/json" id="..."> (embedded real data)
//   DST.el(tag, attrs, ...kids)    HTML element.   DST.s(tag, attrs, ...kids)  SVG element.
//   DST.tip(el, textOrFn)          hover tooltip.
//   DST.bar(container, rows, opts)       rows: [{label, value, color?, note?}] horizontal bar chart (SVG).
//   DST.line(container, series, opts)    series: [{name, color, points:[[x,y],...]}] line chart (SVG).
//   DST.lanes(container, lanes, events, opts)
//        swimlane timeline: lanes: ["R0","R1"], events: [{lane, t, t2?, label?, color?, kind?, tip?}]
//        returns {svg, x(t), mark(t)} so a Player can move a cursor.
//   new DST.Player(container, {count, onStep(i), speed}) play/pause/step/slider for replaying events.
//   DST.term(container, text, rules)     render real terminal text into pre.term with regex highlights.
//   DST.Rand(seed)                 tiny deterministic PRNG (sfc32) for in-browser simulations.
//   DST.C                          palette (same as CSS variables).
(function () {
  const C = {
    bg: "#0b0f17", panel: "#151d2c", panel2: "#1b2538", line: "#26324a", text: "#e6ebf5", muted: "#8f9bb3",
    dim: "#5d6a85", accent: "#7c9cff", accent2: "#36d6c3", ok: "#3ddc84", warn: "#ffb547", bug: "#ff5c7a",
    violet: "#b48cff", pink: "#ff7ad9", yellow: "#f5e663",
  };
  const SERIES = [C.accent, C.accent2, C.warn, C.violet, C.pink, C.ok, C.yellow, C.bug];

  const PAGES = [
    { id: "home", href: "index.html", short: "Guide", title: "What is DST" },
    { id: "tb", href: "tigerbeetle.html", short: "VOPR", title: "Inside TigerBeetle's VOPR" },
    { id: "ex01", href: "01-seeded-randomness.html", short: "01", title: "Seeded randomness" },
    { id: "ex02", href: "02-simulated-time.html", short: "02", title: "Simulated time" },
    { id: "ex03", href: "03-deterministic-scheduler.html", short: "03", title: "Deterministic scheduler" },
    { id: "ex04", href: "04-simulated-disk-crashes.html", short: "04", title: "Simulated disk & crashes" },
    { id: "ex05", href: "05-simulated-network.html", short: "05", title: "Simulated network" },
    { id: "ex06", href: "06-swarm-testing-and-shrinking.html", short: "06", title: "Swarm testing & shrinking" },
    { id: "ex07", href: "07-linearizability-checker.html", short: "07", title: "Linearizability checker" },
    { id: "ex08", href: "08-leader-election-partitions.html", short: "08", title: "Leader election & partitions" },
    { id: "ex09", href: "09-storage-fault-atlas.html", short: "09", title: "Storage fault atlas" },
    { id: "ex10", href: "10-mini-vopr.html", short: "10", title: "Mini-VOPR" },
    { id: "ex11", href: "11-liveness-livelock.html", short: "11", title: "Liveness & livelock" },
    { id: "ex12", href: "12-coverage-marks-exhaustive.html", short: "12", title: "Coverage marks & exhaustive testing" },
    { id: "ex13", href: "13-clock-skew-leases.html", short: "13", title: "Clock skew & leases" },
    { id: "ex14", href: "14-rare-bugs-buggify.html", short: "14", title: "Rare bugs & BUGGIFY" },
    { id: "debug", href: "debugging.html", short: "Debug", title: "Debugging a failing seed" },
    { id: "limits", href: "limits.html", short: "Limits", title: "What DST can't catch" },
  ];

  function el(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === "style" && typeof v === "object") Object.assign(e.style, v);
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else if (k === "html") e.innerHTML = v;
      else e.setAttribute(k, v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) e.append(kid instanceof Node ? kid : String(kid));
    return e;
  }
  const NS = "http://www.w3.org/2000/svg";
  function s(tag, attrs, ...kids) {
    const e = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    return e;
  }
  const $ = (q) => (typeof q === "string" ? document.querySelector(q) : q);

  let tipEl;
  function tip(target, content) {
    if (!tipEl) { tipEl = el("div", { class: "dst-tip" }); document.body.append(tipEl); }
    target.addEventListener("mousemove", (ev) => {
      tipEl.textContent = typeof content === "function" ? content(ev) : content;
      tipEl.style.opacity = 1;
      const x = Math.min(ev.clientX + 14, window.innerWidth - tipEl.offsetWidth - 8);
      tipEl.style.left = x + "px"; tipEl.style.top = ev.clientY + 14 + "px";
    });
    target.addEventListener("mouseleave", () => { tipEl.style.opacity = 0; });
    target.style.cursor = "help";
  }

  function page({ id }) {
    const idx = PAGES.findIndex((p) => p.id === id);
    const nav = el("nav", {}, PAGES.map((p) => el("a", { href: p.href, class: p.id === id ? "cur" : null, title: p.title }, p.short)));
    document.body.prepend(el("header", { class: "top" }, el("div", { class: "in" }, el("a", { class: "brand", href: "index.html" }, "zig", el("b", {}, "-dst")), nav)));
    const main = document.querySelector("main");
    if (main && idx >= 0) {
      const prev = PAGES[idx - 1], next = PAGES[idx + 1];
      main.append(el("div", { class: "pager" },
        prev ? el("a", { class: "card", href: prev.href }, el("div", { class: "src" }, "← previous"), el("strong", {}, prev.title)) : el("span"),
        next ? el("a", { class: "card next", href: next.href }, el("div", { class: "src" }, "next →"), el("strong", {}, next.title)) : el("span")));
    }
    document.body.append(el("footer", { class: "foot" },
      "All numbers and traces on this site come from real runs of the Zig 0.17 programs in ",
      el("code", {}, "examples/"), " and of TigerBeetle's VOPR at commit 0450c32b2. Regenerate with ", el("code", {}, "site/tools/capture.sh"), "."));
  }

  function data(id) { return JSON.parse(document.getElementById(id).textContent); }
  // Raw captured output embedded by tools/embed.py: <script type="text/plain" id="..." data-src="data/..."></script>
  function text(id) { return document.getElementById(id).textContent.replace(/^\n/, "").replace(/<\\\/script/g, "</script"); }

  // ---------- charts ----------
  function bar(container, rows, opts = {}) {
    const W = opts.width || 760, rowH = opts.rowH || 26, labelW = opts.labelW || 200, pad = 8;
    const max = opts.max ?? (Math.max(...rows.map((r) => r.value)) || 1);
    const scale = opts.log ? (v) => (v <= 0 ? 0 : Math.log10(v + 1) / Math.log10(max + 1)) : (v) => v / max;
    const H = rows.length * rowH + pad * 2;
    const svg = s("svg", { viewBox: `0 0 ${W} ${H}` });
    rows.forEach((r, i) => {
      const y = pad + i * rowH, bw = Math.max(2, (W - labelW - 110) * scale(r.value));
      svg.append(s("text", { x: labelW - 10, y: y + rowH * 0.65, "text-anchor": "end", fill: C.muted, "font-size": 12, "font-family": "monospace" }, r.label));
      const rect = s("rect", { x: labelW, y: y + 4, width: 0, height: rowH - 8, rx: 4, fill: r.color || SERIES[i % SERIES.length] });
      rect.append(s("animate", { attributeName: "width", from: 0, to: bw, dur: "0.8s", fill: "freeze", begin: `${i * 0.05}s` }));
      svg.append(rect);
      svg.append(s("text", { x: labelW + bw + 8, y: y + rowH * 0.65, fill: C.text, "font-size": 12, "font-family": "monospace" }, opts.fmt ? opts.fmt(r.value, r) : r.value.toLocaleString()));
      if (r.note) tip(rect, r.note);
    });
    $(container).append(svg);
    return svg;
  }

  function niceTicks(lo, hi, n = 5) {
    const span = hi - lo || 1, step0 = span / n, mag = Math.pow(10, Math.floor(Math.log10(step0)));
    const step = [1, 2, 5, 10].map((m) => m * mag).find((st) => span / st <= n) || 10 * mag;
    const out = []; for (let v = Math.ceil(lo / step) * step; v <= hi + 1e-9; v += step) out.push(+v.toFixed(10));
    return out;
  }

  function line(container, series, opts = {}) {
    const W = opts.width || 760, H = opts.height || 300, m = { l: 56, r: 16, t: 14, b: 36 };
    const xs = series.flatMap((se) => se.points.map((p) => p[0])), ys = series.flatMap((se) => se.points.map((p) => p[1]));
    const x0 = opts.xmin ?? Math.min(...xs), x1 = opts.xmax ?? Math.max(...xs);
    const y0 = opts.ymin ?? Math.min(0, ...ys), y1 = opts.ymax ?? Math.max(...ys);
    const X = (v) => m.l + ((v - x0) / (x1 - x0 || 1)) * (W - m.l - m.r);
    const Y = (v) => H - m.b - ((v - y0) / (y1 - y0 || 1)) * (H - m.t - m.b);
    const svg = s("svg", { viewBox: `0 0 ${W} ${H}` });
    for (const t of niceTicks(y0, y1)) {
      svg.append(s("line", { x1: m.l, x2: W - m.r, y1: Y(t), y2: Y(t), stroke: C.line }));
      svg.append(s("text", { x: m.l - 6, y: Y(t) + 4, "text-anchor": "end", fill: C.dim, "font-size": 11, "font-family": "monospace" }, opts.yfmt ? opts.yfmt(t) : t));
    }
    for (const t of niceTicks(x0, x1, 8)) svg.append(s("text", { x: X(t), y: H - m.b + 16, "text-anchor": "middle", fill: C.dim, "font-size": 11, "font-family": "monospace" }, opts.xfmt ? opts.xfmt(t) : t));
    if (opts.xlabel) svg.append(s("text", { x: (W + m.l) / 2, y: H - 4, "text-anchor": "middle", fill: C.muted, "font-size": 12 }, opts.xlabel));
    if (opts.ylabel) svg.append(s("text", { x: 12, y: (H - m.b) / 2, transform: `rotate(-90 12 ${(H - m.b) / 2})`, "text-anchor": "middle", fill: C.muted, "font-size": 12 }, opts.ylabel));
    series.forEach((se, i) => {
      const d = se.points.map((p, j) => (opts.step && j ? `H${X(p[0])}V${Y(p[1])}` : `${j ? "L" : "M"}${X(p[0])},${Y(p[1])}`)).join("");
      const path = s("path", { d, fill: "none", stroke: se.color || SERIES[i % SERIES.length], "stroke-width": se.width || 2, "stroke-dasharray": se.dash || null });
      svg.append(path);
      requestAnimationFrame(() => {
        const L = path.getTotalLength(); if (!L || se.dash) return;
        path.style.strokeDasharray = L; path.style.strokeDashoffset = L;
        path.style.transition = "stroke-dashoffset 1.2s ease"; requestAnimationFrame(() => (path.style.strokeDashoffset = 0));
      });
      if (se.dots) se.points.forEach((p) => { const c = s("circle", { cx: X(p[0]), cy: Y(p[1]), r: 3.5, fill: se.color || SERIES[i % SERIES.length] }); if (p[2]) tip(c, p[2]); svg.append(c); });
    });
    $(container).append(svg);
    if (series.length > 1 && !opts.noLegend) $(container).append(el("div", { class: "legend" }, series.map((se, i) => el("span", {}, el("i", { class: "sw", style: { background: se.color || SERIES[i % SERIES.length] } }), se.name))));
    return { svg, X, Y };
  }

  function lanes(container, laneNames, events, opts = {}) {
    const W = opts.width || 1000, laneH = opts.laneH || 34, m = { l: opts.labelW || 70, r: 16, t: 22, b: 28 };
    const H = m.t + laneNames.length * laneH + m.b;
    const t0 = opts.tmin ?? Math.min(...events.map((e) => e.t)), t1 = opts.tmax ?? Math.max(...events.map((e) => e.t2 ?? e.t));
    const x = (t) => m.l + ((t - t0) / (t1 - t0 || 1)) * (W - m.l - m.r);
    const svg = s("svg", { viewBox: `0 0 ${W} ${H}` });
    laneNames.forEach((n, i) => {
      const y = m.t + i * laneH;
      svg.append(s("rect", { x: m.l, y, width: W - m.l - m.r, height: laneH - 4, rx: 5, fill: i % 2 ? "#111a2b" : "#0f1726" }));
      svg.append(s("text", { x: m.l - 8, y: y + laneH / 2 + 2, "text-anchor": "end", fill: C.muted, "font-size": 12, "font-family": "monospace" }, n));
    });
    for (const t of niceTicks(t0, t1, 10)) svg.append(s("text", { x: x(t), y: H - 8, "text-anchor": "middle", fill: C.dim, "font-size": 10, "font-family": "monospace" }, t));
    if (opts.tlabel) svg.append(s("text", { x: W - m.r, y: 14, "text-anchor": "end", fill: C.dim, "font-size": 10, "font-family": "monospace" }, opts.tlabel));
    const nodes = events.map((e, i) => {
      const li = typeof e.lane === "number" ? e.lane : laneNames.indexOf(e.lane);
      const y = m.t + li * laneH, col = e.color || C.accent;
      let n;
      if (e.t2 != null) n = s("rect", { x: x(e.t), y: y + 6, width: Math.max(3, x(e.t2) - x(e.t)), height: laneH - 16, rx: 4, fill: col, opacity: 0.85 });
      else if (e.kind === "x") n = s("text", { x: x(e.t), y: y + laneH / 2 + 5, "text-anchor": "middle", fill: col, "font-size": 16, "font-weight": 700 }, "✕");
      else n = s("circle", { cx: x(e.t), cy: y + laneH / 2 - 2, r: e.r || 5, fill: col });
      n.dataset.i = i;
      if (e.tip) tip(n, e.tip);
      svg.append(n);
      if (e.label && e.t2 != null) svg.append(s("text", { x: x(e.t) + 4, y: y + laneH / 2 + 2, fill: "#0b0f17", "font-size": 10, "font-family": "monospace", "pointer-events": "none" }, e.label));
      return n;
    });
    if (opts.arrows) for (const a of opts.arrows) {
      const ly = (l) => m.t + (typeof l === "number" ? l : laneNames.indexOf(l)) * laneH + laneH / 2 - 2;
      const p = s("line", { x1: x(a.t), y1: ly(a.from), x2: x(a.t2), y2: ly(a.to), stroke: a.color || C.dim, "stroke-width": 1.2, opacity: a.opacity ?? 0.7, "stroke-dasharray": a.dash || null });
      if (a.tip) tip(p, a.tip);
      svg.prepend(p); svg.prepend(svg.firstChild); // keep lane backgrounds behind
    }
    const cursor = s("line", { x1: m.l, x2: m.l, y1: m.t - 6, y2: H - m.b + 2, stroke: C.yellow, "stroke-width": 1.5, opacity: 0 });
    svg.append(cursor);
    $(container).append(svg);
    return {
      svg, x, nodes,
      mark(t) { cursor.setAttribute("x1", x(t)); cursor.setAttribute("x2", x(t)); cursor.setAttribute("opacity", 1); nodes.forEach((n, i) => n.setAttribute("opacity", events[i].t <= t ? 1 : 0.18)); },
    };
  }

  class Player {
    constructor(container, { count, onStep, speed = 6, label }) {
      this.count = count; this.onStep = onStep; this.i = 0; this.timer = null; this.speed = speed;
      this.btn = el("button", { class: "primary", onclick: () => this.toggle() }, "▶ play");
      this.range = el("input", { type: "range", min: 0, max: count - 1, value: 0, oninput: (e) => this.go(+e.target.value) });
      this.out = el("span", { class: "out" });
      this.sp = el("select", { onchange: (e) => { this.speed = +e.target.value; if (this.timer) { this.stop(); this.play(); } } },
        [1, 3, 6, 15, 40].map((v) => el("option", { value: v, selected: v === speed ? "" : null }, v + "×")));
      this.label = label || ((i) => `${i + 1}/${count}`);
      $(container).append(el("div", { class: "controls" },
        el("button", { onclick: () => this.go(0), title: "first" }, "⏮"), el("button", { onclick: () => this.go(this.i - 1) }, "◀"),
        this.btn, el("button", { onclick: () => this.go(this.i + 1) }, "▶"), el("button", { onclick: () => this.go(count - 1), title: "last" }, "⏭"),
        this.range, this.sp, this.out));
      this.go(0);
    }
    go(i) { this.i = Math.max(0, Math.min(this.count - 1, i)); this.range.value = this.i; this.out.textContent = this.label(this.i); this.onStep(this.i); }
    play() { if (this.i >= this.count - 1) this.go(0); this.btn.textContent = "❚❚ pause"; this.timer = setInterval(() => { if (this.i >= this.count - 1) return this.stop(); this.go(this.i + 1); }, 1000 / this.speed); }
    stop() { clearInterval(this.timer); this.timer = null; this.btn.textContent = "▶ play"; }
    toggle() { this.timer ? this.stop() : this.play(); }
  }

  function esc(t) { return t.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]); }
  // rules: [[regex, className], ...] applied per line; first match wins for the whole line unless {inline:true}
  function term(container, text, rules = [[/FAIL|VIOLATED|panic|error/, "f"], [/PASS(ED)?/, "k"], [/^\$ /, "p"]]) {
    const html = text.split("\n").map((ln) => {
      for (const [re, cls] of rules) if (re.test(ln)) return `<span class="${cls}">${esc(ln)}</span>`;
      return esc(ln);
    }).join("\n");
    const pre = el("pre", { class: "term", html });
    $(container).append(pre);
    return pre;
  }

  // sfc32: small, fast, deterministic. Seed with any integer.
  function Rand(seed) {
    let a = 0x9e3779b9, b = 0x243f6a88, c = 0xb7e15162, d = (seed >>> 0) ^ 0xdeadbeef;
    const next = () => { a >>>= 0; b >>>= 0; c >>>= 0; d >>>= 0; let t = (a + b) | 0; a = b ^ (b >>> 9); b = (c + (c << 3)) | 0; c = (c << 21) | (c >>> 11); d = (d + 1) | 0; t = (t + d) | 0; c = (c + t) | 0; return (t >>> 0) / 4294967296; };
    for (let i = 0; i < 15; i++) next();
    return { float: next, int: (n) => Math.floor(next() * n), range: (lo, hi) => lo + Math.floor(next() * (hi - lo + 1)), chance: (p) => next() < p, pick: (arr) => arr[Math.floor(next() * arr.length)] };
  }

  window.DST = { C, SERIES, PAGES, el, s, $, tip, page, data, text, bar, line, lanes, Player, term, esc, Rand };
})();
