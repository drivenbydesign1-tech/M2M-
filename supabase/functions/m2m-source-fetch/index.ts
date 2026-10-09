// m2m-source-fetch — controlled source fetch with SSRF protections.
//
// Semantic packet item 1. Preview by default: without {"apply": true} the function
// validates, resolves and reports, and never opens a connection to the target.
//
// Defence layers, in order. Each is independent; none is trusted alone.
//   1. POLICY   — public.muon_validate_source_url() in Postgres is the single
//                 source of truth for scheme, port, host shape and allow/deny.
//                 https + 443 + hostname only + deny-by-default.
//   2. RESOLVE  — every A and AAAA record must be publicly routable. A hostname
//                 check alone does not stop an attacker pointing an allowlisted
//                 name at 169.254.169.254.
//   3. REDIRECT — redirect: "manual". Every hop is re-run through layers 1 and 2.
//                 Auto-following is how an allowlisted host becomes a bounce to
//                 the metadata endpoint.
//   4. BUDGET   — byte cap enforced while streaming, plus a wall-clock timeout.
//   5. MINIMAL  — no cookies, no auth headers, no caller headers forwarded.
//
// KNOWN RESIDUAL RISK, stated rather than papered over: Deno's fetch resolves DNS
// itself, so between our resolution check and the connection there is a window in
// which a hostile authoritative server can return a different address (classic DNS
// rebinding TOCTOU). Closing it requires connecting to a pinned IP with SNI/Host
// override, which the runtime does not expose. The allowlist is what actually
// bounds this: rebinding requires control of an allowlisted domain's DNS. Do not
// add an ALLOW rule for a host whose DNS you do not trust.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const MAX_BYTES = 8 * 1024 * 1024;
const TIMEOUT_MS = 15_000;
const MAX_HOPS = 3;

type Verdict = { allowed: boolean; url: string; host: string | null; reasons: string[] };

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function policyCheck(url: string): Promise<Verdict> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/muon_validate_source_url`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify({ p_url: url }),
  });
  if (!r.ok) throw new Error(`policy check unavailable: ${r.status} ${await r.text()}`);
  return await r.json() as Verdict;
}

function ipv4Blocked(ip: string): string | null {
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return "unparseable IPv4";
  const [a, b] = p;
  if (a === 0) return "0.0.0.0/8 this-network";
  if (a === 10) return "10.0.0.0/8 private";
  if (a === 127) return "127.0.0.0/8 loopback";
  if (a === 100 && b >= 64 && b <= 127) return "100.64.0.0/10 CGNAT";
  if (a === 169 && b === 254) return "169.254.0.0/16 link-local / cloud metadata";
  if (a === 172 && b >= 16 && b <= 31) return "172.16.0.0/12 private";
  if (a === 192 && b === 168) return "192.168.0.0/16 private";
  if (a === 192 && b === 0) return "192.0.0.0/24 IETF protocol assignments";
  if (a === 198 && (b === 18 || b === 19)) return "198.18.0.0/15 benchmarking";
  if (a >= 224) return ">=224.0.0.0 multicast / reserved";
  return null;
}

function ipv6Blocked(ip: string): string | null {
  const s = ip.toLowerCase();
  if (s === "::" || s === "::1") return "IPv6 unspecified / loopback";
  // IPv4-mapped and IPv4-compatible: judge the embedded address.
  const m = s.match(/^::(ffff:)?(\d+\.\d+\.\d+\.\d+)$/);
  if (m) return ipv4Blocked(m[2]) ?? "IPv4-mapped IPv6 address";
  const head = parseInt(s.split(":")[0] || "0", 16);
  if ((head & 0xfe00) === 0xfc00) return "fc00::/7 unique local";
  if ((head & 0xffc0) === 0xfe80) return "fe80::/10 link-local";
  if ((head & 0xff00) === 0xff00) return "ff00::/8 multicast";
  return null;
}

async function resolveAndCheck(host: string) {
  const addrs: string[] = [];
  const blocked: Array<{ ip: string; why: string }> = [];
  for (const kind of ["A", "AAAA"] as const) {
    try {
      const rs = await Deno.resolveDns(host, kind);
      for (const ip of rs) {
        addrs.push(ip);
        const why = kind === "A" ? ipv4Blocked(ip) : ipv6Blocked(ip);
        if (why) blocked.push({ ip, why });
      }
    } catch { /* no records of this type is not an error */ }
  }
  return { addrs, blocked };
}

async function gate(url: string) {
  const verdict = await policyCheck(url);
  if (!verdict.allowed) return { ok: false as const, stage: "policy", verdict, dns: null };
  const dns = await resolveAndCheck(verdict.host!);
  if (dns.addrs.length === 0) {
    return { ok: false as const, stage: "dns", verdict, dns, reason: "host does not resolve" };
  }
  if (dns.blocked.length > 0) {
    return { ok: false as const, stage: "dns", verdict, dns, reason: "resolves to a non-public address" };
  }
  return { ok: true as const, stage: "passed", verdict, dns };
}

async function readCapped(res: Response) {
  const reader = res.body?.getReader();
  if (!reader) return { bytes: new Uint8Array(0), truncated: false };
  const chunks: Uint8Array[] = [];
  let total = 0;
  let truncated = false;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > MAX_BYTES) { truncated = true; await reader.cancel(); break; }
    chunks.push(value);
  }
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return { bytes: out, truncated };
}

Deno.serve(async (req) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body, null, 2), {
      status,
      headers: { "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: { url?: string; apply?: boolean };
  try { body = await req.json(); } catch { return json({ error: "body must be JSON" }, 400); }

  const startUrl = body.url;
  const apply = body.apply === true;
  if (!startUrl) return json({ error: "url is required" }, 400);

  const hops: unknown[] = [];
  let current = startUrl;

  for (let hop = 0; hop <= MAX_HOPS; hop++) {
    let g;
    try { g = await gate(current); }
    catch (e) { return json({ fetched: false, error: String(e), hops }, 502); }

    hops.push({
      hop, url: current, stage: g.stage,
      allowed: g.ok,
      reasons: g.verdict.reasons,
      resolved: g.dns?.addrs ?? [],
      blocked: g.dns?.blocked ?? [],
    });

    if (!g.ok) {
      return json({
        fetched: false, refused_at_hop: hop, stage: g.stage,
        reason: (g as { reason?: string }).reason ?? "policy refused",
        hops,
      }, 403);
    }

    if (!apply) {
      return json({
        fetched: false, dry_run: true, hops,
        note: "Preview. Policy and DNS checks passed and no connection was opened. Re-send with {\"apply\": true} to fetch.",
      });
    }

    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), TIMEOUT_MS);
    let res: Response;
    try {
      res = await fetch(current, {
        method: "GET",
        redirect: "manual",
        signal: ac.signal,
        headers: { "User-Agent": "M2M-SourceFetch/1.0", Accept: "*/*" },
      });
    } catch (e) {
      clearTimeout(timer);
      return json({ fetched: false, error: `transport: ${String(e)}`, hops }, 502);
    }
    clearTimeout(timer);

    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel();
      if (!loc) return json({ fetched: false, error: "redirect without Location", hops }, 502);
      // Re-validate the next hop from the top. Never auto-follow.
      current = new URL(loc, current).toString();
      continue;
    }

    const { bytes, truncated } = await readCapped(res);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const hash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");

    return json({
      fetched: true,
      final_url: current,
      status: res.status,
      content_type: res.headers.get("content-type"),
      bytes: bytes.length,
      truncated,
      content_sha256: hash,
      retrieved_at: new Date().toISOString(),
      hops,
      note: truncated
        ? `Response exceeded the ${MAX_BYTES} byte cap and was truncated. The hash covers the truncated bytes only and must not be recorded as the document hash.`
        : "Hash covers the complete response body.",
    });
  }

  return json({ fetched: false, error: `exceeded ${MAX_HOPS} redirect hops`, hops }, 502);
});
