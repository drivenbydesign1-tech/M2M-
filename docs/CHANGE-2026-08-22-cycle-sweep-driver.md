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
