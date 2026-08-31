# Module progress + completion — final adversarial attack

**Attacker:** CC (this session). **Date:** 2026-08-30, 00:5x UTC.
**Target:** Supabase `jnmywpfdykuybrxkdcmc` — `fn_upsert_module_progress`,
`fn_complete_module`, `fn_my_checkpoints`, `m2m_module_progress`, `m2m_checkpoints`,
`m2m_admins`, and the facilitator read path.
**Vectors, as briefed:** transport identity · duplicate calls · lane normalization ·
evidence revocation · direct-write bypass · completed-row immutability · authority escalation.
**Production changes:** none. Every probe ran inside a transaction that was rolled back.

**Verdict: three findings. One was mine and live — it is now fixed and re-attacked.**

> **A2 FIXED AND RE-ATTACKED, 2026-08-30 — migration `20260830012054 fix_a2_whitespace_key_normalisation`.**
> A1 and A3 remain open and are recorded below as written.
>
> **The fix goes wider than the finding, deliberately.** A2 happened because V5 was
> fixed against the instance I tested (spaces) rather than the class (anything
> invisible or whitespace-equivalent). Fixing the instance again would have been the
> same mistake. So normalisation now lives in **one** shared function,
> `public.m2m_norm_key(text, boolean)` — IMMUTABLE, pinned `search_path`, EXECUTE
> revoked from `PUBLIC` — used by both RPCs, and it:
>
> 1. deletes characters that are invisible *anywhere* in the string (ZWSP, ZWNJ,
>    ZWJ, word-joiner, BOM) — two visually identical lanes can no longer be two keys;
> 2. collapses every run of any whitespace-class character (ASCII, NBSP, the
>    U+2000–200A quads, U+2028/9, U+202F, U+205F, U+3000) to one plain space,
>    **including internal runs**, so `PIVOT\tOS`, `PIVOT  OS` and `PIVOT OS` are one
>    key rather than three;
> 3. trims, and maps empty to NULL so the existing guard refuses it.
>
> `fn_complete_module` now normalises the *stored* checkpoint values through the same
> function, so evidence written with any padding or casing still resolves.
>
> **Backfill checked before applying:** `m2m_module_progress` holds one row
> (`c1783129…`, lane `PIVOT_OS`, module `HTTP-PROBE`) whose key is unchanged under the
> new rule; `m2m_checkpoints` holds zero rows. Nothing to collapse.
>
> Re-attacked as a confirmed non-admin learner, in rolled-back transactions —
> the A2 attack, widened, plus a full replay of the original sixteen vectors:
>
> | Re-test | Result |
> |---|---|
> | 10 lane variants — tab, LF, CR, NBSP, en-quad, ideographic space, BOM, ZWSP *inside*, lowercase | **collapsed to 1 row**, `'PIVOT'` |
> | 4 module_id variants — tab, NBSP, ZWSP inside | **collapsed to 1 row** |
> | lane of nothing but tab/newline/NBSP | **REFUSED** — `os_lane is required` |
> | valid upsert, `PIVOT_OS` | lane intact, 1 row |
> | internal single space `PIVOT OS` | **preserved**, not stripped |
> | completion against a checkpoint stored as `E'\tpivot '` / `E' atk-mod'`, called twice | **1 completed row**, evidence linked |
> | cross-user write · row reassignment | REFUSED |
> | duplicate upserts | 1 row |
> | delete checkpoint behind a completion · null its evidence | REFUSED (FK · `23514`) |
> | self-complete on another learner's checkpoint (direct · via RPC) | REFUSED · REFUSED |
> | direct UPDATE to completed | REFUSED |
> | edit / delete own completed row | 0 edited, 0 deleted |
> | downgrade a completed module via the RPC | REFUSED |
> | learner adds self to `m2m_admins` | REFUSED — *permission denied* |
> | forged `role: service_role` + `is_admin` claims | no escalation, canary invisible |
>
> Eighteen of eighteen. Rollback is in the migration body, and it reopens A2.
>
> **The recurring lesson, third instance:** V1, V2 and now A2 were each introduced by a
> change that looked like hardening. The guard that would have caught all three is the
> same one still not built — a conformance test that runs the adversarial input class,
> not one example from it. There is no SQL test harness in this repo; the JS suite
> cannot reach these functions.


---

## A1 — TRANSPORT-01 does not prove the learner path

The signing user for TRANSPORT-01 was `430a9d02-5f73-420e-b9b8-9f1b48920cb1` =
`kevin@americanviewinc.com`. That user **is a row in `m2m_admins`**:

```
m2m_admins → model2message@gmail.com · kevin@americanviewinc.com · kevin@model2message.net
```

`m2m_module_progress_admin_all` is PERMISSIVE, `TO authenticated`, `USING m2m_is_admin()`
`WITH CHECK m2m_is_admin()`. A permissive policy that passes ends the evaluation. So every
HTTP write in that run was authorized by the **admin** policy. `learner_insert_own`,
`learner_update_own` and `learner_select_own` were never the deciding rule, and the run
therefore does not exercise the learner path at all.

What survives from TRANSPORT-01, because it is policy-independent:

- PostgREST resolved both RPCs despite the default parameters — **no 404**. Real and useful.
- The refusal text is byte-identical across transports, delivered as HTTP 400 `P0001`.
  Real: those refusals are raised inside the function body, before any policy is consulted.
- The partial-index upsert works through the function. Real.

What does **not** survive:

| Claim | Why it is unproven |
|---|---|
| `owned_by_signing_user true` — "not spoofable from the client" | True because `fn_upsert_module_progress` sets `v_user := auth.uid()`; that is a property of the function body, already proven at the SQL layer. An admin *can* write an arbitrary `user_id`. Transport added nothing here. |
| `fn_my_checkpoints` returned only the caller's rows | `m2m_checkpoints` holds **0 rows**. Any caller returns nothing. Vacuous. |
| `fn_complete_module` refused the zero UUID as "not found" | Same reason — with an empty table every UUID is not found. Vacuous. |
| `id_matches_http_response` | Genuine and worth keeping, but it demonstrates function correctness, not authorization. |

**Remedy:** re-run TRANSPORT-01 with a token for a user that is *not* in `m2m_admins`.
The canary worth keeping in the evidence pack is a **learner-owned** one; row
`c1783129-3210-4b70-aca8-1859e1ba3d83` is admin-owned and cannot carry that weight.

---

## A2 — CONFIRMED DEFECT, mine, live: `btrim()` strips spaces only

Migration `20260830001042` normalises with `upper(btrim(lane))` and `btrim(module_id)`.
Single-argument `btrim()` strips **spaces and nothing else**. Tab, newline and
NO-BREAK SPACE all survive:

```
btrim(E'\tPIVOT\t')  → E'\tPIVOT\t'     upper(btrim(E'\tPIVOT')) = 'PIVOT' → false
btrim(E' PIVOT') → E' PIVOT'   upper(btrim(E' PIVOT')) = 'PIVOT' → false
```

Executed as a confirmed non-admin learner, through the sanctioned RPC:

| Attack | Result |
|---|---|
| four upserts, lane = `PIVOT`, `\tPIVOT`, `\nPIVOT`, ` PIVOT`, same module | **4 rows** — `'\tPIVOT' \| '\nPIVOT' \| ' PIVOT' \| 'PIVOT'` |
| two upserts, module_id = `atk-mws`, `\tatk-mws` | **2 rows** |

This is V5's row multiplication, reopened. The partial unique index
`(user_id, os_lane, module_id) WHERE user_id IS NOT NULL AND os_lane IS NOT NULL` sees the
padded variants as distinct keys, so a learner's progress fragments across rows and
`fn_complete_module` can complete one fragment while the others stay open. I shipped this
five hours ago and called V5 closed. It was closed against spaces only.

**Fix:** widen the trim set in both RPCs —
`btrim(x, E' \t\n\r\f\v ')` — or strip all leading/trailing Unicode whitespace with a
regexp. `m2m_module_progress` holds 1 row, so there is no backfill to collapse. Not applied:
this is a findings run.

---

## A3 — the facilitator read path is blind to every row the RPCs write

`Facilitator read member progress` keys on the row's own `email` column:

```sql
lower(cm.email) = lower(m2m_module_progress.email)
AND lower(c.facilitator_email) = lower(auth.jwt() ->> 'email')
```

Neither `fn_upsert_module_progress` nor `fn_complete_module` ever sets `email`. Verified by
enrolling a learner in a cohort, writing progress through the RPC, then reading as the
facilitator:

| | |
|---|---|
| RPC-written row carries an email | **no — `email IS NULL` on every one** |
| facilitator sees their enrolled member's RPC progress | **0 rows** |

Not a security hole. A functional one, and it interacts with the V4 fix: V4 correctly stopped
learners writing an arbitrary `email`, which leaves admin and `service_role` as the only
writers of the column the facilitator policy depends on. The dashboard is keyed to a column
nothing on the sanctioned path populates.

**Fix, preferred:** re-key the policy to `m2m_cohort_members.user_id` — that column already
exists and already holds the learner's id, so the email indirection buys nothing and costs
this. **Alternative:** have the RPCs stamp `email := auth.jwt() ->> 'email'`, which the V4
`WITH CHECK` already permits.

---

## Everything else held

Thirteen of sixteen vectors refused correctly, as a confirmed non-admin learner:

| Vector | Attack | Result |
|---|---|---|
| identity | learner writes a row owned by another user | REFUSED `42501` |
| identity | learner reassigns own row to another user | REFUSED `42501` |
| duplicates | three identical upserts | 1 row |
| duplicates | duplicate `fn_complete_module` | 1 row |
| revocation | delete the checkpoint backing a completion | REFUSED — FK `fk_completion_evidence`, `NO ACTION` |
| revocation | null the evidence on a completed row | REFUSED `23514` |
| direct write | self-complete using **another learner's** checkpoint | REFUSED `42501` |
| direct write | flip own row to `completed` by direct UPDATE | REFUSED `42501` |
| immutability | learner edits their own completed row | 0 rows — `learner_update_own` USING excludes `completed` |
| immutability | learner deletes their own completed row | 0 rows — no learner DELETE policy |
| immutability | learner downgrades a completed module via the RPC | REFUSED (USING) |
| escalation | learner inserts self into `m2m_admins` | REFUSED — *permission denied for table*, i.e. at the grant, not merely RLS |
| escalation | forge `role: service_role` in the JWT claim | no effect — 0 rows, canary invisible |
| escalation | forge `is_admin` / `app_metadata.claims_admin` | no effect — `m2m_is_admin()` false, canary invisible |
| escalation | complete a module on another learner's checkpoint | REFUSED by the function |

The two escalation results deserve their reason stated: the policies key on the **database
role** (`TO service_role`) and on `m2m_admins` membership, not on anything the token asserts.
A forged claim buys nothing because nothing reads it.

**Known and still open:** revoking `kev_authenticated` does not un-complete a module already
completed on that evidence (V8 cascade). The gate holds forward. Governance, not a defect.

---

## Honest limit of this run

`set_config('request.jwt.claims', …)` simulates a claim that has **already passed** GoTrue
signature validation. It cannot test whether a client could forge a signature — that is
GoTrue's job and is out of reach from here. What V-7b and V-7d establish is narrower and
still worth having: even if such a claim did arrive, it grants nothing.

Concurrency under real parallel connections remains **NOT EXECUTED**.
