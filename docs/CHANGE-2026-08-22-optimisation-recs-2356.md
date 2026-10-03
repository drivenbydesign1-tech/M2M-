# Optimisation recommendations 2, 3, 5 and 6

**Date** 2026-08-22
**Ledger** `SEL-20260822-B25C0D8C` (BUILD, Executed) · `SEL-20260822-50162C52` (FINDING, Held)
**Components** `MUON-WATCH-001`, `MUON-WATCH-002`, `MUON-SKILL-001`
**Migrations** `20260822120545`, `20260822120605`, `20260822120657`

---

## Lead finding: the gate verdicts are literals

Reading the live Make blueprint for scenario **5403849 (M2M-LOOP-WATCHER)** to fix
the no-op writes turned up something larger. Every router branch that writes a
`gate_checkpoints` row does so with **hard-coded constants**:

```
gate_verdict:       "TRUST"
check_01_trust:     "PASS"
check_03_liability: "PASS"
route_decision:     "APPROVED"
ocean_total_score:  "12"
```

These are not computed from the Claude module that precedes them. The model writes
briefing prose; the next module stamps a fixed pass regardless of what it produced.

The data agrees:

| | |
|---|---|
| `gate_checkpoints` rows | 120 |
| written by `LOOP-WATCHER-5403849` | **117 — all TRUST, all score exactly 12** |
| `LIABILITY` verdicts, all time | **1** — from a different evaluator |

**The Trust/Liability gate has never once declined anything.** The single time a real
evaluator ran, it produced a non-pass.

This is worse than what `WS44-01` detects. That check says the verdict cannot be
substantiated. This says it was never a judgement at all — and stage 7 of the cycle
reads it as an exit test, so fabricated passes can move work.

**Not remediated.** The fix belongs in Make and changes what the platform asserts
about its own output, so it is a Founder decision. Either the gate modules take a
verdict from a real evaluation, or the `gate_checkpoints` write is removed until such
an evaluator exists. Worth checking first: no `gate_checkpoints` row has been written
since **2026-08-14** despite the watcher claiming a loop daily, which suggests the
branch is already erroring — the fabrication may have stopped by accident, which is
not the same as fixed.

---

## Rec 3 — watcher no-op suppression

The blueprint explains the 5,595 NULL rows: module 1 searches for
`status = 'INITIATED'` limit 1, module 2 writes a CLAIM **unconditionally**. A new
loop defaults to `INITIATED`, so the 11:00 cron loop is claimed on the 11:11 poll and
the other 95 polls that day find nothing and record it.

Fixed **database-side**, not in Make — the blueprint does real work daily and a
trigger reverses in one statement. `trg_watcher_suppress_noop` discards NULL-`loop_id`
rows and counts them in `loop_watcher_poll_tally` at one row per day. Make still gets
a success response and needs no change.

Probe, rolled back: `signals 5769→5770` (only the real claim persisted),
`tally 0→1`, real claim retained.

## Rec 5 — loop metrics wired

`m2m_loop_metrics` was empty since creation. `m2m_cycle_sweep_preview` now emits
**`stage_dwell_days`** per eligible loop — how long it has sat where it is, which is
the "are loops stuck" question the review raised, and it accrues a baseline daily
without anyone doing anything.

Emission sits in the preview wrapper, not in `m2m_cycle_advance`: advance is on the
critical path of state change and should not also own measurement.

First row ever written: `CEO Dashboard Briefing`, `stage_dwell_days 0.4901`,
`run_index 2`. `audit_rows_written` still `0` — the sweep remains inert.

## Rec 6 — semantic skill routing

`m2m_match_skills(vector, k, min_similarity)` over the existing HNSW cosine index.
Seeded with `M2M-SOV-006`:

| Skill | Similarity |
|---|---|
| M2M-SOV-006 (itself) | 1.0000 |
| M2M-SOV-015 — enterprise engagement loop | 0.6150 |
| M2M-SOV-001 — Seven Must-Haves gate | 0.5895 |
| M2M-SOV-036 — voice verdict scoring | 0.5894 |
| M2M-SOV-021 — certification loop | 0.5773 |

A coherent cluster around gates, loops and voice.

**Two things stated precisely.** First, the HNSW index is *still* not used and will
not be at this scale — `EXPLAIN ANALYZE` shows `Seq Scan` over 72 embedded rows in
18ms, and the planner is right: an exact scan of 75 rows beats an approximate probe.
My review framed the zero scan count as the capability being off; that was half the
story. Retrieval genuinely did not exist, *and* the unused index is correct planner
behaviour. Second, callers must embed the query themselves via `m2m-embedder`
(voyage-3, 1024 dims) — nothing in the database does that step.

Also: `search_path` must include `extensions`, or pgvector's `<=>` operator is
invisible and the function will not create. The first attempt failed exactly there.

## Rec 2 — cadence disposition, decided on output

Not preference — output:

| Cadence | Runs | With `final_output` | Decision |
|---|---|---|---|
| Monday Morning Brief | 9 | **7** | **Reactivated** |
| Friday Weekly Brief | 8 | **7** | **Reactivated** |
| Presidio Relationship Cadence | 9 | **0** | Held |
| Month-End Close Prep | 2 | **0** | Held |

Reactivate what demonstrably produced something; hold what never did, pending
investigation. Presidio and Month-End are now held **by decision rather than by
neglect**, which was the point of the original finding.

Note: Monday at `0 10 * * 1` shares its slot with `skl-023-daily-context-review`.
Unrelated work, benign, but that is now a third job at 10:00 on Mondays.

## Verification

`DBC-001 CONFORM` (0 of 3 orphans) · `WS43-01 CONFORM` · `WS44-01 CONFORM` ·
`WS42-01` unchanged at 1 of 23 (`muon_evidence_store`, pre-existing).

## Rollback

```sql
-- watcher
drop trigger trg_watcher_suppress_noop on public.loop_watcher_signals;
drop function public.trgfn_loop_watcher_suppress_noop();
drop table public.loop_watcher_poll_tally;
-- skill routing
drop function public.m2m_match_skills(extensions.vector,integer,double precision);
-- loop metrics: restore m2m_cycle_sweep_preview to migration 20260822114837, then
delete from public.m2m_loop_metrics where evaluator = 'm2m_cycle_sweep_preview';
-- cadences
select cron.alter_job((select jobid from cron.job where jobname='m2m-monday-brief-loop'), active := false);
select cron.alter_job((select jobid from cron.job where jobname='m2m-friday-brief-loop'), active := false);
```

All safe unconditionally and independently.
