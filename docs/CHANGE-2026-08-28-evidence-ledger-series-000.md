# CHANGE · 2026-08-28 · Evidence Ledger — Series 000 (PR #1)

**Migrations:** `20260828150739`, `20260828151118` · **Detector:** `WS54-01` · **Status:** APPLIED, ledger `Pending`

---

## Two defects of mine in WS54, both found by doing this

**1 · WS54 could not reach the refusal table.** I built the join key with links to
`sovereign_execution_log` and `m2m_conformance_audit`, and I did not know
`public.muon_refusal_ledger` existed — 17 rows, typed, carrying `control_ref`,
`control_kind`, `refused_actor`, `attempted_action`, `ground` and `sqlstate`.

So `REFUSAL` rows had nowhere to point but a conformance row. For SERIES-001 that
happened to work — my one refusal was captured as the WS48-02 conformance row. For
SERIES-000 it does not: **three refusals there live only in the refusal ledger.** A
refusal is the most load-bearing artifact in either series, and the index built to make
them assemblable could not reach the table holding them.

**2 · The fix immediately caught two of my own rows.** With the refusal-artifact rule
added, WS54-01's first run over SERIES-000 returned `DEVIATION / HIGH` —
*"2 of 6 REFUSAL row(s) cite no artifact"*. Both mine: `fn_flii_machine_redirect` proved
by a rolled-back probe, and the stage-7 refusal observed before apply was enabled. Real
refusals, verified by execution — but the probes were **rolled back**, so no durable
artifact survives. Marking them `CATALOG_READ` claimed more than the record supports.

The rule was right; the classification was wrong. Both reclassified to `ASSERTION_ONLY`,
which **raises** the disclosed unartifacted count from 10 to 12 — the true number.

### Evidence weight, now stated explicitly

| Tier | Means |
|---|---|
| `EXECUTION` | a typed artifact exists — a `muon_refusal_ledger` row, or a conformance row written at the time |
| `CATALOG_READ` | verified against live catalogs, reproducible |
| `ASSERTION_ONLY` | **no artifact survives** — the declines, and refusals proven by probes that were rolled back |

## Also noted, deliberately not fixed

My WS48-02 refusal was written to `m2m_conformance_audit` rather than
`muon_refusal_ledger`, diverging from the house pattern SERIES-000 established. Writing a
refusal-ledger row for it now would be **back-dating a refusal after the fact** — the same
manufacture-evidence hazard the whole series exists to avoid. The contemporaneous
conformance row stands; the divergence is recorded here instead.

## Series 000 — 26 rows, PR #1's twelve commits

Verified against the twelve commits read from the **GitHub commits API, not the PR body**,
and against live rows. All 14 SEL records named across those commits exist and are
Approved.

`BASELINE 1 · DEFECT 8 · REFUSAL 4 · DECLINE 6 · CORRECTION 2 · RETEST 3`

### The four refusals — three with typed artifacts

| seq | Guard | SQLSTATE | What was refused |
|---|---|---|---|
| 10 | `assert_founder_session` | `P0001` | **the machine attempting to authenticate its own work** |
| 11 | `bp004_scan_provenance_gate` | `23514` | a CONFORM finding declaring `method FULL` with no declared scan scope |
| 20 | `muon_bind_loop_document` | `P0001` | an agent-session apply with `p_dry_run := false` |
| 61 | `fn_flii_machine_redirect` | — | attested only: proved by rolled-back probe, **first time it had ever fired** |

Seq 11 is the same guard that downgraded my malformed WS48-02 row six days later.

### The defects — five of eight are the machine's own

| seq | What |
|---|---|
| 12 | Stage 4/5 gate compared `text = uuid`, raising `42883` — **had never fired** because the column was NULL on all 203 rows. Populating it, the next planned step, would have broken both gates on the first write |
| 21 | **Mine.** A validator raised `22P02` instead of returning a refusal. *A security check must fail closed with a verdict, not raise.* Caught by a 30-case corpus before wiring |
| 30 | **Mine.** SEL rows cited migrations by name, not version → `DBC-001` DEVIATION, 7 of 7 orphans |
| 32 | **Mine, recurrence.** Same defect again two days later, 1 of 1. The correction fixed the instances, not the class |
| 50 | Make router branches wrote hard-coded verdicts: 117 of 120 checkpoints `TRUST`, score exactly 12, none computed. **The gate had never once declined anything** — and stage 7 reads it |
| 51 | **Mine.** *"I invented a bug and built for it"* — eight PATCH modules for a failure mode that didn't exist. Removed |
| 60 | Three functions set `fl_ii_authenticated = true` with no human session, including a `SECURITY DEFINER` RPC that stamped authentication for whichever caller invoked it |
| 70 | **The abort erased its own receipt.** The metrics INSERT preceded the sweep-log INSERT in one transaction, so the failure destroyed the row that would have recorded it. **21 hours unnoticed.** The only symptom was an absence |
| 90 | **Mine.** `PUBLIC` grant inherited on three SECDEF functions including one that mutates `loop_executions` — the anon key could drive the cycle machine. **Direct ancestor of SERIES-001 WS49** |

### The declines — six, all `ASSERTION_ONLY`

Populated zero loop→document relationships rather than invent them · did not route around
a 403 egress denial via `pg_net` · did not retro-write 119 `judge_verdicts` rows · left 158
historical false authentications as they are · said plainly that the applier *"buys exactly
one stage"* · held 9 anon-executable functions as separate scope.

That last one **SERIES-001 closed six days later.**

## Evidence

```
WS54-01  CONFORM / INFO
49 evidence row(s) across 2 series [SERIES-000=26, SERIES-001=23]
  kinds [BASELINE=5, CORRECTION=5, DECLINE=9, DEFECT=15, REFUSAL=6, RETEST=9];
  classes [DETECTOR_CORRECTED=4, HOLE_CLOSED=4, NEW_COVERAGE=4];
0 RETEST cite no conformance row;
0 RETEST declare no remediation class;
0 of 6 REFUSAL claim verification but cite no artifact (2 are attested only, and disclosed);
12 row(s) are ASSERTION_ONLY and are NOT evidenced by any artifact
```

## Assembling both series — now across four stores

```sql
select e.series, e.seq, e.evidence_kind, e.verified_by, e.remediation_class,
       c.verdict, c.severity, c.observed,
       r.control_ref, r.sqlstate, r.ground,
       s.human_review_status, s.reviewed_by,
       e.git_ref, e.summary
from m2m_evidence_ledger e
left join m2m_conformance_audit   c on c.id         = e.conformance_audit_id
left join muon_refusal_ledger     r on r.refusal_id = e.refusal_id
left join sovereign_execution_log s on s.record_id  = e.sel_record_id
order by e.series, e.seq;
```

## Rollback

```sql
delete from public.m2m_evidence_ledger where series = 'SERIES-000';
alter table public.m2m_evidence_ledger drop column if exists refusal_id;
-- CREATE OR REPLACE the WS54-01 body from migration 20260828124948
```

Additive throughout. No evidence is destroyed — every row the index points at lives in the
append-only stores it joins.
