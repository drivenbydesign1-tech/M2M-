# INTAKE-001 — Adversarial Validation Report

**Validator:** CC (independent). **Builder:** Atlas. Builder did not grade builder.
**Date:** 2026-08-29, 13:19–13:26 UTC. **Target:** Supabase project `jnmywpfdykuybrxkdcmc`,
Edge Function `m2m-site-intake` **version 11** (`ezbr_sha256 ec51072148aa…de25`).

**DISPOSITION: INTAKE-001 CONDITIONAL.**

Every backend case that could be executed passed against live production. The condition
is requirement 10, which could not be verified and carries a high-probability defect
described below.

---

## Correction I owe first

**The frontend success contract in PR #27 was under-specified by me, not by Atlas.**

The patch spec I handed the apex session (`APEX-INTAKE-PATCH-SPEC.md`, and the session
prompt) gated success on `res.ok` alone:

```js
if (!res.ok) throw new Error('intake HTTP ' + res.status);
```

That spec was written before v11 introduced the `accepted` field. Requirement 10 asks for
`ok === true && accepted === true && intake_id != null`. A frontend built to my spec would
gate on HTTP status only — and the honeypot path returns **HTTP 200** with
`{"ok":true,"accepted":false}` and no `intake_id`. A honeypot-tripped submission would
therefore render the success screen: exactly the phantom intake requirement 04 exists to
prevent.

The backend is not at fault here — case 04 passed. The defect, if present, is in the
frontend contract, and it originates in my spec.

---

## Method and its limits

Direct egress from this session is blocked by network policy for
`*.model2message.net`, `*.supabase.co` and `*.vercel.app` (`CONNECT tunnel failed,
response 403`). Live HTTP tests were therefore driven **through the database** using
`pg_net` 0.20.0, posting to the real function URL exactly as a browser would (no auth
header, `Origin: https://www.model2message.net`). Responses were read from
`net._http_response`. This is genuine end-to-end HTTP, not simulation.

Requests originate from Supabase egress rather than a browser, so all tests shared one
source IP. That is noted where it matters (case 09).

---

## Results

| # | Case | Verdict |
|---|---|---|
| 01 | First submission | **PASS** |
| 02 | Sequential replay | **PASS** |
| 03 | Concurrent same-key race (23505) | **PASS** |
| 04 | Honeypot / phantom intake | **PASS** (backend) |
| 05 | Invalid email | **PASS** |
| 06 | PII logging | **PARTIAL — exercised paths PASS; total-capture-failure branch NOT EXECUTED / CONTROL INSPECTED** |
| 07 | Dead-letter boundary | **PASS** (with defect D4) |
| 08 | Delete attribution | **PASS** |
| 09 | NAT / rate limit | **CONTROL INSPECTED — acceptable with caveat** |
| 10 | Frontend success contract | **BLOCKED — high-probability defect D1** |

---

### 01 — First submission — PASS
Request: POST `?lane=PIVOT_OS`, `Idempotency-Key: INTAKE001-T01-KEY-20260829`, synthetic
`qa+intake001-t01@m2msovereign.test`.
Observed: HTTP 200,
`{"ok":true,"accepted":true,"lane":"PIVOT_OS","intake_id":"08d2a3e5-b79e-4e5b-bda2-0471d47599d0","capture":"primary","notify":"ok"}`.
DB: 1 row in `m2m_pivot_intake`, `id` identical to the response, `idempotency_key` stored
verbatim, `os_lane='PIVOT_OS'`. Mirror: 1 row in `pivot_leads`; `raw_intake->>'mirror_status'`
null (no best-effort failure). `notify:"ok"` — a real notification email was sent.

### 02 — Sequential replay — PASS
Same body, same key. Observed: HTTP 200,
`{"ok":true,"accepted":true,"replayed":true,...,"intake_id":"08d2a3e5-…","capture":"idempotent_replay","notify":"skipped:replay"}`.
Same `intake_id`. Intake rows still 1. Mirror rows still 1. Notification skipped. Replay is
explicitly identified by both `replayed:true` and `capture`.

### 03 — Concurrent same-key race — PASS (the 23505 test)
Four simultaneous `net.http_post` calls, one key `INTAKE001-T03-RACE-20260829`.
Observed — all four HTTP 200, all four resolving to `28ff6a5c-435d-40ce-9599-5e0cd33d0b9f`:

| req | capture | notify |
|---|---|---|
| 24 | `primary` | `ok` |
| 22 | **`idempotent_race_replay`** | `skipped:replay` |
| 23 | `idempotent_replay` | `skipped:replay` |
| 25 | `idempotent_replay` | `skipped:replay` |

Request 22 is direct evidence the 23505 catch-and-re-read path executed rather than the
pre-check. DB: 1 intake row, 1 mirror row, 0 dead-letter rows. No 500. Exactly one
notification. The partial unique index carrying this is
`uq_m2m_pivot_intake_idempotency_key … WHERE (idempotency_key IS NOT NULL)`.

### 04 — Honeypot — PASS (backend)
`_gotcha` populated. Observed: HTTP 200, `{"ok":true,"accepted":false}` — no `intake_id`,
no `replayed`. DB: 0 intake rows, 0 rows against the supplied key, 0 dead-letter rows.
Backend contract correct. **Frontend enforcement is requirement 10 and is unverified.**

### 05 — Invalid email — PASS
`email:"not-a-valid-email"`. Observed: HTTP 400,
`{"ok":false,"error":"valid email required"}`. DB: 0 rows. No success semantics.

### 06 — PII logging — PARTIAL
A true total-capture failure cannot be induced in production without deliberately breaking
the primary table, so per the brief that branch is **NOT EXECUTED / CONTROL INSPECTED**.

Executed evidence: a search of every log source over the test window for
`qa+intake001`, `m2msovereign.test` and the test phone number returned **zero rows**.
`function_edge_logs` carried only `POST | <status> | <url>`.

Control inspection of v11 confirms Atlas's central claim: on total capture failure the
function writes to `m2m_intake_dead_letter` and logs only
`{idempotency_key_present: boolean}`. The v4 behaviour of dumping full `rawIntake` into
logs is gone. Residual channel remains — see D3.

### 07 — Dead-letter boundary — PASS
Table exists with `subject_email`, `raw_intake`, `capture_error`, `source`, `status`
(CHECK: open/replayed/resolved/erased), `idempotency_key`, `resolved_at`, `resolution_note`.
RLS enabled, **0 policies** (deny-by-default), and no grants:

- `anon` → SELECT grant `false`, INSERT grant `false`, `rolbypassrls false`
- `authenticated` → SELECT grant `false`, `rolbypassrls false`
- `service_role` → SELECT/INSERT `true`, `rolbypassrls true`

Verified by doing, not asserted. Live refusals captured:

```
set local role anon;          → ERROR 42501: permission denied for table m2m_intake_dead_letter
set local role authenticated; → ERROR 42501: permission denied for table m2m_intake_dead_letter
```

Service path proven writable by a `service_role` INSERT inside a transaction that was then
**rolled back** — row returned `status='open'`, and a follow-up count confirmed 0 rows
persisted. Records are attributable to the subject via `subject_email` (NOT NULL).
No real customer PII was inserted at any point.

### 08 — Delete attribution — PASS
Guard is `tg_guard_delete` → `f_guard_intake_delete()`, `AFTER DELETE … REFERENCING OLD
TABLE … FOR EACH STATEMENT`, SECURITY DEFINER. It archives every deleted row to
`m2m_intake_deletion_ledger` and raises when `n > 5` without
`SET LOCAL m2m.allow_bulk_delete='on'`.

Permitted single-row delete (my own synthetic row, `application_name` set to
`INTAKE-001-VALIDATION-CC`) produced ledger row 17:
`db_user=postgres, session_user=postgres, app_name=INTAKE-001-VALIDATION-CC,
client_addr=2600:1f18:…:b373/128`, full `row_payload` including email and
idempotency key, `deleted_at` set.

Blocking half verified by doing — 6 synthetic rows inserted and deleted inside one
transaction:

```
ERROR: P0001: M2M INTAKE GUARD: 6 rows would be deleted from m2m_pivot_intake. Blocked.
HINT: Single-row and small deletes (<=5) pass through and are archived automatically.
```

Transaction aborted; a follow-up count confirmed 0 probe rows persisted. No destructive
historical reconstruction was attempted.

### 09 — Rate limit — CONTROL INSPECTED, acceptable with caveat
`RATE_LIMIT=20`, `RATE_WINDOW_MS=60_000` confirmed in the deployed v11 artifact (raised
from 5). Supporting index present and correctly shaped:
`idx_m2m_pivot_intake_ip_created ON ((raw_intake->>'ip'), created_at DESC)`.

The threshold was not exercised to exhaustion — doing so requires 20 durable rows in 60
seconds against production. Ordering is favourable: honeypot, invalid-email and idempotent
replay all return **before** the limiter, so only genuine captures consume budget.

Caveat (D7): the limiter keys on a single `x-forwarded-for` value. A CVMSDC cohort behind
one NAT or one conference network shares that IP; 20 genuine submissions in a 60-second
window would 429 real people. Acceptable for diffuse launch traffic, marginal for a live
room.

### 10 — Frontend success contract — BLOCKED
PR #27 exists on `Kali-Dedwen/drivenbydesign1-tech`, branch `claude/intake-fail-visible`,
3 commits, head `27451bec`, with READY preview builds. It could not be read:

- `mcp__github__` refuses the repo (session scope is `drivenbydesign1-tech/M2M-` only;
  `add_repo` refuses cross-owner attach even though the App now has access)
- preview deployments sit behind Vercel Authentication, and the MCP fetcher does not carry
  the SSO cookie; direct egress to `*.vercel.app` is proxy-blocked

Deployment protection was **not** disabled to work around this — that would expose every
preview build, and it is not my call.

What is legible is commit `f35cd38`'s own message, which describes "a non-2xx response now
throws instead of falling through" and says nothing about `accepted` or `intake_id`.
Combined with the origin of the spec (see the correction above), the probability that PR
#27 gates on `res.ok` alone is high. That is a builder's claim either way, and the brief
forbids treating it as proof.

---

## Defects

| id | sev | finding |
|---|---|---|
| **D1** | **BLOCKING for req 10** | Frontend success gate likely `res.ok` only. Honeypot returns HTTP 200 `{ok:true,accepted:false}` with no `intake_id`, so a bot-tripped submit would render success. Origin: my spec, which predates v11's `accepted`. Fix: gate on `ok===true && accepted===true && intake_id!=null` in all three lanes. |
| **D4** | MEDIUM | `m2m_intake_dead_letter` has **no delete guard and no ledger coverage**, unlike `m2m_pivot_intake`, `pivot_leads`, `roi_assessment`, `m2m_switch_assessments`. The one table that exists to hold lost-capture PII can be deleted without attribution — a hole in the stated privacy/erasure boundary. |
| **D2** | LOW-MED | Provenance drift: `raw_intake.capture_path` and dead-letter `source` are hardcoded `…@v5` while the deployed function is version 11. Captured rows cannot be attributed to the revision that wrote them. |
| **D3** | LOW-MED | Residual PII-in-logs channel: `console.error('…primary capture failed',{code, message: err.message.slice(0,160)})` logs the raw Postgres error text, which embeds conflicting column values. Harmless for the idempotency index (logs a key), but any future constraint on `email`/`phone` would put PII in logs. |
| **D8** | LOW | Idempotency keys shorter than 8 or longer than 128 characters are silently coerced to `null` — no idempotency, no error, caller unaware it was ignored. |
| **D5** | LOW (obs) | The guard archives before it raises, but the RAISE rolls the archive back too — a **blocked** bulk-delete attempt leaves no trace. It prevents the loss without recording the attempt. |
| **D6** | LOW (obs) | Ledger attribution granularity: `db_user` and `session_user` are `postgres` for both my deletes and Atlas's 11:12 `mgmt-api` probe. The only discriminators are `app_name` and `client_addr`, so the ledger identifies the channel, not the person. |
| **D7** | LOW (obs) | Shared-NAT rate limiting — see case 09. |

## What I changed, and the rollback path

Test rows were synthetic throughout (`qa+intake001-*@m2msovereign.test`); no real customer
PII was written or read. All were removed afterwards under
`application_name='INTAKE-001-VALIDATION-CC-cleanup'`. Final state verified: 0 test rows in
`m2m_pivot_intake`, 0 in `pivot_leads`, `m2m_intake_dead_letter` empty,
`m2m_pivot_intake` back to 0 total rows.

`m2m_intake_deletion_ledger` holds 5 rows — 4 mine (1 case-08 delete, 3 cleanup) and 1
Atlas's earlier `mgmt-api` probe. These are the intended audit residue and should be kept.
Rollback, if the residue is unwanted: `delete from m2m_intake_deletion_ledger where
app_name like 'INTAKE-001-VALIDATION-CC%'` — but that destroys the evidence for case 08 and
is not recommended.

Case 01 and case 03 each sent one real notification email to `LEAD_NOTIFY_EMAIL`, subject
`New PIVOT OS inquiry — QA Intake001` and `— QA Race`. Two QA emails, expected, no action.

No production configuration was modified. No frontend PR was merged or deployed.

## To close INTAKE-001 to PASS

1. Confirm or fix D1 in PR #27 — the one thing that still loses leads.
2. Extend the delete guard + ledger to `m2m_intake_dead_letter` (D4).
3. Optionally: bump the `@v5` strings to the real revision (D2), and reduce the logged
   Postgres error text to `code` alone (D3).
