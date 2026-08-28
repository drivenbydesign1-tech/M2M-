# CHANGE · 2026-08-28 · Evidence Ledger — Series 001

**Migrations:** `20260828124948`, `20260828125145` · **Detector:** `WS54-01` · **Status:** APPLIED, ledger `Pending`

---

## Why this exists

Atlas's framing: the day's hardening work becomes Evidence Ledger Series 001, and it must
preserve **defects, refusals, corrections and successful retests — not merely the final green
state.** That is right, and it's the thing most evidence packages get wrong. A green dashboard
proves the checks currently pass. It says nothing about whether the controls work.

I checked whether that evidence was actually assemblable before agreeing. It was not.

**`m2m_conformance_audit` has zero foreign keys.** No column references the execution log; no
execution-log column references a `check_code` or `run_id`. On 2026-08-28 alone: 12 SEL rows,
27 conformance rows, correlatable only by timestamp proximity and by reading prose.

So the evidence for a single defect sat in three unjoined stores:

| Store | Holds | Missing |
|---|---|---|
| `m2m_conformance_audit` | before/after verdicts | **why** they changed |
| `sovereign_execution_log` | the why, free-text `dart_deconstruct` | not typed, not queryable |
| git | the actually-defective code | `pg_get_functiondef` returns only corrected bodies |

Assembled from any one alone, a POC package misleads: a green dashboard with no defects,
narrative with no verification, or code with no live proof.

### One correction to my own framing

I nearly claimed the defect arc lived only in prose. **It doesn't.** The append-only ledger caught
each detector's pre-fix verdict as a state transition. That's a stronger evidentiary position than
I'd have credited — and it's exactly why I checked before asserting.

## Why a table and not a column

`trg_m2m_conformance_audit_finding_frozen` blocks `UPDATE`. A link column could never be
backfilled onto the rows that matter. An additive index is the only design that doesn't touch
frozen evidence — and the reversible-order-correct one regardless.

## Two honesty mechanisms built into the schema

**`remediation_class` separates the two kinds of green.** WS24-01, WS24-03 and WS48-01 went
CONFORM because a real hole was **closed**. WS31-01 and WS24-05 went CONFORM because the
**detector was wrong and the system was always fine** — WS24-05 remediated nothing, it silenced a
twelve-day false alarm. WS50-01 is `NEW_COVERAGE`: no prior verdict exists, so it is not a closed
regression. A package listing these in one "remediated" table would overstate the work and would
be fair to attack.

**`verified_by` marks what is not evidenced.** The strongest items here are arguably the
**declines** — refusing to call `eco_authenticate`, to file a test whistleblower report, to write
through the provenance view — because they show the machine choosing not to manufacture the
evidence the control exists to protect. But **no artifact proves a non-action.** Those rows are
`ASSERTION_ONLY`, and WS54-01 prints the count on every run so it can never be quietly dropped.

## Series 001 — 23 rows

`BASELINE 4 · DEFECT 6 · REFUSAL 1 · DECLINE 3 · CORRECTION 3 · RETEST 6`
`HOLE_CLOSED 3 · DETECTOR_CORRECTED 4 · NEW_COVERAGE 1` · **6 of the 6 defects are mine**

| seq | kind | check | class | what |
|---|---|---|---|---|
| 10 | DEFECT | WS48-01 | — | **Origin.** `eco_authenticate` guarded on the calling database *role*, not the human. No detector existed to catch it |
| 20 | **REFUSAL** | WS48-02 | — | **Load-bearing artifact.** `assert_founder_session()` refused this session *by execution*; `eco_tasks` before=1 after=1 |
| 21 | DEFECT | WS48-02 | — | My malformed probe row, downgraded to UNVERIFIABLE by `bp004_scan_provenance_gate`. Preserved — it's evidence the guard fires |
| 30 | DEFECT | WS48-01 | — | **My detector counted itself.** Reported "2 function(s)" where the truth is 1 |
| 31 | CORRECTION | WS48-01 | DETECTOR_CORRECTED | Structural match on `update [public.]eco_tasks`; self-exclusion declared |
| 32 | RETEST | WS48-01 | HOLE_CLOSED | CONFORM after Founder authentication |
| 33 | **DECLINE** | — | — | Did not call `eco_authenticate` to demonstrate the bypass |
| 40 | DEFECT | WS49-01 | — | **Second instance.** Flagged a grant WS49 had just deliberately preserved |
| 41 | CORRECTION | WS49-01 | DETECTOR_CORRECTED | Acceptance encoded, severity split |
| 42 | **DECLINE** | — | — | Did not file a test whistleblower report |
| 50 | DEFECT | WS50-01 | — | **Severest of the series.** `v_flii_provenance_review` anon-writable, RLS bypassed by owner-execution |
| 51 | **DECLINE** | — | — | Did not write through the view to prove it |
| 52 | RETEST | WS50-01 | NEW_COVERAGE | 7 views, 0 anon-writable, 0 authenticated-writable |
| 60 / 61 | BASELINE → RETEST | WS31-01 | DETECTOR_CORRECTED | 9 days BLOCKING on **8 false positives**; one real assigner, already redirect-guarded |
| 70 / 71 | BASELINE → RETEST | WS24-01 | HOLE_CLOSED | BLOCKING daily since ≥ 08-17 → 0 anon-reachable |
| 80 / 81 | BASELINE → RETEST | WS24-03 | HOLE_CLOSED | 5 unexpected → none. Root cause the inherited `PUBLIC` grant |
| 90 / 91 | BASELINE → RETEST | WS24-05 | DETECTOR_CORRECTED | 12 days HIGH **masking 7-of-7 completion** |
| 100 | CORRECTION | WS24-01 | — | **My retracted claim**, made in a row the Founder had already authenticated |
| 110 | DEFECT | — | — | The GitHub identity split |

### The subtlety that justifies the whole exercise

**The defective WS48-01 run reported `CONFORM`.** It wasn't a wrong verdict — it was a wrong
*count* that still passed. A package built from final green state would show that row as a clean
pass and never surface the defect. Only the index makes it legible.

## Assembling the series

One query, which was impossible before this change:

```sql
select e.seq, e.evidence_kind, e.check_code, e.remediation_class,
       c.verdict, c.severity, c.observed,
       s.human_review_status, s.reviewed_by, e.git_ref, e.summary
from m2m_evidence_ledger e
left join m2m_conformance_audit  c on c.id        = e.conformance_audit_id
left join sovereign_execution_log s on s.record_id = e.sel_record_id
where e.series = 'SERIES-001'
order by e.seq;
```

## Evidence

```
WS54-01  CONFORM / INFO
23 evidence row(s) across 1 series
  [BASELINE=4, CORRECTION=3, DECLINE=3, DEFECT=6, REFUSAL=1, RETEST=6];
remediation classes [DETECTOR_CORRECTED=4, HOLE_CLOSED=3, NEW_COVERAGE=1];
0 RETEST row(s) cite no conformance row;
0 RETEST row(s) declare no remediation class;
4 row(s) are ASSERTION_ONLY and are NOT evidenced by any artifact
```

Grants: `service_role` only; `PUBLIC`, `anon`, `authenticated` revoked explicitly — today's WS49
root cause applied rather than re-learned. RLS enabled **with** a policy, so this table does not
add to WS24-04's count.

## Open — the boundary question

**Series 001 starting at WS48 cuts mid-stream.** PR #1's twelve commits from Aug 22–27 are the
same discipline, same ledger, same detectors, and are still unmerged. The `series` column is
deliberately free text so a `SERIES-000` can be indexed behind this one without schema change.
Not done — that's a scoping decision, not mine.

Also unresolved: the canonical branch's artifacts remain **unverified from this account**, so any
POC package drawing on both histories inherits that gap.

## Rollback

```sql
drop function if exists public.ws54_evidence_ledger_integrity_check(uuid);
drop table if exists public.m2m_evidence_ledger;
-- then re-run cron.schedule('ws10_conformance_daily','0 13 * * *', ...) without the WS54 line
```

The table is additive and referenced by nothing. Dropping it removes the index but **destroys no
evidence** — every row it points at lives in the append-only stores it joins.
