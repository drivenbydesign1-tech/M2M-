# CHANGE · 2026-08-28 · Gate `eco_authenticate` behind the Founder session

**Migration:** `supabase/migrations/20260828141500_ws48_eco_authenticate_founder_gate_and_detector.sql`
**Detector:** `WS48-01`
**Status:** **APPLIED** 2026-08-28 on narrow Founder authorization. Ledger rows Pending.
**Applied versions:** `20260828095500` (WS48) · `20260828095705` (WS48-01a correction)
**Prior record:** `SEL-20260827-AF9B1D84` (Held — recommended exactly this fix)

---

## Corrections to the status report this work was picked up from

Stated first, because the rest rests on it.

1. **There is no PR #14 in `drivenbydesign1-tech/M2M-`.** The repository has exactly
   one pull request: **#1**, open, draft, `mergeable_state: clean`, 28 files, +3,359,
   12 commits, head `4bd96e5`.
2. **Branch `claude/atlas-authorization-hardening-hlkdb0` does not exist on the remote.**
   `git ls-remote origin` returns only `main` and `claude/2m-build-status-sequence-a4ya61`.
3. **Commit `ab683480c0e6051a4f44fe442f806f137654802a` does not exist**, and
   `MCP-AUTHORIZATION-NEGATIVE-TEST-PLAN-001.md` is not in this repository.

`SEL-20260827-AF9B1D84` and `SEL-20260827-14D65378` both reference a **PR #5** and a
**PR #14** that this repository has never had. That is the canonical-repository dispute
(Atlas F3) showing up as a concrete contradiction rather than a registry mismatch: the
work described in those records was done somewhere this session cannot reach. Settling
which repository is canonical is a prerequisite to reviewing any of it, not a follow-up.

## What was verified, and how

Read-only, against project `jnmywpfdykuybrxkdcmc`, 2026-08-28.

| Claim | Verdict | Evidence |
|---|---|---|
| `eco_authenticate` does not call `assert_founder_session()` | **CONFIRMED** | `pg_proc.prosrc` — no occurrence; `prosecdef = false` |
| No detector watches `eco_tasks.auth_status` | **CONFIRMED** | zero `ws*check*` functions reference `eco_tasks` or `eco_authenticate` |
| `eco_tasks` holds 1 row, `NOT_REQUIRED` | **CONFIRMED** | no false authentication record exists yet |
| 9 anon-executable `SECURITY DEFINER` functions | **CONFIRMED** | independent count via `has_function_privilege` agrees with Atlas *and* the Supabase advisor at 9 — three independent counts, so WS24-01's "1 anon-reachable" is a scan-scope defect in that detector |
| Last applied migration `20260827133939` (ws47) | **CONFIRMED** | `supabase_migrations.schema_migrations` |
| GitHub branch protection | **RESOLVED — there is none** | both branches report `protected: false`. The registry's "pending" is optimistic; the actual state is off |

### Two corrections to Atlas's own findings

- **`fn_flii_machine_redirect` does not write `m2m_conformance_audit`.** It is anon-executable,
  but it is a trigger function, so it is not an evidence-injection vector in the way the
  others are. The anon-reachable functions that *do* write conformance findings are
  `fn_canonical_last_write`, `ws32_ledger_immutability_check`, `ws33_flii_single_writer_check`
  and `ws31_flii_guard_bypass_check`.
- **`ws31_flii_guard_bypass_check` contains the string `assert_founder_session`** because it
  scans other functions for it, not because it calls it. Any heuristic keyed on `prosrc`
  matching — including the one in this document's own tooling — reports that row wrong.

### The finding, stated at full strength

`eco_authenticate`'s only authority check was:

```sql
IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
  RAISE EXCEPTION 'AUTH-CONTAINMENT: unauthorized caller role %', current_user;
END IF;
```

That verifies **which database role is calling, not which human**. `service_role` is what
Edge Functions, MCP clients, automation and agent sessions hold. The function then writes
`eco_tasks.auth_status = 'AUTHENTICATED'` and inserts a child record carrying
`'actor','Kevin A. Smith'`.

Proved by contradiction on a live session, without writing anything:

```
current_user = 'postgres'   auth.uid() = NULL
  -> ACCEPTED by eco_authenticate's containment check
  -> REFUSED  by assert_founder_session()  ("FL/II REFUSED: no user session")
```

One caller, two gates, opposite verdicts. And the inverse: the Founder's own PostgREST
session runs as `current_user = 'authenticated'`, which the containment check **rejects**,
and `eco_authenticate` carried no `authenticated` EXECUTE grant. So the callers permitted
were exactly the ones that must never be trusted to do this, and the one human who should
was locked out.

**The bypass was not demonstrated by execution.** Calling `eco_authenticate` to prove it
would have manufactured the precise false authorization record the doctrine exists to
prevent. Static evidence is conclusive without it.

### This is not a missing lock

`assert_founder_session()` is live and already gates five sibling surfaces — every one
`SECURITY DEFINER`, granted to `authenticated` only, never to `service_role`:

`muon_founder_authenticate` · `muon_founder_authenticate_deliverable` ·
`muon_ratify_binding` · `muon_score_refusal` · `authenticate_sovereign_task`

`eco_authenticate` is the lone outlier on every axis. It is a **second write path around an
existing control** — the split-write-path failure — and the fix conforms it to the pattern
its siblings already follow. The role check came from `20260824005933
authcontain_tier3_interim_hardening`, which named itself interim.

## What the migration does

1. `ws48_authentication_surface_gate_check(uuid)` — additive, inert, shipped **before** the
   fix so the condition is visible even if only part is applied. Against today's schema it
   reports `DEVIATION / BLOCKING`; after step 2 it reaches `CONFORM`.
2. `eco_authenticate` gated on `assert_founder_session()`, `SECURITY INVOKER` -> `SECURITY DEFINER`.
   **Correction:** `search_path` was already pinned to `'public','pg_temp'` before this change;
   an earlier draft of this record implied it was not. It is preserved verbatim, not added.
   Records the real `auth.uid()` as `session_uid` and sets
   `attribution_verified = true` — previously hard-coded `false`, honestly, on the child
   row only, while the parent row's `auth_status` carried no such qualifier at all.
3. EXECUTE moved: revoked from `service_role`, granted to `authenticated`.
4. WS48-01 wired into the existing `ws10_conformance_daily` cron — no new schedule.
5. Ledger row, `Pending`.

`supersedes` is deliberately **not** set on the ledger row. `SEL-20260827-AF9B1D84` is the
finding this executes and is itself still Pending; marking it superseded would retire it
from the review queue before it had been read.

## Rollback

Executable, and safe: `eco_tasks` holds 1 row at `NOT_REQUIRED`, so no authentication has
ever succeeded through this path and no data moves in either direction.

**(a)** Restore the prior definition — `SECURITY INVOKER`, `search_path` as it already was, and
note the `p_notes` default, whose omission would make `CREATE OR REPLACE` fail outright:

```sql
CREATE OR REPLACE FUNCTION public.eco_authenticate(p_task_id uuid, p_decision text, p_notes text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_task eco_tasks%ROWTYPE; v_claude uuid; v_auth_task uuid;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'AUTH-CONTAINMENT: unauthorized caller role %', current_user USING ERRCODE = '42501';
  END IF;
  IF upper(p_decision) NOT IN ('AUTHENTICATED','REJECTED') THEN
    RAISE EXCEPTION 'ECO: decision must be AUTHENTICATED or REJECTED';
  END IF;
  SELECT * INTO v_task FROM eco_tasks WHERE task_id = p_task_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ECO: task % not found', p_task_id; END IF;

  UPDATE eco_tasks SET auth_status = upper(p_decision),
    metadata = metadata || jsonb_build_object('auth_notes', COALESCE(p_notes,''), 'auth_at', now(), 'executed_by_role', current_user)
  WHERE task_id = p_task_id;

  SELECT model_id INTO v_claude FROM eco_models WHERE model_code='claude';
  INSERT INTO eco_tasks (ecosystem_id, model_id, parent_task_id, task_type, task_description,
    gate_status, auth_status, fl_ii_class, completed_at, metadata)
  VALUES (v_task.ecosystem_id, v_claude, p_task_id, 'authentication',
    'Founder authentication: ' || upper(p_decision) || ' — task ' || p_task_id,
    'UNGATED', 'NOT_REQUIRED', 'AUTHENTICATE', now(),
    jsonb_build_object('actor','Kevin A. Smith','decision',upper(p_decision),'executed_by_role',current_user,'attribution_verified',false))
  RETURNING task_id INTO v_auth_task;

  RETURN jsonb_build_object('task_id', p_task_id, 'auth_status', upper(p_decision),
    'auth_event_task_id', v_auth_task);
END $function$;
```

**(b)** `REVOKE EXECUTE ON FUNCTION public.eco_authenticate(uuid,text,text) FROM authenticated;`
    `GRANT EXECUTE ON FUNCTION public.eco_authenticate(uuid,text,text) TO service_role;`
**(c)** `DROP FUNCTION public.ws48_authentication_surface_gate_check(uuid);`
**(d)** re-run `cron.schedule('ws10_conformance_daily','0 13 * * *', ...)` with the WS48 line removed.

## Held, not done

- **Not applied.** This changes the authentication surface of a live system. It is written,
  reviewable, and reversible, and it stays unapplied until the Founder says otherwise.
- **No authentication performed.** No `eco_tasks` write, no G6 declaration, no migration 369,
  no FL/II cutover, no root-key activation, no production authority transfer, no merge.
- **The 9 anon-executable `SECURITY DEFINER` functions.** Separate scope. Four of them write
  `m2m_conformance_audit` as owner, so an anon key holder can inject conformance findings —
  evidence integrity, open at BLOCKING under WS24-03 since Aug 19.
- **`WS24-01`'s scan scope.** It reports 1 anon-reachable function where three independent
  counts find 9. The detector needs its scope widened; it is currently reporting clean on a
  set it is not looking at.
- **Repo filename vs applied version drift.** PR #1 carries
  `20260827134500_ws47_...sql`; the applied version is `20260827133939`. Cosmetic, but it
  means filename and `schema_migrations` are not a reliable join key.

## Verification after applying

```sql
-- 1. detector should now read CONFORM
select verdict, severity, observed from m2m_conformance_audit
where check_code = 'WS48-01' order by audited_at desc limit 1;

-- 2. the gate must refuse a service_role session
--    (expect: FL/II REFUSED: no user session)
select public.eco_authenticate('<task_id>','AUTHENTICATED','probe');

-- 3. grants must read: authenticated only
select pg_catalog.array_to_string(proacl,' | ') from pg_proc
where proname = 'eco_authenticate';
```


---

# Applied — evidence, 2026-08-28

Authorized narrowly for WS48. Every other HOLD left where it was.

## Two defects of mine, caught and corrected

**1 · `search_path` was already pinned.** I wrote that this change pins it. It was already
`'public','pg_temp'`. The real change is `SECURITY INVOKER` -> `SECURITY DEFINER` plus the gate.
The rollback SQL above has been corrected — as first written it omitted both the `SET search_path`
clause and the `p_notes DEFAULT NULL::text`, and **would have failed on execution**
(`CREATE OR REPLACE` cannot remove an existing parameter default). Caught in pre-flight, before
applying. The rollback path is the highest-value field in a change record and mine was wrong.

**2 · WS48-01 counted itself.** Its universe was three `ILIKE` probes against `prosrc`
(`%eco_tasks%`, `%auth_status%`, `%update%`). Its own body contains all three, so it reported
**2** writers where the true answer is **1** — and scored itself `gated` because its text contains
the *string* `assert_founder_session`, not because it calls it. That is the identical false
positive I had documented in `ws31_flii_guard_bypass_check` one section earlier, and then walked
into. Masked today (CONFORM either way), latent tomorrow: an edit dropping that literal would make
the check flag *itself* as an ungated service_role-reachable writer — a DEVIATION it could never
clear on a finding that was never true. Corrected in `20260828095705` (WS48-01a): universe is a
structural match on `update [public.]eco_tasks`, gating is a structural match on a call site, and
the function is excluded from its own scan with the exclusion **declared** in `scan_scope`.

## Evidence

**WS48-01 — CONFORM / INFO**

```
1 function(s) update eco_tasks.auth_status (eco_authenticate);
0 of them do not call assert_founder_session();
0 of those are EXECUTE-able by service_role;
0 eco_tasks row(s) at AUTHENTICATED, 0 without a verified session attribution
```

**WS48-02 — CONFORM.** The refusal captured by execution, not asserted. The call was permitted to
reach the gate and was stopped by it:

```
REFUSED :: FL/II REFUSED: no user session. Caller is service_role, MCP, an agent
connection, or the SQL editor. Founder authentication requires the Founder session
credential. :: eco_tasks rows before=1 after=1
```

**Grants, live:**

| function | SECDEF | gated | anon | authenticated | service_role |
|---|---|---|---|---|---|
| `eco_authenticate` | yes | yes | no | **yes** | **no** |
| `ws48_authentication_surface_gate_check` | yes | n/a | no | no | yes |

`eco_authenticate` ACL is now `postgres=X | authenticated=X` — the house pattern exactly.

### A note on the first WS48-02 row

My first probe row was written **without** `scan_scope` and your own
`trg_bp004_scan_provenance_gate` downgraded it to `UNVERIFIABLE` on insert. That is the platform
control working correctly against a malformed finding of mine. The row is left in place rather than
deleted — it is evidence the guard fires — and a correctly scoped WS48-02 was inserted alongside it.

## Every other HOLD, confirmed untouched

| Probe | Value |
|---|---|
| `eco_tasks` rows | 1 |
| `eco_tasks` at `AUTHENTICATED` | **0** |
| SEL rows moved to Approved today | **0** |
| SEL rows Pending | 4 |
| migration 369 present | **false** |
| latest migrations | `20260828095705 ws48_01a...` · `20260828095500 ws48_...` |

No G6 declaration. No FL/II cutover. No root-key activation. No production authority transfer.
No merge. **No authentication performed by the machine** — the gate refused this session, on the
record, which is the point.

## What remains yours

The WS48 and WS48-01a ledger rows are `Pending`. I cannot move them; `assert_founder_session()`
refuses this session by design. From your own authenticated portal session:

```sql
select public.muon_founder_authenticate(
  array(select id from public.sovereign_execution_log
        where human_review_status = 'Pending'
          and action_description like 'WS48%'),
  'AUTHENTICATED',
  'Reviewed: narrow WS48 authorization, evidence verified.');
```
