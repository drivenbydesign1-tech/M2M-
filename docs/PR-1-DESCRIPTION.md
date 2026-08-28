<!--
Canonical text of the PR #1 description, as of 2026-08-28.

Held here because the GitHub App credential for this session can READ pull
requests but cannot WRITE them: every PATCH to /pulls/1 returned
403 "Resource not accessible by integration", across two attempt rounds,
while git push to this branch succeeded in the same window. The live PR body
is therefore STALE against this file until someone with PR-write permission
applies it. Apply it verbatim; do not re-draft from memory.
-->

Twelve commits across six days. Every one began as "the next step in the sequence" and turned into a repair, because the step could not be taken safely as specified. Each is ledgered in `sovereign_execution_log` with a rollback path and left **Pending** — none of this is authenticated, and authentication is not mine to perform.

**28 files, +3,359.** 17 migrations, 8 change records, 1 Edge Function, 2 test corpora.

> **Indexed as Evidence Ledger Series 000** (added 2026-08-28 by WS55, on branch `claude/atlas-authorization-hardening-hlkdb0`). These twelve commits are now indexed as **26 typed rows** in `public.m2m_evidence_ledger` — BASELINE 1, DEFECT 8, REFUSAL 4, DECLINE 6, CORRECTION 2, RETEST 3 — each linked where an artifact exists to `m2m_conformance_audit`, `muon_refusal_ledger` and `sovereign_execution_log`. Indexed against the commits **read from the GitHub API rather than from this description**, and against live rows: all 14 SEL records named in these commits exist and are Approved. **Five of the eight defects are the machine's own.** See `docs/CHANGE-2026-08-28-evidence-ledger-series-000.md` on that branch.

---

## The through-line

Four separate controls were in the codebase, looked correct on the page, and could not have worked. In each case the reason they went unnoticed was the same: **nothing distinguishes a gate that passes from a gate that cannot execute.**

| What it looked like | What it was |
|---|---|
| Stage 4/5 exit gate enforcing claim citations | Raised `42883` on first execution — `text = uuid`, unreachable only because the column was NULL on all 203 rows |
| 120 gate checkpoints, all `TRUST` | A literal in a Make module. `judge_verdicts` holds 0 rows. No evaluator ever ran |
| Daily cycle sweep, preview-only | Aborted 2026-08-23 and stopped silently — the failing statement destroyed the transaction that would have recorded the failure |
| An applier with an apply mode | Never once invoked. `loop_audit_trail` held 0 advance events |

---

## Commits

**`9db13fa` Repair stage 4/5 cycle gate, add reachability detector WS43-01**
The sequence asked for `loop_executions.deliverable_id` to be populated from the deliverable catalogue. Doing so would have broken stages 4 and 5 on the first row written: `m2m_cycle_exit_test` compared `m2m_claim_register.doc_id` (text) to `deliverable_id` (uuid), and PostgreSQL has no such operator. Confirmed by probe inside an aborted transaction:

```
PROBE>>> STAGE4 GATE RAISED 42883 :: operator does not exist: text = uuid <<
```

Added `doc_ref text` as the correct-typed axis; repaired the branch; shipped WS43-01 so an unreachable gate is a detectable condition rather than a silent pass. **Populated zero relationships** — three deliverable identifier namespaces with no join-key overlap, and binding a loop to a document is a Founder decision, not a deterministic rule. Reported rather than invented.

**`d1cd39a` Add Founder-gated loop binding and SSRF-protected source fetch**
`muon_bind_loop_document(jsonb, boolean)` — preview by default, `assert_founder_session()` before any write. `m2m-source-fetch` Edge Function with five defence layers, plus a source-policy table (9 ALLOW, 4 DENY) and a URL validator. Test corpora: 30 SQL cases, 34 JS cases.
⚠️ **The Edge Function has never been executed.** Registered `building`, not `live`. Egress to the project host returns 403 from this session and I did not route around it.

**`79913ac` Record DBC-001 correction: link SEL rows to migration versions**
My error. Seven migrations flagged as orphans because my ledger rows cited migrations by *name*, not *version*. Amended. It recurred once when I guessed a version string; thereafter I read versions inline from `supabase_migrations.schema_migrations` rather than guessing.

**`24217e4` Schedule the nine-stage cycle sweep in preview** · **`a7e90bb` Classify new loops at SIGNAL on insert**
Preview harness hardcoding `p_apply := false`, on a daily cron. Default `cycle_stage = 1` with a belt-and-braces trigger.

**`a9a9748` Add WS44-01 gate verdict provenance detector**
117 of 120 checkpoints came from LOOP-WATCHER, all `TRUST`, all `ocean_total_score` 12. The only `LIABILITY` in history came from a different evaluator. WS44-01 makes the gap permanent and visible, and **does not retro-back the 119 historical verdicts** — writing `judge_verdicts` rows for them would manufacture evidence of judgements nobody made.

**`744c1bf` Close optimisation recs 2, 3, 5 and 6; find hard-coded gate verdicts**
Watcher no-op suppression, semantic skill routing (`search_path` fix — pgvector lives in `extensions`, not `public`), loop metrics.

**`97c79d1` Repair LOOP-WATCHER blueprint: max_tokens and fabricated verdicts**
Root-caused an 8-day briefing outage to `max_tokens` passed as a quoted string. Span established from three independent DB series after Make's API ignored the status/date filters. Removed the five modules writing literal verdicts.
🔻 **I invented a bug and built for it.** I added 8 PATCH modules believing verdict-removal would strand loops at `INITIATED`. `process_loop_watcher_signal` already sets `RUNNING`. Removed them in a third edit.

**`972bd6d` Close the machine paths that assert Founder authentication**
Three functions set `fl_ii_authenticated = true` / `last_gate_verdict = 'TRUST'` / `status = 'APPROVED'` on their own. Rewritten to `ARCHITECT_REVIEW` + `machine_verified`. Proved `fn_flii_machine_redirect` works for the first time in its existence — `machine_verified` was 0 across the table, so the guard had never fired.

**`6373e66` Repair the cycle sweep harness and detect its silence**
`m2m_loop_metrics` was keyed on `loop_execution_id` but uniquely constrained on `(loop_name, run_index, metric_name)`. Two executions sharing a `loop_name` — what a daily cron loop does by definition — collide inside one multi-row INSERT. It passed once because exactly one eligible loop then carried a non-null stage.

The metrics INSERT precedes the sweep-log INSERT in the same transaction, so **the abort erased its own receipt**. The only symptom was an absence. 21 hours unnoticed. Re-keyed in reversible order; `ON CONFLICT DO NOTHING` plus an exception guard so a measurement can never again take down the thing it measures. WS45-01 watches for the silence.

**`1e13070` Wire the cycle applier behind a verdict-provenance guard**
The applier was **not built here** — `m2m_cycle_advance` and `m2m_cycle_sweep` already existed, already previewed by default, already refused stage 8→9 without Founder authentication. Apply mode had simply never been called.

Grounding first mattered: apply would have advanced loop `6e798ad1` from stage 7→8 on a `TRUST` verdict with `verdict_id` NULL and no `judge_verdicts` row — consuming an acknowledged evidence gap as though it were a passed test. Tightened stage 7 to `BLOCKED_UNBACKED_VERDICT` **first**, proved the refusal, then enabled apply. 11 advanced, 1 blocked, 11 audit rows.

**`4bd96e5` Revoke anon EXECUTE on the SECURITY DEFINER functions added today**
🔻 **My defect, same day.** Supabase grants `EXECUTE` on `public` functions to `PUBLIC` by default, resolving to `anon`. `m2m_cycle_sweep_apply` — `SECURITY DEFINER`, mutates `loop_executions` — inherited it. The anon key was enough to drive the cycle machine over PostgREST RPC. The convention already existed (`m2m_cycle_sweep_preview` carries no anon grant) and I failed to repeat it. Nothing in the function source shows this; it is visible only in `proacl`.

---

## Detectors added

Each is wired into `ws10_conformance_daily` and each can reach a clean state.

| Code | Asks | Now |
|---|---|---|
| **WS43-01** | Can the cycle gates actually execute? | CONFORM |
| **WS44-01** | Does every asserted verdict have a judge row behind it? | CONFORM |
| **WS45-01** | Is the preview harness alive, and still writing nothing? | CONFORM |
| **WS46-01** | Has the applier ever advanced on evidence that does not exist, or crossed the Founder boundary? | CONFORM |

WS45-01 and WS46-01 both spent time at DEVIATION *by design* after their fixes landed — they clear when a window passes without a failure, not when their author declares the code fixed.

---

## The four refusals, now typed

Series 000 indexes four REFUSAL rows from this branch. Three carry typed artifacts with SQLSTATEs in `muon_refusal_ledger`:

- **`assert_founder_session()`** refusing the machine attempting to authenticate its own work — `P0001`
- **`bp004_scan_provenance_gate`** refusing a `CONFORM` finding that declared FULL coverage with no declared scan scope — `23514`
- **`muon_bind_loop_document`** refusing an agent-session apply — `P0001`

The fourth is `ASSERTION_ONLY`: `fn_flii_machine_redirect` was proven by a probe that was rolled back, so no durable artifact survives. That distinction is now in the schema rather than in prose.

---

## Held, not remediated

Deliberately left undone and recorded as such:

- **The stage-1 pile-up is now a stage-2 pile-up.** The applier buys exactly one stage. Stages 2, 3 and 6 return `NO_INSTRUMENTATION` — no exit signal exists anywhere in the schema. 12 eligible loops currently declined. Instrumenting them is a design decision, not a defect to patch.
- **`m2m-source-fetch` has never run.** Needs one preview call from a session that can reach the project host.
- ~~**WS31-01 sits at BLOCKING**, 8 unguarded writers.~~ **Superseded 2026-08-28.** WS50 established that the check was matching any function whose body *mentioned* `fl_ii_authenticated`, counting readers as writers. Exactly one function assigns those columns, and it is an AFTER trigger reacting to an already-vetted transition on a table whose BEFORE trigger redirects machine writes first. **These were 8 false positives, and this bullet reported them as real for nine days.** Now `CONFORM` at 0 unguarded.
- ~~**9 further anon-executable `SECURITY DEFINER` functions predate this branch**~~ **Closed 2026-08-28** by WS49 and WS51 — down to 3, all deliberate (the whistleblower submit and status paths, and a token-gated result read), each printed on every detector run rather than disappearing into CONFORM. The root cause was never a grant anyone made: eight of the nine carried the inherited `PUBLIC` grant in `proacl`, invisible in the function source. The **4 `SECURITY DEFINER` views** in this bullet were the more serious half — WS50 found one of them anon-writable with RLS bypassed via owner-execution. The **4 mutable-`search_path` functions** remain open as WS24-02 (MEDIUM), unauthorized.
- **Loop-to-document mapping.** The axis is authorized and the gated surface is live. The mapping itself is the Founder's to supply.

## Review

Ledger rows `SEL-20260822-*` through `SEL-20260827-28AF3D1B` are all **Pending**. The two records that matter most for this branch are `SEL-20260827-5DB7DD89` (applier wiring, with a rollback path that restores the prior stage distribution from the audit trail) and `SEL-20260827-28AF3D1B` (the privilege revoke).