# The nine-stage cycle gets a driver

**Date** 2026-08-22
**Ledger** `SEL-20260822-E2951181` (BUILD, Executed, Pending) — acts on `SEL-20260822-1BD26D3B` rec. 1
**Components** `MUON-CYCLE-DRV-001`, `MUON-CYCLE-DRV-002`
**Migration** `20260822114837_m2m_cycle_sweep_preview_harness.sql`

---

## What was wrong

`m2m_cycle_sweep` and `m2m_cycle_advance` appeared in **zero cron jobs**. The
nine-stage cycle advanced only when a human called it by hand — an architecture,
not a process. Nothing moved work through it, and nothing recorded that nothing
was moving.

## What now runs

| | |
|---|---|
| Job | `m2m_cycle_sweep_preview_daily` |
| Schedule | `0 14 * * *` — after the 13:00 conformance battery, clear of the 11:00 and hourly collisions |
| Command | `select public.m2m_cycle_sweep_preview(100);` |
| Mode | **PREVIEW. Cannot apply.** |

## Two design choices worth keeping

**Apply is not a parameter.** The scheduled entry point hard-codes
`p_apply := false` inside the function body. There is no argument that makes it
write. Turning the cycle on for real is a separate migration someone has to author
and review — not a flag edited inside a cron command string, where it would never
show up in a diff.

**The job proves its own innocence.** `m2m_cycle_sweep_preview` counts rows in
`loop_audit_trail` before and after the sweep and stores the delta as
`audit_rows_written`. In preview that must be `0` on every run. A non-zero value in
that column is visible evidence that something applied when it should not have —
you do not have to take the mode label on trust.

## Verified

First run against live data:

```json
{ "mode": "PREVIEW", "candidates": 1, "verdict_counts": { "PREVIEW": 1 },
  "eligible_now": 1, "unclassified_now": 14, "audit_rows_written": 0 }
```

Inert confirmed by before/after comparison in a single statement:

- `loop_audit_trail` — 770 rows before, **770 after**
- `cycle_stage` distribution — `9:190 / 7:1 / null:14` before, **identical after**

`DBC-001 CONFORM`. `WS43-01 CONFORM` at 205 of 205.

## The constraint this surfaces rather than solves

Read the two numbers together: **`eligible_now: 1`, `unclassified_now: 14`.**

`m2m_cycle_sweep` selects `WHERE cycle_stage IS NOT NULL AND cycle_stage < 9`. The
14 loops sitting at NULL stage are **invisible to it**, and `m2m-ceo-dashboard-loop`
adds roughly two more NULL-stage loops every day. The driver is scheduled, but it
will have almost nothing to drive until loops are classified at creation.

Classification was **not** built here, deliberately. `m2m_cycle_exit_test` returns
`UNCLASSIFIED` with the note that status maps to stages 2–6 ambiguously — so picking
a new loop's opening stage is a judgement about what a loop *means*, not a mechanical
mapping.

**Recommended next:** set `cycle_stage := 1` (SIGNAL) at insert on the loop-creating
path. Stage 1's exit test requires only `loop_name` and `trigger_source`, which both
cron-created loops already satisfy — so they would enter the cycle and immediately
be eligible to advance.

## Rollback

```sql
select cron.unschedule('m2m_cycle_sweep_preview_daily');
drop function public.m2m_cycle_sweep_preview(integer);
drop table public.m2m_cycle_sweep_log;
```

Safe unconditionally and in any order: nothing else references them, and
`m2m_cycle_sweep` / `m2m_cycle_advance` are untouched, so the manual path keeps
working. To pause instead:

```sql
select cron.alter_job(
  (select jobid from cron.job where jobname='m2m_cycle_sweep_preview_daily'),
  active := false);
```

## Note on a corrected record

`SEL-20260822-E2951181` initially cited migration version `20260822114812` — guessed
rather than read. The applied version is `20260822114837`, and `DBC-001` counted the
migration as an orphan until the record was amended. Cite versions you have read.

---

# Part two: new loops now enter the cycle

**Ledger** `SEL-20260822-AB55DBCD` (BUILD, Executed, Pending)
**Component** `MUON-CYCLE-CLS-001`
**Migration** `20260822115410_loop_executions_classify_signal_on_insert.sql`

Scheduling the driver was necessary and not sufficient — it reported
`eligible_now: 1` against `unclassified_now: 14`. This closes that gap forward.

- `loop_executions.cycle_stage` now **defaults to 1** (SIGNAL)
- `trg_ab_cycle_stage_default` (BEFORE INSERT) coerces an explicit NULL to 1

Both exist because the default cannot catch an explicitly-inserted NULL, and the
loop-creating paths are several: pg_cron, the `m2m-loop-webhook` Edge Function, and
Make scenarios — not all visible from the database.

## Why stage 1 is earned, not assumed

Stage 1's exit test is evaluated as `loop_name IS NOT NULL AND trigger_source IS NOT
NULL`. **Both columns are NOT NULL in the table definition.** Any row that exists has
necessarily satisfied stage 1. The schema guarantees the classification is true — it
is not a guess about what happened to the loop.

## Verified

Dual-path probe inside an aborted transaction:

```
omitted->1 | explicit_null->1 | pre-existing NULL rows before=14 after=14
```

Both creation shapes classify to 1. Existing rows untouched — the trigger is
INSERT-only, confirmed via `pg_trigger.tgtype` (BEFORE INSERT set, UPDATE bit clear).
Probe fully rolled back: 0 `PROBE%` rows remain, 205 loops, distribution unchanged.

`DBC-001 CONFORM` · `WS43-01 CONFORM` · `WS41-01` still reports 14 unclassified,
which is correct — nothing was backfilled.

## Open for Founder decision: the 14 existing rows

All 14 satisfy stage 1's exit test on paper. Their statuses have not stayed together:

| Status | Count | Loops |
|---|---|---|
| `RUNNING` | 8 | CEO Dashboard Briefing (daily, 15–22 Aug) |
| `HUMAN_REQUIRED` | 5 | Month-End Close Prep ×2, FORGE / COMPASS / ANCHOR Intake |
| `CLOSED` | 1 | Platform Integrity Sentinel |

Classifying a **CLOSED** loop as "signal received" would be false, and
`m2m_cycle_exit_test` declines this mapping itself — it returns `UNCLASSIFIED` with
the note that status maps to stages 2–6 ambiguously.

A defensible narrow backfill covers **only the eight RUNNING CEO Dashboard Briefing
rows**. The CLOSED and HUMAN_REQUIRED rows need a judgement about what stage they
actually reached, which is not in the data.

## What to watch

At 11:00 UTC the CEO dashboard cron creates the next loops; they now enter at stage 1.
At 14:00 UTC the sweep runs. In `m2m_cycle_sweep_log`, expect **`eligible_now` to
rise** while **`unclassified_now` holds flat at 14**.

## Rollback

```sql
drop trigger if exists trg_ab_cycle_stage_default on public.loop_executions;
drop function public.trgfn_loop_default_cycle_stage();
alter table public.loop_executions alter column cycle_stage drop default;
```

Safe unconditionally and in any order — they affect only rows inserted after this
change, and nothing reads the default.
