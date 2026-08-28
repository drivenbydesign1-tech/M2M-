# Controlled source fetch with SSRF protections

**Date** 2026-08-22
**Ledger** `SEL-20260822-113D8031` (BUILD, Executed, Pending) · `SEL-20260822-A124D543` companion
**Components** `MUON-SRCPOL-001`, `MUON-SRCPOL-002` (live) · `MUON-SRCFETCH-001` (**building**)

---

## Status, plainly

The policy layer is live and tested. **The Edge Function is deployed but has never
been executed.** This session cannot reach `jnmywpfdykuybrxkdcmc.supabase.co` — the
agent egress proxy answers `403` to `CONNECT` under organisation policy. Routing
around that denial through `pg_net` was deliberately not attempted. It is registered
at status `building`, not `live`, for that reason.

Someone with project access must run the preview call below before anyone claims
this fetcher works.

## Layers

| # | Layer | Where | Enforces |
|---|---|---|---|
| 1 | POLICY | `muon_validate_source_url()` | https only, port 443 only, no IP literals, no userinfo, no internal hostnames, deny-by-default allowlist |
| 2 | RESOLVE | Edge Function | every A/AAAA record must be publicly routable |
| 3 | REDIRECT | Edge Function | `redirect: "manual"`, every hop re-gated, max 3 |
| 4 | BUDGET | Edge Function | 8 MB streamed cap, 15 s timeout |
| 5 | MINIMAL | Edge Function | no cookies, no auth headers, no caller headers forwarded |

Layer 1 is the single source of truth and lives in Postgres, so it is testable and
a detector can reach it. Layer 2 exists because a hostname check alone does not stop
someone pointing an allowlisted name at `169.254.169.254`. Layer 3 exists because an
allowlisted host can redirect to one.

## Known residual risk

Deno resolves DNS inside `fetch`, so there is a window between our resolution check
and the connection in which a hostile authoritative server can return a different
address — classic DNS rebinding TOCTOU. Closing it requires connecting to a pinned
IP with an SNI/Host override, which the runtime does not expose. **The allowlist is
what actually bounds this**: rebinding requires control of an allowlisted domain's
DNS. Do not add an ALLOW rule for a host whose DNS you do not trust.

## Verification performed

- **Policy layer** — 30-case attack corpus, executed live against the database:
  **30/30**. Covers cloud metadata IPv4, loopback, RFC1918, IPv6 loopback and ULA
  literals, decimal- and hex-encoded `127.0.0.1`, userinfo host confusion
  (`https://www.bcg.com@evil.test/`), suffix-match confusion (`notbcg.com`),
  prefix-match confusion (`bcg.com.evil.test`), non-443 port, http/file/gopher/
  javascript schemes, newline header injection, localhost, `.local`, unallowlisted
  host, empty, null. Reproduce with `tests/ssrf_url_policy_corpus.sql`.
- **Fetcher IP guard** — logic lifted verbatim, unit-tested under Node against 34
  addresses including boundaries either side of RFC1918, CGNAT and multicast, plus
  IPv4-mapped IPv6 forms of the metadata and loopback addresses: **34/34**.
  Run with `node tests/ipguard.test.mjs`.
- **End to end** — not performed. See Status above.

## A bug the corpus caught

The first version of `muon_validate_source_url` appended bare string literals to a
`text[]`. With the right operand of unknown type, PostgreSQL resolves
`anyarray || anyarray` and tries to parse the literal as an array, raising
`22P02 malformed array literal`. Every branch appending a bare literal therefore
**raised instead of returning a verdict**.

That is worse than an ordinary type slip. A validator that raises rather than
returning `{"allowed": false}` is one whose caller may treat the failure as
transient and retry, or catch it and continue. A security check must fail closed
with a verdict. Fixed in `20260822111725`; every appended reason is now `::text`.

## The call to run

```bash
curl -X POST "https://jnmywpfdykuybrxkdcmc.supabase.co/functions/v1/m2m-source-fetch" \
  -H "Authorization: Bearer <anon-or-service-key>" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://www.bcg.com/capabilities/artificial-intelligence"}'
```

Expected: `fetched: false`, `dry_run: true`, one hop with `allowed: true` and the
resolved public addresses listed. Then the refusal cases, which must all return `403`:

```bash
-d '{"url":"https://169.254.169.254/latest/meta-data/","apply":true}'   # metadata
-d '{"url":"https://evil.test/","apply":true}'                          # not allowlisted
-d '{"url":"https://www.bcg.com@evil.test/","apply":true}'              # userinfo
```

Only once those behave should `{"apply": true}` be used against a real source.

## Rollback path

```sql
-- 1. delete the Edge Function (dashboard, or: supabase functions delete m2m-source-fetch)
--    Nothing depends on it; no caller exists yet.
drop function public.muon_validate_source_url(text);
drop table public.muon_source_policy;
```

Safe unconditionally today: nothing in the schema calls the validator yet. To narrow
rather than remove:

```sql
update public.muon_source_policy set active = false where disposition = 'ALLOW';
```

which leaves the deny-by-default posture with no reachable host.

## Open for Founder decision

1. **The 9 ALLOW rules.** Seeded from registered domains already cited by rows in
   `muon_evidence` — evidence-grounded, but still a decision about what the platform
   may reach over the network. Open to rejection.
2. **Standing observation, not remediated.** 12 of 14 `muon_evidence` rows carry
   `hash_algorithm = 'sha256'` with `content_hash` NULL. A citation whose hash is
   absent cannot be checked against the source it names. This fetcher is what would
   populate them.
