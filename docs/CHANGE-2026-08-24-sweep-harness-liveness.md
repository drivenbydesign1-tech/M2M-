# The sweep harness stopped, and the failure deleted its own receipt

**Date:** 2026-08-24
**Ledger:** `SEL-20260824-DB220C96` (Pending — Founder review)
**Migration:** `20260824112652_ws45_repair_sweep_metrics_grain_and_add_liveness_detector.sql`
**Detector shipped:** `WS45-01`

## What happened

`m2m_cycle_sweep_preview_daily` fires at 14:00 UTC. It ran once successfully on
2026-08-22, then aborted on 2026-08-23:

```
ERROR:  duplicate key value violates unique constraint
        "m2m_loop_metrics_loop_name_run_index_metric_name_key"
DETAIL: Key (loop_name, run_index, metric_name)
        = (CEO Dashboard Briefing, 4, stage_dwell_days) already exists.
```

## Why

`m2m_loop_metrics` is keyed on `loop_execution_id` — one row per execution
measured — but its unique constraint was `(loop_name, run_index, metric_name)`.
`run_index` is a single scalar computed once per sweep, so every row in the sweep's
multi-row `INSERT` carries the same value. Two `loop_executions` rows sharing a
`loop_name` therefore collide *with each other inside one statement*. Sharing a
`loop_name` is not an edge case: it is what a daily cron loop does by definition.

The 2026-08-22 run passed only because the `cycle_stage` default landed at 11:54
that morning, so exactly one eligible loop carried a non-null stage when the sweep
ran two hours later. By 14:00 the next day there were two. The constraint was
always wrong; a one-row universe hid it for exactly one run.

## The part that matters more than the bug

The metrics `INSERT` sits **ahead of** the `m2m_cycle_sweep_log` `INSERT` in the same
function and the same transaction. When it raised, it took the receipt down with it.
The harness did not report a failure — it stopped producing rows. The only symptom
was an absence, and nothing was watching for an absence. It went unnoticed for
21 hours and was found by reading `cron.job_run_details` by hand.

That is the defect worth generalising: **a measurement side effect must never be able
to take down the thing it measures.**

## The repair

Reversible order:

1. `create unique index m2m_loop_metrics_exec_run_metric_key on (loop_execution_id, run_index, metric_name)`
2. verify satisfiable — 0 null `loop_execution_id`, 0 duplicate groups — or `raise`
3. drop the old `(loop_name, run_index, metric_name)` constraint
4. `alter column loop_execution_id set not null`, so the new key actually binds
5. `ON CONFLICT ... DO NOTHING` on the metrics insert, plus an exception block that
   records `_metrics_error` into the sweep log instead of replacing it

`m2m_cycle_sweep_preview` is the sole writer of `m2m_loop_metrics`, verified against
`pg_proc`, so re-keying the table breaks no other caller.

## WS45-01

Checks four things every day at 13:00, inside the `ws10_conformance_daily` battery:

| signal | threshold |
|---|---|
| newest sweep log row | ≤ 26 hours old (24h + drift) |
| failed cron runs | 0 in the last 48 hours |
| job active | true |
| `audit_rows_written` total | exactly 0, forever |

The last one is not about liveness. The harness is preview-only by construction —
`m2m_cycle_sweep(false, ...)` is hardcoded — so a non-zero total would mean somebody
rewired it to apply. That is a governance breach, not a bug, and it is graded
`BLOCKING`.

**WS45-01 reads DEVIATION today, deliberately.** The 2026-08-23 failure is still
inside its 48-hour window. It does not turn green because the code changed; it turns
green when two days pass without a failed run. A detector that clears on the strength
of its author's fix is not a detector.

## Verification

Post-repair run: 6 candidates, **6** metric rows emitted where the old key permitted
1, `audit_rows_written` 0. WS45-01 reproduces the original error text verbatim from
`cron.job_run_details`.

## Rollback

In `SEL-20260824-DB220C96`. Note that restoring the old unique constraint will fail
while more than one execution per `loop_name` holds a metric row at the same
`run_index` — which is the defect itself. Delete the affected `run_index` first.
