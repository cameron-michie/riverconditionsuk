// River Conditions UK. One canvas; d3 for projection and zoom. No data lives here: the browser asks Supabase for map tiles
// (z/x/y) and Postgres decides what a tile contains at that zoom (stream order, simplification, clustering, caps).
(() => {
const HDR = RC.key ? { apikey: RC.key, Authorization: "Bearer " + RC.key } : {};
const json = r => { if (!r.ok) throw new Error(r.status); return r.json(); };
const rpc = (fn, body) => fetch(RC.api + "/rpc/" + fn, { method: "POST", headers: { ...HDR, "Content-Type": "application/json" }, body: JSON.stringify(body) }).then(json);
const rpcGet = (fn, q) => fetch(RC.api + "/rpc/" + fn + "?" + new URLSearchParams(q), { headers: HDR }).then(json);
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const ordn = n => { n = Math.round(n); const m = n % 100, t = n % 10; return n + (m >= 11 && m <= 13 ? "th" : t === 1 ? "st" : t === 2 ? "nd" : t === 3 ? "rd" : "th"); };
const nf = n => Number(n).toLocaleString("en-GB");
const when = t => t ? new Date(t).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "";
const day = t => t ? new Date(t).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" }) : "";

let cfg, SIGS = [], EV = {}, LAYERS = {}, on = {}, lab = {}, sigI = 0;
const COL = ["#aab5c0", "#3b6fb6", "#e6c53f", "#ee8a3c", "#b3202a"];
const FLOWCOL = ["#aab5c0", "#8c510a", "#d8b365", "#b8c6cf", "#5ab4ac", "#01665e"];     // flow vs normal: much lower (brown) .. much higher (teal)
const NEUTRAL = "#6f8aa3";                                                              // every river the same colour when no dataset is selected
const colOf = (i, r) => i < 0 ? NEUTRAL : r === 0 ? COL[0] : SIGS[i].code === "flow" ? FLOWCOL[r] : COL[r];
const GB = ["#bbb", "#8c510a", "#8fb0cf", "#e6c53f", "#ee8a3c", "#b3202a"];        // gauge band rank: low, normal, elevated, high, severe
const BAND = ["low", "normal", "elevated", "high", "severe"], RISK = { VL: "very low", L: "low", M: "medium", H: "high" };
const SEWAGE = "#7a4a1d";
const ARROW = { improving: "↗", worsening: "↘", stable: "→" };
const word = (i, r) => r ? SIGS[i].words[r - 1] : (SIGS[i]?.code === "flow" ? "no gauge nearby" : "no data");

// ───────────────────────── canvas, projection, view
const cv = $("#map"), ctx = cv.getContext("2d"), tip = $("#tip");
let W, H, dpr, proj, s0, T = d3.zoomIdentity, zoomB;
function size() { dpr = devicePixelRatio || 1; W = innerWidth; H = innerHeight; cv.width = W * dpr; cv.height = H * dpr; cv.style.width = W + "px"; cv.style.height = H + "px"; }
function fit() { proj = d3.geoMercator().fitExtent([[30, 56], [W - 30, H - 50]], { type: "MultiPoint", coordinates: [[-6.4, 49.9], [1.9, 58.9]] }); s0 = proj.scale(); }
const tzf = () => Math.log2(2 * Math.PI * s0 * T.k / 256);
const tz = () => Math.max(0, Math.min(14, Math.round(tzf())));
const lon2x = (lon, z) => (lon + 180) / 360 * 2 ** z;
const lat2y = (lat, z) => { const r = Math.max(-85.05, Math.min(85.05, lat)) * Math.PI / 180; return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * 2 ** z; };
const bbox = () => { const a = proj.invert([-T.x / T.k, -T.y / T.k]), b = proj.invert([(W - T.x) / T.k, (H - T.y) / T.k]); return [a[0], b[1], b[0], a[1]]; };
const scr = p => [p.px * T.k + T.x, p.py * T.k + T.y];

// ───────────────────────── tiles
const tiles = new Map(); let queue = [], inflight = 0, wanted = new Set(), shown = {};
const tkey = (l, z, x, y) => l + "/" + z + "/" + x + "/" + y;
function want(l, z, x, y) {
  const k = tkey(l, z, x, y); wanted.add(k);
  let t = tiles.get(k);
  if (!t) { t = { k, l, z, x, y, st: "q" }; tiles.set(k, t); queue.push(t); pump(); }
  return t;
}
function pump() {
  while (inflight < 8 && queue.length) {
    const t = queue.pop();
    if (!wanted.has(t.k)) { tiles.delete(t.k); continue; }               // scrolled away before we got to it
    inflight++; t.st = "l"; status();
    rpcGet("map_tile", { p_layer: t.l, z: t.z, x: t.x, y: t.y }).then(j => { t.fs = j.features || []; t.cut = j.truncated; prep(t); t.st = "ok"; })
      .catch(() => { t.st = "err"; setTimeout(() => tiles.delete(t.k), 4000); })
      .finally(() => { inflight--; status(); pump(); redraw(); });
  }
}
function status() { const n = inflight + queue.length; $("#status").textContent = n ? "loading" : ""; }
function prune() { if (tiles.size < 900) return; for (const [k, t] of tiles) if (!wanted.has(k) && t.st === "ok" && tiles.size > 600) tiles.delete(k); }

const bboxOf = a => { const b = [1e9, 1e9, -1e9, -1e9]; for (let i = 0; i < a.length; i += 2) { if (a[i] < b[0]) b[0] = a[i]; if (a[i + 1] < b[1]) b[1] = a[i + 1]; if (a[i] > b[2]) b[2] = a[i]; if (a[i + 1] > b[3]) b[3] = a[i + 1]; } return b; };
function lines(g) { return g.type === "LineString" ? [g.coordinates] : g.type === "MultiLineString" ? g.coordinates : g.type === "Polygon" ? g.coordinates : g.type === "MultiPolygon" ? g.coordinates.flat() : []; }
function prep(t) {
  const kind = LAYERS[t.l].kind;
  if (kind === "point") {
    t.pts = t.fs.map(f => { const p = proj(f.geometry.coordinates); return { px: p[0], py: p[1], p: f.properties, id: f.id, l: t.l }; });
  } else if (kind === "polygon") {
    t.all = new Path2D();
    t.polys = t.fs.map(f => { const path = new Path2D(); for (const ln of lines(f.geometry)) { ln.forEach((c, i) => { const p = proj(c); i ? path.lineTo(p[0], p[1]) : path.moveTo(p[0], p[1]); }); path.closePath(); }
      t.all.addPath(path); const p = f.properties, lp = p.lx != null ? proj([p.lx, p.ly]) : null; return { path, p, lp }; });
  } else {
    t.fl = t.fs.map(f => { const parts = lines(f.geometry).map(ln => { const a = new Float32Array(ln.length * 2); ln.forEach((c, i) => { const p = proj(c); a[2 * i] = p[0]; a[2 * i + 1] = p[1]; }); return a; });
      const bb = [1e9, 1e9, -1e9, -1e9]; parts.forEach(a => { const b = bboxOf(a); bb[0] = Math.min(bb[0], b[0]); bb[1] = Math.min(bb[1], b[1]); bb[2] = Math.max(bb[2], b[2]); bb[3] = Math.max(bb[3], b[3]); });
      return { p: f.properties, parts, bb }; });
    t.bs = -1;
  }
}
function buckets(t, S) {                                          // Path2D per (state rank, river size); separate set for the selected river
  if (t.bs === sigI && t.bsel === S) return t.bk; t.bs = sigI; t.bsel = S; const o = new Map(), sm = new Map();
  for (const f of t.fl) {
    const r = sigI < 0 || !f.p.s ? 0 : +f.p.s[sigI] || 0, key = r * 32 + Math.min(f.p.o || 1, 31), m = S && (S[0] === "r" ? f.p.r === S.slice(2) : String(f.p.w) === S.slice(2)) ? sm : o;
    let path = m.get(key); if (!path) m.set(key, path = new Path2D());
    for (const a of f.parts) for (let i = 0; i < a.length; i += 2) i ? path.lineTo(a[i], a[i + 1]) : path.moveTo(a[i], a[i + 1]);
  }
  return t.bk = { o, s: sm };
}

// tiles to draw for a layer: the current zoom if loaded, otherwise whatever loaded tile overlaps (so zooming never blanks the map)
function visible(layer, z, bb) {
  const n = 2 ** z, x0 = Math.max(0, Math.floor(lon2x(bb[0], z))), x1 = Math.min(n - 1, Math.floor(lon2x(bb[2], z))), y0 = Math.max(0, Math.floor(lat2y(bb[3], z))), y1 = Math.min(n - 1, Math.floor(lat2y(bb[1], z)));
  const out = [], seen = new Set(), prev = shown[layer] || [];
  for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) {
    const t = want(layer, z, x, y);
    if (t.st === "ok") { if (!seen.has(t)) { seen.add(t); out.push(t); } continue; }
    for (const p of prev) { if (p.z === z || seen.has(p)) continue; const s = 2 ** (z - p.z); const ox = p.x * s, oy = p.y * s, w = s; if (x + 1 > ox && x < ox + w && y + 1 > oy && y < oy + w) { seen.add(p); out.push(p); } }
  }
  shown[layer] = out.filter(t => t.st === "ok"); return out;
}

// ───────────────────────── drawing
let hov = null, sel = null, raf = 0, drawn = {}, zonesShown = false;
const redraw = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(draw); };
const zf = () => Math.max(0.7, Math.min(2.6, 0.7 + 0.22 * (tzf() - 5)));
const px = o => (0.55 + 0.3 * Math.pow(o, 1.1)) * zf();       // line width follows river size (upstream channel length class), a proxy for width
const lw = v => v / T.k;
let rects = [];
function label(text, x, y, font, color, halo) {
  ctx.font = font; const w = ctx.measureText(text).width, r = [x - w / 2 - 2, y - 11, x + w / 2 + 2, y + 3];
  for (const q of rects) if (r[0] < q[2] && r[2] > q[0] && r[1] < q[3] && r[3] > q[1]) return false;
  rects.push(r); ctx.lineWidth = 3; ctx.strokeStyle = halo || "rgba(255,255,255,.92)"; ctx.strokeText(text, x, y); ctx.fillStyle = color; ctx.fillText(text, x, y); return true;
}
function draw() {
  const z = tz(), bb = bbox(); drawn = {}; rects = [];
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
  ctx.setTransform(dpr * T.k, 0, 0, dpr * T.k, dpr * T.x, dpr * T.y); ctx.lineJoin = "round"; ctx.lineCap = "round";
  const act = c => on[c] && z >= LAYERS[c].min_zoom;
  // base
  if (act("country")) { drawn.country = visible("country", z, bb); ctx.fillStyle = "#fbfbfb"; ctx.strokeStyle = "#d9d9d9"; ctx.lineWidth = lw(0.8); for (const t of drawn.country) { ctx.fill(t.all); ctx.stroke(t.all); } }
  // natural water at true size, under everything else
  if (act("water")) { drawn.water = visible("water", z, bb); ctx.fillStyle = "#d3e6f5"; ctx.strokeStyle = "#8fb4d9"; ctx.lineWidth = lw(0.6); for (const t of drawn.water) { ctx.fill(t.all); if (z >= 8) ctx.stroke(t.all); } }
  if (act("beaches")) { drawn.beaches = visible("beaches", z, bb); ctx.fillStyle = "#efdca8"; ctx.strokeStyle = "#c2a24f"; ctx.lineWidth = lw(0.9); for (const t of drawn.beaches) { ctx.fill(t.all); ctx.stroke(t.all); } }   // true size; the 0.9 px outline keeps slivers findable
  if (on.rain && WX.img && WX.img.complete && WX.rb) { const p0 = proj([WX.rb[0], WX.rb[3]]), p1 = proj([WX.rb[2], WX.rb[1]]); ctx.imageSmoothingEnabled = true; ctx.drawImage(WX.img, p0[0], p0[1], p1[0] - p0[0], p1[1] - p0[1]); }   // radar now, forecast later; one Mercator-linear PNG
  // overlays
  if (act("urban")) { drawn.urban = visible("urban", z, bb); const fa = z <= 9 ? 0.10 : z <= 11 ? 0.05 : 0; ctx.fillStyle = "rgba(95,95,95," + fa + ")"; ctx.strokeStyle = "rgba(95,95,95,.4)"; ctx.lineWidth = lw(0.7); for (const t of drawn.urban) { if (fa) ctx.fill(t.all); if (z >= 8) ctx.stroke(t.all); } }
  if (act("national_parks")) { drawn.national_parks = visible("national_parks", z, bb); ctx.fillStyle = "rgba(46,125,80," + (z <= 10 ? 0.08 : 0.04) + ")"; ctx.strokeStyle = "rgba(46,125,80,.65)"; ctx.lineWidth = lw(1); for (const t of drawn.national_parks) { ctx.fill(t.all); ctx.stroke(t.all); } }
  if (act("flood_outlook")) { drawn.flood_outlook = visible("flood_outlook", z, bb); ctx.lineWidth = lw(0.8); for (const t of drawn.flood_outlook) for (const f of t.polys) { const r = f.p.r | 0; ctx.fillStyle = ["rgba(0,0,0,0)", "rgba(230,197,63,.30)", "rgba(238,138,60,.38)", "rgba(179,32,42,.42)"][r]; ctx.strokeStyle = r ? "rgba(120,90,20,.55)" : "rgba(150,150,150,.45)"; ctx.fill(f.path); ctx.stroke(f.path); } }
  if (act("flood_warnings")) { drawn.flood_warnings = visible("flood_warnings", z, bb); ctx.lineWidth = lw(1.6); for (const t of drawn.flood_warnings) for (const f of t.polys) { const sv = f.p.sv | 3; ctx.fillStyle = sv === 3 ? "rgba(230,160,40,.35)" : "rgba(179,32,42,.40)"; ctx.strokeStyle = sv === 3 ? "#c47f00" : "#b3202a"; ctx.fill(f.path); ctx.stroke(f.path); } }
  if (act("flood_zones")) { drawn.flood_zones = visible("flood_zones", z, bb); let any = false; for (const t of drawn.flood_zones) for (const f of t.polys) { any = true; const z3 = f.p.z === "FZ3"; ctx.fillStyle = z3 ? "rgba(200,20,30,.42)" : "rgba(200,20,30,.22)"; ctx.strokeStyle = z3 ? "rgba(179,32,42,.95)" : "rgba(179,32,42,.5)"; ctx.lineWidth = lw(z3 ? 1.1 : 0.7); ctx.fill(f.path); ctx.stroke(f.path); } if (any !== zonesShown) { zonesShown = any; legendUI(); } }
  if (on.pressure && WX.path) { ctx.strokeStyle = "rgba(80,70,100,.5)"; ctx.lineWidth = lw(0.8); ctx.stroke(WX.path); ctx.strokeStyle = "rgba(80,70,100,.8)"; ctx.lineWidth = lw(1.4); ctx.stroke(WX.major); }
  // selected river: thin guide along its whole length, other rivers dimmed, the river itself outlined where it is drawn
  const S = sel && sel.key;
  if (S && sel.path) { ctx.strokeStyle = "rgba(17,17,17,.6)"; ctx.lineWidth = lw(1.4); ctx.stroke(sel.path); }
  if (on.network) {
    drawn.network = visible("network", z, bb);
    const paint = (m, cas) => { for (const [key, path] of m) { const r = key >> 5, o = key & 31; if (cas) { ctx.strokeStyle = "#111"; ctx.lineWidth = lw(px(o) + 3.4); ctx.stroke(path); } ctx.strokeStyle = sigI < 0 ? NEUTRAL : COL[0]; if (r) ctx.strokeStyle = colOf(sigI, r); ctx.lineWidth = lw(px(o) * (r || sigI < 0 ? 1 : 0.8)); ctx.stroke(path); } };
    for (const t of drawn.network) { ctx.globalAlpha = S ? 0.3 : 1; paint(buckets(t, S).o, false); }
    ctx.globalAlpha = 1;
    if (S) for (const t of drawn.network) paint(buckets(t, S).s, true);
  }
  if (act("bridge_areas")) { drawn.bridge_areas = visible("bridge_areas", z, bb); ctx.fillStyle = "#2b2b2b"; ctx.strokeStyle = "#111"; ctx.lineWidth = lw(1.3); for (const t of drawn.bridge_areas) { ctx.fill(t.all); ctx.stroke(t.all); } }   // massive bridges at true size; the outline keeps them visible zoomed out
  if (hov && hov.kind === "river") {                               // the whole stretch the information is about, not just the link under the cursor
    const w = hov.f.p.w, mine = w != null ? [] : [hov.f];
    if (w != null) for (const t of drawn.network || []) for (const f of t.fl) if (f.p.w === w) mine.push(f);
    ctx.strokeStyle = "#111"; for (const f of mine) { ctx.lineWidth = lw(px(f.p.o || 1) + 2.6); const pth = new Path2D(); for (const a of f.parts) for (let i = 0; i < a.length; i += 2) i ? pth.lineTo(a[i], a[i + 1]) : pth.moveTo(a[i], a[i + 1]); ctx.stroke(pth); }
  }
  // screen space
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.textAlign = "center";
  const sx = p => p.px * T.k + T.x, sy = p => p.py * T.k + T.y;
  if (act("river_labels")) { drawn.river_labels = visible("river_labels", z, bb); for (const t of drawn.river_labels) for (const q of t.pts) { const x = sx(q), y = sy(q); if (x > 0 && y > 0 && x < W && y < H) label(String(q.p.n).replace(/^(River|Afon) /, ""), x, y - 3, "italic 11px system-ui", "#566"); } }
  if (act("place_labels")) { drawn.place_labels = visible("place_labels", z, bb); for (const t of drawn.place_labels) for (const q of t.pts) { const x = sx(q), y = sy(q); if (x > -50 && y > 0 && x < W + 50 && y < H) label(q.p.n, x, y, "600 12px system-ui", "#222"); } }
  if (lab.national_parks && drawn.national_parks) for (const t of drawn.national_parks) for (const f of t.polys) if (f.lp && z >= 5) label(f.p.n.replace(/ National Park$/, ""), f.lp[0] * T.k + T.x, f.lp[1] * T.k + T.y, "italic 12px system-ui", "#2e6b49");
  if (lab.urban && drawn.urban) for (const t of drawn.urban) for (const f of t.polys) { const a = f.p.a || 0, minz = f.p.m || a >= 60 ? 5 : a >= 15 ? 8 : 10; if (f.lp && z >= minz) label(f.p.n, f.lp[0] * T.k + T.x, f.lp[1] * T.k + T.y, (f.p.m || a >= 60 ? "600 " : "") + "11px system-ui", "#444"); }
  if (lab.water && drawn.water) for (const t of drawn.water) for (const f of t.polys) { const a = f.p.a || 0; if (f.p.n && f.lp && (a >= 8 || (z >= 8 && a >= 0.4) || (z >= 10 && a >= 0.08) || z >= 12)) label(f.p.n, f.lp[0] * T.k + T.x, f.lp[1] * T.k + T.y, "italic 11px system-ui", "#3b6fb6"); }
  if (lab.beaches && drawn.beaches) for (const t of drawn.beaches) for (const f of t.polys) if (f.p.n && f.lp && z >= 11) label(f.p.n, f.lp[0] * T.k + T.x, f.lp[1] * T.k + T.y, "italic 11px system-ui", "#8a6d1c");
  if (on.pressure) for (const q of WX.labels) { const x = sx(q), y = sy(q); if (x > 0 && y > 0 && x < W && y < H) label(q.t, x, y + 4, "600 11px system-ui", "#4a4060"); }
  // points, least to most urgent
  for (const code of ["bridges", "gauges", "bathing", "sewage_works", "overflows"]) {
    if (!act(code)) continue; drawn[code] = visible(code, z, bb);
    for (const t of drawn[code]) for (const q of t.pts) { const x = sx(q), y = sy(q); if (x < -20 || y < -20 || x > W + 20 || y > H + 20) continue; symbol(code, q, x, y, z); }
  }
}
function symbol(code, q, x, y, z) {
  const p = q.p;
  if (p.c != null) {                                              // server-side cluster
    const r = 7 + Math.min(11, 2.2 * Math.log2(p.c + 1)); ctx.beginPath(); ctx.arc(x, y, r, 0, 7); ctx.fillStyle = "rgba(255,255,255,.92)"; ctx.fill(); ctx.lineWidth = 1.5; ctx.strokeStyle = p.h ? COL[4] : "#777"; ctx.stroke();
    ctx.fillStyle = "#222"; ctx.font = "10px system-ui"; ctx.fillText(p.c > 999 ? Math.round(p.c / 100) / 10 + "k" : p.c, x, y + 3.5); return;
  }
  ctx.lineWidth = 1;
  if (code === "overflows") {                                   // storm overflows: circles. Red = discharging now; filled = monitored; hollow = offline or unmonitored
    ctx.beginPath();
    if (p.st === "discharging") { ctx.arc(x, y, 5.4, 0, 7); ctx.fillStyle = COL[4]; ctx.fill(); ctx.strokeStyle = "#fff"; ctx.lineWidth = 1.8; ctx.stroke(); }
    else if (p.mon) { ctx.arc(x, y, 3.2, 0, 7); ctx.fillStyle = "#cf8b80"; ctx.fill(); ctx.strokeStyle = "#fff"; ctx.stroke(); }
    else { ctx.arc(x, y, 3, 0, 7); ctx.fillStyle = "#fff"; ctx.fill(); ctx.strokeStyle = "#9a7b74"; ctx.lineWidth = 1.2; ctx.stroke(); }
  } else if (code === "sewage_works") {                         // treatment works: squares. Filled = effluent is monitored; hollow = no monitoring point found
    ctx.beginPath(); ctx.rect(x - 4, y - 4, 8, 8);
    if (p.m) { ctx.fillStyle = SEWAGE; ctx.fill(); ctx.strokeStyle = "#fff"; ctx.lineWidth = 1.2; ctx.stroke(); } else { ctx.fillStyle = "#fff"; ctx.fill(); ctx.strokeStyle = SEWAGE; ctx.lineWidth = 1.5; ctx.stroke(); }
  } else if (code === "bathing") {
    ctx.fillStyle = ({ excellent: COL[1], good: "#6a9fd0", sufficient: COL[2], poor: COL[4] })[p.cl] || "#bbb"; ctx.strokeStyle = "#fff"; ctx.fillRect(x - 4, y - 4, 8, 8); ctx.strokeRect(x - 4, y - 4, 8, 8);
  } else if (code === "gauges") {                               // gauges: ring coloured by flood band
    const b = p.b | 0; ctx.beginPath(); ctx.arc(x, y, b >= 4 ? 5.2 : b === 3 ? 4.4 : 3.6, 0, 7); ctx.fillStyle = GB[b]; ctx.fill(); ctx.strokeStyle = "#fff"; ctx.lineWidth = 1.4; ctx.stroke();
  } else if (code === "bridges") {
    ctx.strokeStyle = "#333"; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(x - 5, y); ctx.lineTo(x + 5, y); ctx.stroke(); ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(x - 4, y - 3); ctx.lineTo(x - 4, y + 3); ctx.moveTo(x + 4, y - 3); ctx.lineTo(x + 4, y + 3); ctx.stroke();
    if (z >= 13) label(p.n, x, y - 8, "11px system-ui", "#333");
  }
}

// ───────────────────────── hit testing and tooltip
function polyHit(mx, my) {
  ctx.save(); ctx.setTransform(dpr * T.k, 0, 0, dpr * T.k, dpr * T.x, dpr * T.y); let r = null;
  for (const code of ["flood_zones", "flood_warnings", "flood_outlook"]) { for (const t of drawn[code] || []) { for (const f of t.polys) if (ctx.isPointInPath(f.path, mx * dpr, my * dpr)) { r = { kind: "poly", code, f }; break; } if (r) break; } if (r) break; }
  ctx.restore(); return r;
}
function pick(mx, my) {
  for (const code of ["overflows", "sewage_works", "gauges", "bathing", "bridges"]) {
    if (!drawn[code]) continue; let best = null, bd = 100;
    for (const t of drawn[code]) for (const q of t.pts) { const [x, y] = scr(q), d = (x - mx) ** 2 + (y - my) ** 2; if (d < bd) { bd = d; best = q; } }
    if (best) return { kind: "point", q: best, code };
  }
  if (!drawn.network) return polyHit(mx, my);
  const bx = (mx - T.x) / T.k, by = (my - T.y) / T.k, tol = 7 / T.k; let best = null, bd = tol * tol;
  for (const t of drawn.network) for (const f of t.fl) {
    const b = f.bb; if (bx < b[0] - tol || bx > b[2] + tol || by < b[1] - tol || by > b[3] + tol) continue;
    for (const a of f.parts) for (let i = 0; i + 3 < a.length; i += 2) {
      const x1 = a[i], y1 = a[i + 1], dx = a[i + 2] - x1, dy = a[i + 3] - y1, l = dx * dx + dy * dy; let u = l ? ((bx - x1) * dx + (by - y1) * dy) / l : 0; u = u < 0 ? 0 : u > 1 ? 1 : u;
      const ex = x1 + u * dx - bx, ey = y1 + u * dy - by, d = ex * ex + ey * ey - (f.p.o || 1) * 1e-9 / T.k;
      if (d < bd) { bd = d; best = f; }
    }
  }
  return best ? { kind: "river", f: best } : polyHit(mx, my);
}
const riverLine = f => { const p = f.p, r = p.s && sigI >= 0 ? +p.s[sigI] || 0 : 0;
  if (!p.s) return esc(p.n || "watercourse") + " · not a classified stretch";
  const base = `${esc(p.n || "stretch")} · ${p.k ? Math.round(p.k * 10) / 10 + " km stretch" : "stretch"}`;
  return sigI < 0 ? base : `${base} · ${SIGS[sigI].code === "flow" ? "flow" : SIGS[sigI].label} ${word(sigI, r)}${p.t && p.t[sigI] !== "0" && p.t[sigI] ? " " + (p.t[sigI] === "+" ? "↗" : "↘") : ""}`; };
const polyLine = h => { const p = h.f.p;
  if (h.code === "flood_zones") return `${p.z === "FZ3" ? "Expected flood plain, high probability (flood zone 3)" : "Expected flood plain, medium probability (flood zone 2)"} · ${esc(p.r)}`;
  if (h.code === "flood_warnings") return `${esc(p.n)} · ${({ 1: "severe flood warning", 2: "flood warning", 3: "flood alert" })[p.sv] || "flood alert"}`;
  return `${esc(p.n)} · flood risk, next 5 days: ${String(p.d || "").split(",").map(x => RISK[x] || x).join(", ")}`; };
const pointLine = h => { const p = h.q.p; if (p.c != null) return `${nf(p.c)} ${LAYERS[h.code].label}${p.h ? ", " + p.h + " active" : ""}: click to zoom`;
  if (h.code === "overflows") return `${esc(p.n || "overflow")} · ${p.st === "discharging" ? "discharging now" : p.st === "not_discharging" ? "not discharging" : "monitor " + p.st} · ${esc(p.co || "")}`;
  if (h.code === "sewage_works") return `${esc(p.n || "treatment works")} · treated sewage discharge · effluent ${p.m ? "monitored" : "not monitored"}${p.co ? " · " + esc(p.co) : ""}`;
  if (h.code === "gauges") return `${esc(p.n)} · flood index ${BAND[(p.b | 0) - 1] || "unknown"}${p.lv != null ? " · height " + p.lv + " m" : ""}${p.q != null ? " · " + Number(p.q).toPrecision(3) + " m³/s" : ""}`;
  return h.code === "bathing" ? `${esc(p.n)} · ${esc(p.cl || "unclassified")}` : esc(p.n); };
cv.addEventListener("mousemove", ev => {
  const r = cv.getBoundingClientRect(), mx = ev.clientX - r.left, my = ev.clientY - r.top, h = pick(mx, my);
  const nh = h && h.kind === "river" ? h : null; const hk = x => x ? (x.f.p.w != null ? "w" + x.f.p.w : x.f) : null; if (hk(hov) !== hk(nh)) { hov = nh; redraw(); }
  if (h) { tip.style.display = "block"; tip.innerHTML = h.kind === "river" ? riverLine(h.f) : h.kind === "poly" ? polyLine(h) : pointLine(h); tip.style.left = Math.min(mx + 12, W - tip.offsetWidth - 8) + "px"; tip.style.top = my + 14 + "px"; cv.classList.add("hit"); } else { tip.style.display = "none"; cv.classList.remove("hit"); }
});
cv.addEventListener("dblclick", ev => {
  const r = cv.getBoundingClientRect(), h = pick(ev.clientX - r.left, ev.clientY - r.top);
  if (h && h.kind === "river" && h.f.p.r) openRiver(h.f.p.r, false);
});
cv.addEventListener("mouseleave", () => { tip.style.display = "none"; if (hov) { hov = null; redraw(); } });
cv.addEventListener("click", ev => {
  const r = cv.getBoundingClientRect(), h = pick(ev.clientX - r.left, ev.clientY - r.top);
  if (!h) return closePanel();
  if (h.kind === "river") { if (h.f.p.w != null) openStretch(h.f.p.w); else panelNote(h.f.p); return; }
  if (h.kind === "poly") { h.code === "flood_zones" ? showZone(h.f.p) : h.code === "flood_warnings" ? showWarning(h.f.p) : showOutlook(h.f.p); return; }
  if (h.q.p.c != null) { const [x, y] = scr(h.q); d3.select(cv).transition().duration(450).call(zoomB.scaleBy, 2.6, [x, y]); return; }
  showPoint(h.code, h.q.p, h.q.id);
});

// ───────────────────────── panel
function spark(pts, o = {}) {                                   // tiny dependency-free line chart
  if (!pts || pts.length < 2) return `<div class="dim">no recent readings</div>`;
  const w = 330, h = 54, xs = pts.map(q => q[0]), ys = pts.map(q => q[1]), lo = Math.min(...ys, o.lo ?? 1e9), hi = Math.max(...ys, o.hi ?? -1e9), x0 = xs[0], x1 = xs[xs.length - 1];
  const X = t => ((t - x0) / (x1 - x0 || 1)) * w, Y = v => h - 3 - ((v - lo) / (hi - lo || 1)) * (h - 8);
  const band = o.lo != null && o.hi != null ? `<rect x="0" y="${Y(o.hi)}" width="${w}" height="${Math.max(1, Y(o.lo) - Y(o.hi))}" fill="#e8f1f8"/>` : "";
  const max = o.max != null && o.max <= hi * 1.001 && o.max >= lo ? `<line x1="0" x2="${w}" y1="${Y(o.max)}" y2="${Y(o.max)}" stroke="#b3202a" stroke-dasharray="3 3" stroke-width="1"/>` : "";
  return `<svg viewBox="0 0 ${w} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(o.label || "chart")}">${band}${max}<polyline fill="none" stroke="#111" stroke-width="1.4" points="${pts.map(q => X(q[0]).toFixed(1) + "," + Y(q[1]).toFixed(1)).join(" ")}"/></svg>
    <div class="dim" style="display:flex;justify-content:space-between;font-size:11px"><span>7 days ago</span><span>${lo.toPrecision(3)} to ${hi.toPrecision(3)} ${o.unit || ""}</span><span>now</span></div>`;
}
const bandBar = b => `<span class="bands">${BAND.map((n, i) => `<i class="${i + 1 === b ? "on" : ""}" style="${i + 1 === b ? "background:" + GB[i + 1] + ";color:" + (i + 1 === 3 ? "#111" : "#fff") : ""}">${n}</i>`).join("")}</span>`;
const dayName = i => { const d = new Date(); d.setDate(d.getDate() + i); return i === 0 ? "Today" : d.toLocaleDateString("en-GB", { weekday: "short" }); };
const riskChips = d => String(d || "").split(",").filter(Boolean).map((r, i) => `<span class="rk r${["VL", "L", "M", "H"].indexOf(r)}"><b>${dayName(i)}</b> ${RISK[r] || r}</span>`).join("");

async function showGauge(p, id) {
  const seq = ++panelSeq; panel.style.display = "block"; sel = null; redraw(); doc.innerHTML = `<span class="dim">…</span>`;
  const d = await rpc("gauge_dossier", { p_id: id }); if (seq !== panelSeq) return; if (!d || !d.site) { doc.innerHTML = `<span class="dim">no data</span>`; return; }
  const st = d.state || {}, site = d.site, lvTxt = st.stage != null ? `${st.stage.toFixed(2)} m` : null;
  doc.innerHTML = `<div class="kick">River gauge${site.river ? ` on <a href="#${esc(site.river.slug)}">${esc(site.river.name)}</a>` : ""}</div><h1>${esc(site.name)}</h1>
    <div class="dim">${site.stretch ? `<a href="#stretch-${site.stretch.id}">${esc(site.stretch.name)}</a>` : ""}${tag("official_monitoring")}</div>
    <h2>Flood index now</h2>
    <div>${bandBar(st.band_rank)}</div>
    <h2>River height</h2>
    ${st.stage != null ? `<div class="big"><b>${lvTxt}</b> <span class="dim">${st.level_band} · ${st.level_index != null ? Math.round(st.level_index * 100) + "% of the way from typical high to the highest on record" : ""}</span></div>
      <div class="dim">typical range ${st.typical_low?.toFixed?.(2)} to ${st.typical_high?.toFixed?.(2)} m · highest on record ${st.max_on_record?.toFixed?.(2)} m · ${when(st.stage_at)}</div>
      ${spark(d.level, { lo: st.typical_low, hi: st.typical_high, max: st.max_on_record, unit: "m", label: "river height, last 7 days" })}` : `<div class="dim">No height reading with a known typical range at this gauge.</div>`}
    <h2>River flow</h2>
    ${st.flow != null ? `<div class="big"><b>${Number(st.flow).toPrecision(3)} m³/s</b> <span class="dim">${st.flow_band || ""}</span></div>
      <div class="dim">${st.flow_pct != null ? ordn(st.flow_pct) + " percentile of its long-term record" : ""}${st.qmed ? ` · ${Math.round(st.flow_index * 100)}% of the median annual flood (${Number(st.qmed).toPrecision(3)} m³/s)` : ""} · ${when(st.flow_at)}</div>
      ${spark(d.flow, { unit: "m³/s", label: "river flow, last 7 days" })}` : `<div class="dim">No flow measured at this gauge.</div>`}
    ${d.outlook?.days ? `<h2>Flood outlook, ${esc(d.outlook.area)}${tag("regulator_assessment")}</h2><div class="rks">${riskChips(d.outlook.days)}</div>` : ""}
    <div class="dim" style="margin-top:14px">Flood index: height against the gauge's typical range and record high, and flow against the median annual flood. A guide to how unusual the river is, not a flood warning.</div>`;
}
async function showWorks(p, id) {
  const seq = ++panelSeq; panel.style.display = "block"; sel = null; redraw(); doc.innerHTML = `<span class="dim">…</span>`;
  const d = await rpc("works_dossier", { p_id: id }); if (seq !== panelSeq) return; if (!d || !d.works) { doc.innerHTML = `<span class="dim">no data</span>`; return; }
  const w = d.works, L = d.latest || [], nm = x => x.c ? `${x.c}${x.v ?? ""}` : Number(x.v).toPrecision(3);
  doc.innerHTML = `<div class="kick">Sewage treatment works</div><h1>${esc(w.name || "Unnamed works")}</h1>
    <div class="dim">${esc(w.company || "water company not identified")}${w.permit ? " · permit " + esc(w.permit) : ""}${tag("company_reported")}</div>
    <h2>Treated sewage is discharged to</h2><div><span class="big">${esc(w.receiving || "unknown")}</span>${w.river ? ` · <a href="#${esc(w.river.slug)}">${esc(w.river.name)}</a>` : ""}${w.stretch ? `<br><a href="#stretch-${w.stretch.id}">${esc(w.stretch.name)}</a>` : ""}</div>
    <h2>Effluent monitoring</h2>
    ${w.measured ? (L.length ? `<div class="dim" style="margin-bottom:4px">Operator self-monitoring, latest result for each measure</div>${L.map(x => `<div class="bar"><span class="n" style="width:15em">${esc(x.name)}</span><span style="flex:1"><b>${nm(x)}</b> ${esc(x.u || "")}</span><span class="dim">${day(x.at)}</span></div>`).join("")}` : `<div>The effluent is monitored, but no result is held since 2025.</div>`) : `<div>No effluent monitoring point was found for this works in the Environment Agency archive.</div>`}
    ${d.overflows_near?.length ? `<h2>Storm overflows within 500 m${tag("company_reported")}</h2><ul>${d.overflows_near.slice(0, 6).map(o => `<li>${esc(o.name || "overflow")} <span class="dim">${o.status === "discharging" ? "discharging now" : esc(String(o.status).replace("_", " "))}${o.spills != null ? " · " + nf(o.spills) + " spills in 2025" : ""}</span></li>`).join("")}</ul>` : ""}`;
}
function showZone(p) {
  panelSeq++; panel.style.display = "block"; sel = null; redraw();
  doc.innerHTML = `<div class="kick">Danger zone</div><h1>${p.z === "FZ3" ? "Flood zone 3" : "Flood zone 2"}</h1><div class="dim">Environment Agency flood map${tag("regulator_assessment")}</div>
    <p>${p.z === "FZ3" ? "Land with a high probability of flooding from rivers or the sea." : "Land with a medium probability of flooding from rivers or the sea."}</p>
    <h2>Shown because of</h2><div>${esc(p.r || "")}</div>`;
}
function showOutlook(p) {
  panelSeq++; panel.style.display = "block"; sel = null; redraw();
  doc.innerHTML = `<div class="kick">Flood outlook</div><h1>${esc(p.n)}</h1><div class="dim">Flood Forecasting Centre, five days${tag("regulator_assessment")}</div>
    <h2>Risk of flooding</h2><div class="rks">${riskChips(p.d)}</div>
    <div class="dim" style="margin-top:12px">Highest of river, surface water, sea and groundwater flooding for the county or unitary authority. Planning guidance, not public advice during a flood.</div>`;
}
function showWarning(p) {
  panelSeq++; panel.style.display = "block"; sel = null; redraw();
  doc.innerHTML = `<div class="kick">${({ 1: "Severe flood warning", 2: "Flood warning", 3: "Flood alert" })[p.sv] || "Flood alert"}</div><h1>${esc(p.n)}</h1><div class="dim">Environment Agency${tag("regulator_assessment")}</div><p style="white-space:pre-line">${esc(p.m || "")}</p>`;
}
let panelSeq = 0;
const panel = $("#panel"), doc = $("#doc");
function closePanel() { panelSeq++; panel.style.display = "none"; sel = null; history.replaceState(null, "", location.pathname + location.search); redraw(); }
$("#x").onclick = closePanel;
const tag = ev => ev && EV[ev] ? `<span class="tag" title="${esc(EV[ev].about)}">${esc(EV[ev].label)}</span>` : "";
const lad = (r, si) => { const n = si != null && SIGS[si] ? SIGS[si].words.length : 4; return `<span class="lad ${r ? "" : "none"}" aria-hidden="true">${Array.from({ length: n }, (_, k) => `<i style="${k + 1 <= r ? "background:" + colOf(si ?? 0, r) : ""}"></i>`).join("")}</span>`; };
function panelNote(p) { panelSeq++; panel.style.display = "block"; sel = null; redraw(); doc.innerHTML = `<h1>${esc(p.n || "Watercourse")}</h1><p class="dim">A watercourse segment that is not part of a classified stretch (tidal, canal, lake or small stream), so there is no condition data for it.</p>${p.r ? `<p><a href="#${esc(p.r)}">Open the whole river →</a></p>` : ""}`; }
function showPoint(code, p, id) {
  if (code === "gauges") return showGauge(p, id); if (code === "sewage_works") return showWorks(p, id);
  panelSeq++; panel.style.display = "block"; const river = p.rv ? `<h2>River</h2><a href="#${esc(p.rv)}">${esc(p.rn)}</a>` : "";
  if (code === "overflows") doc.innerHTML = `<h1>${esc(p.n || "storm overflow")}</h1><div class="dim">${esc(p.co || "")}${tag("company_reported")}</div>
    <div class="kick" style="margin-top:-2px">Storm overflow</div><h2>Now</h2><div class="big">${p.st === "discharging" ? `<b style="color:var(--c4)">Discharging</b>` : p.st === "not_discharging" ? "Not discharging" : "Monitor " + esc(p.st) + " (unknown, not zero)"}</div>
    ${p.since ? `<div class="dim">since ${when(p.since)}</div>` : ""}${p.ls ? `<div class="dim">last event ${when(p.ls)} to ${p.le ? when(p.le) : "ongoing"}</div>` : ""}
    <h2>Into</h2><div>${esc(p.rw || "unknown")}</div>${p.sp != null ? `<h2>2025</h2><div>${nf(p.sp)} spills · ${nf(p.hr || 0)} hours</div>` : ""}${river}
    <p class="dim" style="margin-top:16px">${p.mon ? "Monitored by an event duration monitor. " : "No live monitor reporting. "}Company-reported and unaudited. Reported ${when(p.rep)}.</p>`;
  else if (code === "bathing") doc.innerHTML = `<h1>${esc(p.n)}</h1><div class="dim">${esc(p.wt || "bathing water")}${tag("regulator_assessment")}</div>
    <h2>Official classification</h2><div class="big">${esc(p.cl || "none")} ${p.cy || ""}</div>
    <h2>Last sample</h2><div>${p.at ? day(p.at) : "none"}${p.ec != null || p.cn ? ` · E. coli ${p.cn || ""}${p.ec ?? ""} per 100 ml` : ""}${tag("official_monitoring")}</div>${river}
    <p class="dim" style="margin-top:16px">Official classification and latest sample. Not swim advice.</p>`;
  else doc.innerHTML = `<h1>${esc(p.n)}</h1><div class="dim">${esc(code.replace(/s$/, ""))}${tag("citizen_science")}</div>${p.wb ? `<h2>Waterbody</h2><div>${esc(p.wb)}</div>` : ""}${river}<p class="dim" style="margin-top:16px">Source: OpenStreetMap contributors.</p>`;
}

const ST = { high: "high", good: "good", moderate: "moderate", poor: "poor", bad: "bad", pass: "pass", fail: "fail", supports_good: "supports good", does_not_support_good: "does not support good", not_assessed: "not assessed" };
const stw = x => ST[x] || String(x || "").replace(/_/g, " ");
const RK = { high: 1, good: 2, moderate: 3, poor: 4, bad: 5 };
// ── the panel shows one dataset (or all of them when none is selected)
const DS = { chemical: "chemical", ecological: "ecology", sewage_pressure: "sewage", agricultural_pressure: "farming", algal_visual: "algae", flow: "flow" };
const showD = c => sigI < 0 || SIGS[sigI].code === c;
const cond = S => SIGS.map((s, i) => { if (sigI >= 0 && i !== sigI) return ""; const g = S[s.code], rk = g?.rank || 0;
  return `<div class="sig"><div class="top"><span class="nm">${esc(s.label)}</span><span class="wd">${lad(rk, i)} <span class="big">${word(i, rk)}</span> ${ARROW[g?.trend] || ""}</span>${tag(g?.evidence)}</div>${g?.summary ? `<div class="why">${esc(g.summary)}</div>` : ""}</div>`; }).join("");
const bandChip = b => `<span class="rk r${Math.max(0, BAND.indexOf(b) - 1)}" style="padding:0 6px">${esc(b)}</span>`;
const gaugeLine = g => `<div style="margin:3px 0"><a href="#gauge-${g.id}"><b>${esc(g.name)}</b></a> ${bandChip(g.band)}<br><span class="dim">${g.stage != null ? g.stage + " m" : ""}${g.stage != null && g.flow != null ? " · " : ""}${g.flow != null ? Number(g.flow).toPrecision(3) + " m³/s" : ""}${g.pct != null ? " · " + ordn(g.pct) + " percentile" : ""} · ${when(g.at)}</span></div>`;
const warnHtml = w => w?.length ? `<h2>Active flood warnings${tag("regulator_assessment")}</h2>${w.map(x => `<div style="margin:4px 0"><b style="color:var(--c4)">${({ 1: "Severe warning", 2: "Warning", 3: "Alert" })[x.sv] || "Alert"}</b> ${esc(x.name)}<div class="dim" style="white-space:pre-line">${esc(x.message || "")}</div></div>`).join("")}` : "";
const dangerHtml = d => d?.length ? `<h2>Danger zone</h2><div>The expected flood plain is drawn in red on the map because of: ${d.map(esc).join("; ")}.</div>` : "";
const outlookHtml = (days, area) => days ? `<h2>Flood outlook, ${esc(area)}${tag("regulator_assessment")}</h2><div class="rks">${riskChips(days)}</div>` : "";
const apHtml = ap => ap.length ? `<h2>Where the phosphorus comes from${tag("modelled")}</h2>${ap.map(a => `<div class="bar"><span class="n">${esc(a.sector.replace(/_/g, " "))}</span><i style="width:${Math.max(2, a.share * 1.6)}px"></i><span class="v">${a.share}%</span></div>`).join("")}` : "";
const sourcesHtml = src => { const k = sigI < 0 ? null : DS[SIGS[sigI].code], l = (src || []).filter(x => k ? (x.ds || []).some(d => d === k || d === "all") : true);
  return l.length ? `<details><summary>Data and licences</summary><div class="dim">${l.map(s => `${esc(s.name)} ${tag(s.evidence)} ${esc(s.licence || "")}`).join("<br>")}</div></details>` : ""; };

async function openStretch(id) {
  const seq = ++panelSeq; panel.style.display = "block"; doc.innerHTML = `<span class="dim">…</span>`; history.replaceState(null, "", location.search + "#stretch-" + id);
  sel = { key: "w:" + id, id }; redraw();
  rpc("stretch_geom", { p_id: id }).then(g => { if (!g || !g.geometry || !sel || sel.id !== id) return; const path = new Path2D(); for (const ln of lines(g.geometry)) ln.forEach((c, i) => { const p = proj(c); i ? path.lineTo(p[0], p[1]) : path.moveTo(p[0], p[1]); }); sel.path = path; sel.bbox = g.properties.bbox; redraw(); });
  const d = await rpc("stretch_dossier", { p_id: id }); if (seq !== panelSeq) return; if (!d || !d.stretch) { doc.innerHTML = `<span class="dim">no data</span>`; return; }
  const t = d.stretch, S = d.signals || {}, o = d.overflows || {}, r = t.river, fl = d.flow;
  const ap = (d.apportionment || []).filter(a => a.pollutant === "phosphorus").map(a => ({ sector: a.sector, share: a.share }));
  const reasonHtml = re => { const l = (d.reasons || []).filter(x => re.test(x.sector || "")); return l.length ? `<h2>The regulator's reasons for not achieving good${tag("regulator_assessment")}</h2><ul>${l.map(x => `<li>${esc(x.sector || "")}${x.activity && x.activity !== "Not applicable" ? " · " + esc(x.activity) : ""} <span class="dim">${esc(x.element || "")}</span></li>`).join("")}</ul>` : ""; };
  const cl = (codes, title) => { const rows = (d.classes || []).filter(c => codes.includes(c.code)); return rows.length ? `<h2>${title}${tag("regulator_assessment")}</h2>${rows.map(c => { const ch = c.prev && c.prev !== c.status && RK[c.prev] && RK[c.status] ? (RK[c.status] < RK[c.prev] ? " ↗" : " ↘") : "";
    return `<div class="bar"><span class="n" style="width:13em">${esc(c.label)}</span><span style="flex:1"><b>${stw(c.status)}</b>${ch}${c.prev && c.prev !== c.status ? ` <span class="dim">was ${stw(c.prev)}</span>` : ""}</span><span class="dim">${c.year}</span></div>`; }).join("")}` : ""; };
  const near = !d.readings.length && d.readings_near.length, rd = near ? d.readings_near : d.readings, nm = x => x.c ? `${x.c}${x.v ?? ""}` : (x.v >= 100 ? Math.round(x.v) : Number(x.v).toPrecision(3));
  const readings = `<h2>${near ? "Nearest monitoring" : "Latest readings"}${tag("official_monitoring")}</h2>` + (rd.length ? `${near ? `<div class="dim" style="margin-bottom:4px">No recent sampling on this stretch. Nearest is ${esc(rd[0].site)}, ${rd[0].km} km away, and may be on a different watercourse.</div>` : `<div class="dim" style="margin-bottom:4px">${esc(rd[0].site)}${new Set(rd.map(x => x.site)).size > 1 ? " and others" : ""}</div>`}${rd.map(x => `<div class="bar"><span class="n" style="width:15em">${esc(x.name)}</span><span style="flex:1"><b>${nm(x)}</b> ${esc(x.u || "")}</span><span class="dim">${day(x.at)}</span></div>`).join("")}` : `<div class="dim">No monitoring on or near this stretch in the data we hold.</div>`);
  const bathing = d.bathing?.length ? `<h2>Bathing${tag("regulator_assessment")}</h2>${d.bathing.map(b => `<div>${esc(b.name)} · ${esc(b.class || "none")} ${b.year || ""}${b.ecoli != null ? ` · E. coli ${b.censor || ""}${b.ecoli}` : ""}</div>`).join("")}<div class="dim">Official classification. Not swim advice.</div>` : "";
  const c = d.citizen || {};
  const secs = {
    chemical: readings + cl(["chemical", "phosphate", "ammonia", "dissolved_oxygen", "ph", "temperature", "sac_phosphorus"], "Official classification") + bathing,
    ecological: cl(["ecological", "fish", "invertebrates", "macrophytes_phytobenthos"], "Official classification") + (c.riverfly_24m ? `<h2>Riverfly surveys${tag("citizen_science")}</h2><div>${nf(c.riverfly_24m)} in two years, ${nf(c.riverfly_breaches_24m)} breaches</div>` : ""),
    sewage_pressure: (o.n ? `<h2>Overflows${tag("company_reported")}</h2><div><b>${nf(o.n)}</b> in this stretch's catchment, <b>${nf(o.on_stretch)}</b> directly on it${o.discharging ? ` · <b style="color:var(--c4)">${o.discharging} discharging now</b>` : ""} · ${nf(o.spills_2025)} spills in 2025</div><ul>${o.worst.map(w => `<li>${esc(w.name || "overflow")}<br><span class="dim">${esc(w.company || "")} · ${nf(w.spills)} spills · ${nf(w.hours)} h</span></li>`).join("")}</ul>` : "")
      + (d.works?.length ? `<h2>Sewage works discharging here${tag("company_reported")}</h2>${d.works.slice(0, 8).map(w => `<div><a href="#works-${w.id}">${esc(w.name || "works")}</a> <span class="dim">${w.measured ? "effluent monitored" : "not monitored"}</span></div>`).join("")}` : "") + apHtml(ap) + reasonHtml(/water industry/i),
    agricultural_pressure: (sigI < 0 ? "" : apHtml(ap)) + reasonHtml(/agricult/i),
    algal_visual: c.brw_36m ? `<h2>Big River Watch${tag("citizen_science")}</h2><div>${nf(c.brw_36m)} surveys in three years, ${nf(c.unhealthy_36m)} called the river unhealthy</div>` : `<div class="dim" style="margin-top:8px">No citizen surveys on this stretch.</div>`,
    flow: (fl ? (fl.method === "estimated" ? `<h2>Estimated from nearby gauges${tag("modelled")}</h2><div class="dim" style="margin-bottom:4px">No gauge on this river here. Each gauge's flow for the time of year is combined, weighted by closeness. ${esc(fl.confidence || "")} confidence.</div>${(fl.donors || []).map(x => `<div style="margin:3px 0"><a href="#gauge-${x.gauge}"><b>${esc(x.name)}</b></a> <span class="dim">${x.km} km · ${ordn(x.pct)} percentile</span></div>`).join("")}`
        : `<h2>Gauge used for this reading</h2><div><a href="#gauge-${fl.gauge}"><b>${esc(fl.gauge_name)}</b></a> <span class="dim">${fl.on_stretch ? "on this stretch" : fl.km_along_river + " km away on the same river"} · ${ordn(fl.pct)} percentile for the time of year</span></div>`)
      : `<div class="dim" style="margin-top:8px">No gauge within reach, so there is no flow reading.</div>`)
      + (d.gauges?.length ? `<h2>Gauges on this stretch${tag("official_monitoring")}</h2>${d.gauges.map(gaugeLine).join("")}` : "") + outlookHtml(d.outlook?.days, d.outlook?.area) + warnHtml(d.warnings) + dangerHtml(d.danger)
  };
  doc.innerHTML = `<div class="kick">Stretch${r ? ` of <a href="#${esc(r.slug)}">${esc(r.name)}</a>` : ""}</div><h1>${esc(t.name)}</h1>
    <div class="dim">${t.km} km${t.catchment ? " · " + esc(t.catchment) : ""}</div>
    <h2>${sigI < 0 ? "Condition" : esc(SIGS[sigI].label)}</h2>${cond(S)}
    ${sigI < 0 ? cl(["overall"], "Overall classification") : ""}
    ${SIGS.map(s => showD(s.code) ? secs[s.code] || "" : "").join("")}
    ${r ? `<h2>The whole river</h2><div><a href="#${esc(r.slug)}" class="big">${esc(r.name)}, ${r.km} km →</a></div>` : ""}`;
}
const geomCache = new Map();
async function openRiver(slug, fitTo) {
  const seq = ++panelSeq; panel.style.display = "block"; doc.innerHTML = `<span class="dim">…</span>`; history.replaceState(null, "", location.search + "#" + slug);
  rpc("river_geom", { p_slug: slug }).then(g => {
    if (!g || !g.geometry) return; const path = new Path2D(); for (const ln of lines(g.geometry)) ln.forEach((c, i) => { const p = proj(c); i ? path.lineTo(p[0], p[1]) : path.moveTo(p[0], p[1]); });
    sel = { key: "r:" + slug, slug, path, bbox: g.properties.bbox }; redraw(); if (fitTo !== false) zoomToBox(g.properties.bbox);
  });
  const d = await rpc("river_dossier", { p_slug: slug }); if (seq !== panelSeq) return; if (!d || !d.river) { doc.innerHTML = `<span class="dim">no data</span>`; return; }
  const r = d.river, S = d.signals || {}, o = d.overflows, c = d.citizen || {};
  const ap = (d.apportionment || []).filter(a => a.pollutant === "phosphorus" && a.share_pct >= 1).map(a => ({ sector: a.sector, share: a.share_pct }));
  const reasons = {}; (d.waterbodies || []).forEach(w => Object.entries(w.reasons || {}).forEach(([k, n]) => reasons[k] = (reasons[k] || 0) + n));
  const reasonHtml = re => { const l = Object.entries(reasons).filter(([k]) => re.test(k)).sort((a, b) => b[1] - a[1]); return l.length ? `<h2>The regulator's named reasons for failure${tag("regulator_assessment")}</h2><div>${l.map(([k, n]) => `${esc(k.replace(/_/g, " "))} ${n}`).join(" · ")}</div>` : ""; };
  const stretches = codes => { if (sigI < 0 && codes.length < SIGS.length) return ""; const idx = codes.map(cd => SIGS.findIndex(s => s.code === cd)), worst = w => Math.max(0, ...codes.map(cd => w.signals[cd]?.rank || 0));
    const list = [...(d.waterbodies || [])].sort((a, b) => worst(b) - worst(a)); if (!list.length) return "";
    return `<details${sigI >= 0 ? " open" : ""}><summary>Stretches (${list.length})</summary>${list.map(w => `<div class="st"><div><a href="#stretch-${w.id}">${esc(w.name)}</a> <span class="dim">${w.km} km</span></div><div class="l">${codes.map((cd, k) => { const g = w.signals[cd]; return g ? `<span title="${esc(g.summary || "")}">${lad(g.rank, idx[k])} <span class="dim">${esc(SIGS[idx[k]].label)}${sigI >= 0 ? " " + esc(word(idx[k], g.rank)) : ""}</span></span>` : ""; }).join("")}</div></div>`).join("")}</details>`; };
  const overflows = o?.count ? `<h2>Overflows upstream${tag("company_reported")}</h2><div><b>${nf(o.count)}</b>${o.discharging_now ? ` · <b style="color:var(--c4)">${o.discharging_now} discharging now</b>` : ""}${o.offline ? ` · ${o.offline} monitors offline` : ""} · ${nf(o.spills_2025)} spills · ${nf(o.hours_2025)} hours in 2025</div><ul>${o.worst.map(w => `<li>${esc(w.name || w.receiving)}<br><span class="dim">${esc(w.company || "")} · ${nf(w.spills)} spills · ${nf(w.hours)} h</span></li>`).join("")}</ul>` : "";
  const bathing = d.bathing?.length ? `<h2>Bathing waters${tag("regulator_assessment")}</h2><ul>${d.bathing.map(b => `<li>${esc(b.name)} · ${esc(b.class || "none")} ${b.year || ""}${b.ecoli != null ? ` · E. coli ${b.censor || ""}${b.ecoli}` : ""}</li>`).join("")}</ul><div class="dim">Official classification. Not swim advice.</div>` : "";
  const gauges = d.gauges?.length ? `<h2>Gauges${tag("official_monitoring")}</h2>${d.gauges.map(gaugeLine).join("")}` : `<div class="dim" style="margin-top:8px">No gauges on this river.</div>`;
  const sci = (d.research || []).filter(x => x.confidence >= 0.65);
  const secs = {
    chemical: stretches(["chemical"]) + bathing,
    ecological: stretches(["ecological"]) + (c.riverfly_24m ? `<h2>Riverfly surveys${tag("citizen_science")}</h2><div>${nf(c.riverfly_24m)} in two years, ${nf(c.riverfly_breaches_24m)} breaches</div>` : ""),
    sewage_pressure: overflows + apHtml(ap) + reasonHtml(/water_industry/) + stretches(["sewage_pressure"]),
    agricultural_pressure: (sigI < 0 ? "" : apHtml(ap)) + reasonHtml(/agriculture/) + stretches(["agricultural_pressure"]),
    algal_visual: (c.big_river_watch_36m ? `<h2>Big River Watch${tag("citizen_science")}</h2><div>${nf(c.big_river_watch_36m)} surveys in three years, ${nf(c.unhealthy_36m)} unhealthy</div>` : "") + stretches(["algal_visual"]),
    flow: gauges + (d.outlook?.length ? `<h2>Flood outlook${tag("regulator_assessment")}</h2>${d.outlook.map(a => `<div style="margin:3px 0"><b>${esc(a.area)}</b><div class="rks">${riskChips(a.days)}</div></div>`).join("")}` : "") + warnHtml(d.warnings) + dangerHtml(d.danger) + stretches(["flow"])
  };
  doc.innerHTML = `<div class="kick">River</div><h1>${esc(r.name)}${r.name_cy ? ` <span class="dim">· ${esc(r.name_cy)}</span>` : ""}</h1>
    <div class="dim">${r.length_km} km${r.parent ? ` · joins <a href="#${esc(r.parent.slug)}">${esc(r.parent.name)}</a>` : ""} · ${nf(r.tributaries)} tributaries</div>
    <h2>${sigI < 0 ? "Condition" : esc(SIGS[sigI].label)}</h2>${cond(S)}
    ${SIGS.map(s => showD(s.code) ? secs[s.code] || "" : "").join("")}
    ${sigI < 0 ? stretches(SIGS.map(s => s.code)) : ""}
    ${sigI < 0 && sci.length ? `<details open><summary>Science (${sci.length})</summary><div class="dim" style="margin-bottom:4px">Linked automatically. Not reviewed by this project.${tag("published_research")}</div><ul>${sci.map(s => `<li><a href="${esc(s.url)}" target="_blank" rel="noopener">${esc(s.title)}</a><br><span class="dim">${esc((s.authors || []).join(", "))} · ${s.year}${s.licence ? " · " + esc(s.licence) : ""}</span></li>`).join("")}</ul></details>` : ""}
    ${sourcesHtml(d.sources)}`;
}
function zoomToBox(b) {
  if (!b) return; const a = proj([b[0], b[3]]), c = proj([b[2], b[1]]), pw = W > 700 ? Math.min(430, W) : 0, ph = W > 700 ? 0 : H * 0.62, aw = W - pw - 60, ah = H - ph - 100;
  const k = Math.max(1, Math.min(300, 0.9 * Math.min(aw / (c[0] - a[0] || 1), ah / (c[1] - a[1] || 1)))), cx = (a[0] + c[0]) / 2, cy = (a[1] + c[1]) / 2;
  d3.select(cv).transition().duration(700).call(zoomB.transform, d3.zoomIdentity.translate(aw / 2 + 30 - k * cx, ah / 2 + 56 - k * cy).scale(k));
}
function setView(lon, lat, z) { const p = proj([lon, lat]), k = 2 ** z / (2 * Math.PI * s0 / 256); d3.select(cv).call(zoomB.transform, d3.zoomIdentity.translate(W / 2 - k * p[0], H / 2 - k * p[1]).scale(k)); }
let urlT = 0;
function syncUrl() { clearTimeout(urlT); urlT = setTimeout(() => { const c = proj.invert([(W / 2 - T.x) / T.k, (H / 2 - T.y) / T.k]); const q = new URLSearchParams(location.search); q.set("v", c[0].toFixed(4) + "," + c[1].toFixed(4) + "," + tzf().toFixed(2)); history.replaceState(null, "", "?" + q + location.hash); }, 400); }
const flyTo = (x, y, z) => { const p = proj([x, y]), k = Math.max(T.k, 2 ** (z - Math.log2(2 * Math.PI * s0 / 256))); d3.select(cv).transition().duration(600).call(zoomB.transform, d3.zoomIdentity.translate(W / 2 - k * p[0], H / 2 - k * p[1]).scale(k)); };
const route = (fit) => { const s = location.hash.slice(1); if (!s) return; if (s.startsWith("stretch-")) openStretch(+s.slice(8)); else if (s.startsWith("gauge-")) showGauge({}, +s.slice(6)); else if (s.startsWith("works-")) showWorks({}, +s.slice(6)); else openRiver(s, fit); };
addEventListener("hashchange", () => route(true));

// ───────────────────────── this-view card: the latest data about the area on screen
const view = $("#view"), vin = view.querySelector(".in"); let vt = 0, vseq = 0;
function scheduleView() { clearTimeout(vt); vt = setTimeout(loadView, 450); }
async function loadView() {
  const b = bbox(), seq = ++vseq;
  if (b[2] - b[0] > 4.5 || b[3] - b[1] > 3.5) { view.style.display = "none"; $("#status").textContent = tz() >= 5 ? "zoom in for local detail" : ""; return; }
  $("#status").textContent = "";
  const d = await rpcGet("area_summary", { p_minx: b[0], p_miny: b[1], p_maxx: b[2], p_maxy: b[3] }).catch(() => null);
  if (!d || d.too_wide || seq !== vseq) return;
  const o = d.overflows || {}, g = d.gauges || {}, ct = d.counts || {}, st = d.stretches || {}, wk = d.works || {}, ol = d.outlook || [], wn = d.warnings || [], gb = g.bands || {};
  const bar = (code, i) => { const a = st[code] || [], tot = a.reduce((x, y) => x + y, 0); if (!tot) return ""; const n = SIGS[i].words.length;
    return `<div style="display:flex;align-items:center;gap:6px;margin:2px 0;cursor:pointer;${i === sigI ? "font-weight:600" : ""}" data-sig="${i}"><span style="width:4.2em">${esc(SIGS[i].label)}</span><span style="display:flex;flex:1;height:9px">${[...Array(n).keys()].map(k => k + 1).concat(0).map(k => `<i style="width:${100 * (a[k] || 0) / tot}%;background:${colOf(i, k)}"></i>`).join("")}</span></div>`; };
  const n = d.towns?.length ? d.towns.slice(0, 3).join(", ") : (d.parks?.[0] || "this view");
  view.querySelector("summary").innerHTML = `${esc(n)} <span class="dim">· ${nf(o.n || 0)} overflows${o.discharging ? `, <b style="color:var(--c4)">${o.discharging} discharging</b>` : ""}</span>`;
  vin.innerHTML = `${d.parks?.length ? `<div class="dim" style="color:#2e6b49">${esc(d.parks.join(", "))}</div>` : ""}
    <h3>River stretches in view</h3>${SIGS.map((s, i) => bar(s.code, i)).join("")}<div class="dim" style="font-size:11px">click a row to colour the rivers by it</div>
    <h3>Rivers</h3>${(d.rivers || []).map(r => `<div><a href="#${esc(r.slug)}"><i class="bgd" style="background:${colOf(sigI, sigI < 0 ? 0 : +r.s[sigI] || 0)}"></i>${esc(r.n)}</a> <span class="dim">${r.km} km</span></div>`).join("") || `<span class="dim">none</span>`}
    ${o.n ? `<h3>Overflows${tag("company_reported")}</h3><div>${nf(o.n)} · ${nf(o.discharging)} discharging · ${nf(o.offline)} offline</div>${(o.worst || []).slice(0, 3).map(w => `<div class="dim" style="cursor:pointer" data-fly="${w.x},${w.y}">${esc(w.n)} · ${nf(w.sp)} spills</div>`).join("")}` : ""}
    ${wn.length ? `<h3>Flood warnings${tag("regulator_assessment")}</h3>${wn.map(w => `<div><b style="color:var(--c4)">${({ 1: "Severe warning", 2: "Warning", 3: "Alert" })[w.sv] || "Alert"}</b> ${esc(w.n)}</div>`).join("")}` : ""}
    ${ol.length ? `<h3>Flood outlook, five days${tag("regulator_assessment")}</h3>${ol.slice(0, 4).map(a => `<div>${esc(a.n)} <span class="dim">${String(a.d).split(",").map(x => RISK[x] || x).join(" · ")}</span></div>`).join("")}` : ""}
    ${g.n ? `<h3>Gauges, flood index${tag("official_monitoring")}</h3><div>${BAND.map((b, i) => gb[b] ? `<span style="margin-right:8px"><i class="bgd" style="background:${GB[i + 1]}"></i>${gb[b]} ${b}</span>` : "").join("")}</div>${(g.extreme || []).slice(0, 3).map(e => `<div class="dim" style="cursor:pointer" data-fly="${e.x},${e.y}">${esc(e.n)} · ${esc(e.bd)}${e.lv != null ? " · " + e.lv + " m" : ""}${e.q != null ? " · " + Number(e.q).toPrecision(3) + " m³/s" : ""}</div>`).join("")}` : ""}
    ${wk.n ? `<h3>Sewage works${tag("company_reported")}</h3><div>${nf(wk.n)} treatment works · ${nf(wk.measured)} with effluent monitoring</div>` : ""}
    ${d.bathing?.length ? `<h3>Bathing${tag("regulator_assessment")}</h3>${d.bathing.slice(0, 5).map(b => `<div style="cursor:pointer" data-fly="${b.x},${b.y}">${esc(b.n)} <span class="dim">${esc(b.cl || "")}</span></div>`).join("")}` : ""}
    ${Object.keys(ct).length ? `<h3>Places</h3><div class="dim">${Object.entries(ct).map(([k, v]) => `${nf(v)} ${k}`).join(" · ")}</div>` : ""}`;
  view.style.display = "block";
}
vin.addEventListener("click", e => { const s = e.target.closest("[data-sig]"); if (s) { pickSignal(+s.dataset.sig); return; } const f = e.target.closest("[data-fly]"); if (f) { const [x, y] = f.dataset.fly.split(",").map(Number); flyTo(x, y, 13); } });

// ───────────────────────── weather: rain (radar now, forecast later) and pressure (isobars). One call per chosen time.
const WX = { d: null, img: null, rb: null, path: null, major: null, labels: [], times: [], idx: -1, at: null, seq: 0 }, IMGS = new Map();
const RAIN = [["#e2daf0", "0.1"], ["#b090d0", "1"], ["#6a3fa0", "4"], ["#2e1260", "16"]];
const wxt = t => { const d = new Date(t), fc = d - Date.now() > 3600e3; return d.toLocaleString("en-GB", fc ? { weekday: "short", hour: "2-digit", minute: "2-digit" } : { hour: "2-digit", minute: "2-digit" }); };
const wxOn = () => on.rain || on.pressure;
function loadWx() {
  if (!wxOn()) { wxUI(); legendUI(); redraw(); return; }
  const seq = ++WX.seq;
  rpc("weather", WX.at ? { p_at: WX.at } : {}).then(d => {
    if (seq !== WX.seq) return;
    WX.d = d; WX.times = d.times || [];
    WX.rb = d.rain?.bbox || null; WX.img = null;
    if (d.rain) { let im = IMGS.get(d.rain.path); if (!im) { im = new Image(); im.onload = redraw; im.src = (RC.media || "") + d.rain.path; IMGS.set(d.rain.path, im); if (IMGS.size > 60) IMGS.delete(IMGS.keys().next().value); } WX.img = im; }
    WX.path = new Path2D(); WX.major = new Path2D(); WX.labels = [];
    for (const ln of d.pressure?.lines || []) { const maj = ln.l % 4 === 0, tg = maj ? WX.major : WX.path;
      for (const seg of ln.g) { seg.forEach(([lo, la], i) => { const p = proj([lo, la]); i ? tg.lineTo(p[0], p[1]) : tg.moveTo(p[0], p[1]); });
        if (maj && seg.length > 20) { const q = proj(seg[seg.length >> 1]); WX.labels.push({ px: q[0], py: q[1], t: String(ln.l) }); } } }
    wxUI(); legendUI(); redraw();
  }).catch(e => console.error("weather", e));
}
function wxUI() {
  const el = $("#wx"), r = $("#wxt");
  if (!wxOn() || !WX.times.length) { el.style.display = "none"; return; }
  const live = WX.times.map(t => t.kind).lastIndexOf("radar"); r.max = WX.times.length - 1;
  if (WX.at == null) r.value = live;
  el.style.display = "block"; wxLabel();
}
function wxLabel() {
  const i = +$("#wxt").value, t = WX.times[i]; if (!t) return;
  $("#wxl").innerHTML = `${t.kind === "radar" ? "" : "forecast · "}${wxt(t.at)}${WX.at != null ? ` <button id="wxnow">now</button>` : ""}`;
}
function wxInit() {
  const r = $("#wxt"); let t = 0;
  r.addEventListener("input", () => { const i = +r.value, live = WX.times.map(x => x.kind).lastIndexOf("radar"); WX.at = i === live ? null : WX.times[i].at; wxLabel(); clearTimeout(t); t = setTimeout(loadWx, 120); });
  $("#wx").addEventListener("click", e => { if (e.target.id === "wxnow") { WX.at = null; loadWx(); } });
  setInterval(() => { if (WX.at == null && wxOn()) loadWx(); }, 300000);
  if (wxOn()) loadWx();
}

// ───────────────────────── controls
function legendUI() {
  const row = [], flow = sigI >= 0 && SIGS[sigI].code === "flow";
  if (sigI < 0) row.push(`<span><i style="border-color:${NEUTRAL};border-top-width:3px"></i>river</span><span class="dim">width = river size</span>`);
  else row.push(SIGS[sigI].words.map((t, i) => `<span><i style="border-color:${colOf(sigI, i + 1)};border-top-width:${flow ? 3 : 2 + i}px"></i>${esc(t)}</span>`).join("") + `<span><i style="border-color:${COL[0]}"></i>${flow ? "no gauge nearby" : "no data"}</span><span class="dim">width = river size</span>`);
  if (on.gauges) row.push(`<span class="lg"><b>gauges</b>${BAND.map((b, i) => `<span><i class="bgd" style="background:${GB[i + 1]}"></i>${b}</span>`).join("")}</span>`);
  if (on.overflows || on.sewage_works) row.push(`<span class="lg"><b>sewage</b>${on.overflows ? `<span><i class="dot" style="background:${COL[4]}"></i>overflow discharging</span><span><i class="dot" style="background:#cf8b80"></i>monitored</span><span><i class="dot ring"></i>unmonitored</span>` : ""}${on.sewage_works ? `<span><i class="sq" style="background:${SEWAGE}"></i>works, effluent monitored</span><span><i class="sq ring"></i>not monitored</span>` : ""}</span>`);
  if (zonesShown) row.push(`<span class="lg"><b>flood risk</b><span><i class="sq" style="background:rgba(179,32,42,.35);border:1px solid #b3202a"></i>expected flood plain (danger zone)</span></span>`);
  if (on.flood_outlook) row.push(`<span class="lg"><b>flood risk, 5 days</b>${[["#fff", "very low"], ["#e6c53f", "low"], ["#ee8a3c", "medium"], ["#b3202a", "high"]].map(([c, t]) => `<span><i class="sq" style="background:${c};border:1px solid #bbb"></i>${t}</span>`).join("")}</span>`);
  if (on.rain && WX.d?.rain) { const r = WX.d.rain; row.push(`<span class="lg"><b>rain</b>${RAIN.map(([c, t]) => `<span><i class="sq" style="background:${c}"></i>${t}</span>`).join("")}<span>mm/h</span><span class="dim">${esc(r.source)} · ${wxt(r.valid_at)} · ${r.kind === "radar" ? "Contains Met Office data © Crown copyright" : "Contains ECMWF open data"}</span></span>`); }
  if (on.pressure && WX.d?.pressure) { const p = WX.d.pressure; row.push(`<span class="lg"><b>pressure</b><span><i style="border-color:#504664;border-top-width:1px"></i>isobars, hPa</span><span class="dim">${esc(p.source)} · ${wxt(p.valid_at)}</span></span>`); }
  $("#legend").innerHTML = row.map(r => `<div>${r}</div>`).join("");
}
function sigUI() { $("#sg").querySelectorAll("button").forEach(b => b.setAttribute("aria-pressed", +b.dataset.i === sigI)); legendUI(); }
function setParam(k, v) { const q = new URLSearchParams(location.search); q.set(k, v); history.replaceState(null, "", "?" + q + location.hash); }
function pickSignal(i) { sigI = sigI === i ? -1 : i; setParam("s", sigI < 0 ? "" : SIGS[sigI].code); sigUI(); redraw(); loadView(); const h = location.hash.slice(1); if (h && h !== "!") route(false); }
function buildBar() {
  const GROUPS = [["overlay", "map"], ["weather", "weather"], ["sewage", "sewage"], ["points", "points"]];
  const btn = l => `<button data-l="${l.code}" aria-pressed="${!!on[l.code]}"${l.labels ? ' title="click to show or hide; double-click for names"' : ""}>${esc(l.label)}${l.labels ? `<i class="aa${lab[l.code] ? " on" : ""}" aria-hidden="true">Aa</i>` : ""}</button>`;
  const grp = (g, title) => { const ls = cfg.layers.filter(l => l.group === g); return ls.length ? `<span class="grp"><b>${title}</b>${ls.map(btn).join("")}</span>` : ""; };
  $("#bar").innerHTML = `<span class="grp" id="sg">${SIGS.map((s, i) => `<button data-i="${i}">${esc(s.label)}</button>`).join("")}</span>${GROUPS.map(([g, t]) => grp(g, t)).join("")}<input id="q" type="search" placeholder="river" autocomplete="off" aria-label="search rivers">`;
  $("#sg").addEventListener("click", e => { const i = e.target.dataset?.i; if (i != null) pickSignal(+i); });
  const urlParam = setParam;
  $("#bar").addEventListener("click", e => { const btn0 = e.target.closest("button[data-l]"); if (!btn0) return;
    const l = btn0.dataset.l; if (l) { on[l] = !on[l]; btn0.setAttribute("aria-pressed", on[l]); if (l === "rain" || l === "pressure") loadWx(); legendUI(); const q = new URLSearchParams(location.search); q.set("l", cfg.layers.filter(x => x.group !== "base" && on[x.code]).map(x => x.code).join(",")); history.replaceState(null, "", "?" + q + location.hash); redraw(); } });
  $("#bar").addEventListener("dblclick", e => { const b = e.target.closest("button[data-l]"); if (!b || !LAYERS[b.dataset.l]?.labels) return;
    const c = b.dataset.l; lab[c] = !lab[c]; b.querySelector(".aa").classList.toggle("on", lab[c]); urlParam("n", cfg.layers.filter(x => x.labels && lab[x.code]).map(x => x.code).join(",")); redraw(); });
  let st; const q = $("#q"), hits = $("#hits");
  q.addEventListener("input", () => { clearTimeout(st); st = setTimeout(async () => { const v = q.value.trim(); if (v.length < 2) { hits.style.display = "none"; return; }
    const r = await rpc("search_rivers", { q: v }); hits.innerHTML = r.map(x => `<div data-s="${esc(x.slug)}">${esc(x.name)}${x.name_cy ? " · " + esc(x.name_cy) : ""} <span class="dim">${x.length_km} km${x.parent_name ? " → " + esc(x.parent_name) : ""}</span></div>`).join(""); hits.style.display = r.length ? "block" : "none"; }, 160); });
  hits.addEventListener("click", e => { const s = e.target.closest("[data-s]")?.dataset.s; if (s) { hits.style.display = "none"; q.value = ""; openRiver(s); } });
}
document.addEventListener("keydown", e => { if (e.key === "Escape") { $("#hits").style.display = "none"; closePanel(); } });

// ───────────────────────── boot
function onView() { wanted = new Set(); redraw(); clearTimeout(onView.t); onView.t = setTimeout(() => { prune(); }, 1500); scheduleView(); }
async function boot() {
  size(); fit();
  cfg = await rpc("ui_config", {}); SIGS = cfg.signals; EV = cfg.evidence; cfg.layers.forEach(l => { LAYERS[l.code] = l; on[l.code] = l.on; if (l.labels) lab[l.code] = l.labels_on; });
  const qp = new URLSearchParams(location.search);
  if (qp.get("s") != null) sigI = SIGS.findIndex(x => x.code === qp.get("s"));
  if (qp.get("n") != null) { const w = qp.get("n").split(","); cfg.layers.forEach(l => { if (l.labels) lab[l.code] = w.includes(l.code); }); }
  if (qp.get("l") != null) { const want = qp.get("l").split(","); cfg.layers.forEach(l => { if (l.group !== "base") on[l.code] = want.includes(l.code); }); }
  buildBar(); sigUI(); wxInit();
  zoomB = d3.zoom().scaleExtent([1, 400]).on("zoom", e => { T = e.transform; wanted = new Set(); redraw(); scheduleView(); }).on("end", () => { redraw(); syncUrl(); });
  d3.select(cv).call(zoomB).on("dblclick.zoom", null);
  if (qp.get("card") === "open") view.open = true;
  const v = qp.get("v"); if (v) { const [lo, la, z] = v.split(",").map(Number); setView(lo, la, z); }
  redraw(); setTimeout(redraw, 300);
  route(!v);
}
addEventListener("resize", () => { size(); redraw(); });
boot().catch(e => { document.body.insertAdjacentHTML("beforeend", `<div style="position:absolute;left:14px;top:60px;color:#b3202a">${esc(e.message)}: is the API running?</div>`); console.error(e); });
})();
