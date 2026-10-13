// Pass-through GET proxy for Environment Agency hosts that block the compute's cloud IP (hydrology, linked-data bathing API).
// Streams the upstream body untouched; only environment.data.gov.uk, only GET, only with the shared token.
const TOKEN = Deno.env.get("ETL_PROXY_TOKEN") ?? "";
Deno.serve(async (req) => {
  if (!TOKEN || req.headers.get("x-etl-token") !== TOKEN) return new Response("unauthorised", { status: 401 });
  const target = new URL(req.url).searchParams.get("u") ?? "";
  let u: URL;
  try { u = new URL(target); } catch { return new Response("bad url", { status: 400 }); }
  if (u.protocol !== "https:" || u.hostname !== "environment.data.gov.uk") return new Response("host not allowed", { status: 403 });
  const r = await fetch(u, { headers: { "User-Agent": "riverconditionsuk/0.1 (open-data research)", "Accept": req.headers.get("accept") ?? "*/*" } });
  return new Response(r.body, { status: r.status, headers: { "content-type": r.headers.get("content-type") ?? "application/json", "x-upstream-status": String(r.status) } });
});
