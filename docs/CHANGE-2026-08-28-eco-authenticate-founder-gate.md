# CHANGE · 2026-08-28 · Gate `eco_authenticate` behind the Founder session

**Migration:** `supabase/migrations/20260828141500_ws48_eco_authenticate_founder_gate_and_detector.sql`
**Detector:** `WS48-01`
**Status:** written, **not applied**. Ledger row Pending.
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
2. `eco_authenticate` gated on `assert_founder_session()`, `SECURITY DEFINER`,
   `search_path` pinned. Records the real `auth.uid()` as `session_uid` and sets
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

**(a)** Restore the prior definition — `SECURITY INVOKER`, no `search_path`, exact prior body:

```sql
CREATE OR REPLACE FUNCTION public.eco_authenticate(p_task_id uuid, p_decision text, p_notes text)
RETURNS jsonb LANGUAGE plpgsql
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
