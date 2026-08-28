<!--
Canonical text of the PR #2 description, as of 2026-08-28.

Held here because the GitHub App credential for this session can READ pull
requests but cannot WRITE them: every PATCH to /pulls/2 returned
403 "Resource not accessible by integration", across two attempt rounds,
while git push to this branch succeeded in the same window. The live PR body
is therefore STALE against this file until someone with PR-write permission
applies it. Apply it verbatim; do not re-draft from memory.
-->

<!-- PR title: Authorization hardening WS48–WS55: two live authorization holes, three miscalibrated detectors, one evidence join key -->

All ten migrations **APPLIED** to `jnmywpfdykuybrxkdcmc` under narrow Founder authorization, each evidenced by a detector run. **Scope is closed** — no further production changes under this authorization.

| | Applied | Detector | Ledger |
|---|---|---|---|
| **WS48** `eco_authenticate` gated behind `assert_founder_session()` | `…095500`, `…095705` | WS48-01, WS48-02 `CONFORM` | **Approved** |
| **WS49** anon `EXECUTE` closed across the `SECURITY DEFINER` surface | `…103722`, `…103841` | WS49-01 `CONFORM` | **Approved** |
| **WS50** anon DML closed on an FL/II provenance view; WS31-01 rescoped | `…112312` | WS50-01, WS31-01 `CONFORM` | **Approved** |
| **WS51** last provisional acceptance resolved | `…114500` | WS24-03 `CONFORM` | **Approved** |
| **WS52** WS24-05 rescoped; working repo registered | `…115900` | WS24-05 `CONFORM` | **Approved** |
| **WS53** Founder canonical designation recorded | `…120400` | — | **Approved** |
| **WS54** evidence-ledger join key; Series 001 indexed | `…124948`, `…125145` | WS54-01 `CONFORM` | **Approved** |
| **WS55** refusal link added; Series 000 indexed (PR #1) | `…150739`, `…151118` | WS54-01 `CONFORM` | **Approved** |

---

## Corrections to my own reporting, first

Seven, because they're the most important thing in this PR.

**1 · A claim I retract entirely.** I reported — here, in two migrations, in WS49-01's evidence field, and in `SEL-20260828-A2018879` **which was authenticated on it** — that *"WS24-01's scan scope is too narrow for anon-reachable `SECURITY DEFINER` functions."* **Wrong.** WS24-01 measures owner-executing **views**, not functions; the function check is **WS24-03**. WS24-01 was never defective, and its "1 anon-reachable" was a true finding. Corrected in WS50, including the evidence field WS49-01 had been stamping into every row it emitted.

**2 · WS49 did not close WS24-03, as it claimed.** It took the unexpected set from five to one. WS51 closed it properly.

**3 · Two functions wrongly named as conformance writers.** `fn_canonical_last_write` is `STABLE` — a heartbeat that *reads* the audit table. `fn_flii_machine_redirect` is a trigger function, never exposed over PostgREST.

**4 · A rollback path of mine would have failed on execution.** It omitted `p_notes DEFAULT NULL::text` and an already-present `SET search_path`. Caught in pre-flight.

**5 · Two detectors of mine flagged their own decisions on first run.** WS48-01 counted itself; WS49-01's allowlist omitted a grant WS49 had deliberately preserved.

**6 · WS54's join key could not reach the refusal table.** I built it with links to `sovereign_execution_log` and `m2m_conformance_audit` and did not know `public.muon_refusal_ledger` existed — 17 typed rows carrying `control_ref`, `refused_actor`, `ground` and `sqlstate`. REFUSAL rows had nowhere to point. It happened to work for Series 001 and does not work for Series 000, where three refusals live only in that ledger. **A refusal is the most load-bearing artifact in either series and the index could not reach the table holding them.** Fixed in WS55.

**7 · That fix immediately caught two of my own rows.** With the refusal-artifact rule added, WS54-01's first run over Series 000 returned `DEVIATION/HIGH` — two REFUSAL rows marked `CATALOG_READ` were proven by probes that were **rolled back**, so no durable artifact survives. Reclassified to `ASSERTION_ONLY`, which **raises** the disclosed unartifacted count from 10 to 12. Nothing loosened.

Corrections 3, 5 and 7 share one root cause with the detectors this PR fixes: **asserting behaviour from a substring or a claim instead of testing it.**

## Two real authorization holes

**`eco_authenticate` accepted a database role in place of a human.** Its only check was `current_user IN ('service_role','postgres','supabase_admin')` — then it wrote `auth_status = 'AUTHENTICATED'` and a record naming the Founder as actor. Proved by contradiction, without writing:

```
current_user = 'postgres'   auth.uid() = NULL
  -> ACCEPTED by eco_authenticate's containment check
  -> REFUSED  by assert_founder_session()
```

And the inverse: the Founder's own session runs as `authenticated`, which that check **rejected**, with no `EXECUTE` grant. The permitted callers were the ones that must never be trusted; the one human who should authenticate was locked out. Not a missing lock — `assert_founder_session()` already gated five sibling surfaces. This conformed the outlier.

**`v_flii_provenance_review` was anon-writable.** An owner-executing, auto-updatable view over `loop_executions` projecting `fl_ii_authenticated_by AS claimed_actor`, granted `arwdDxtm` — full DML — to **both `anon` and `authenticated`**. Owner-executing views run base-table permission *and RLS* checks as the **view owner**, so the `service_role`-only RLS policy on `loop_executions` did not apply to writes routed through it. An anon key holder could have rewritten **who is recorded as having authenticated a sovereign task**. Same defect class as WS48, reachable anonymously.

**Neither was demonstrated by execution.** Proving either would have forged exactly the record it protects.

## Root cause of the anon surface

Eight of nine functions carried `=X/postgres` in `proacl` — **the `PUBLIC` grant**, which Supabase resolves to `anon`. Nobody granted `anon` anything; it was inherited at `CREATE FUNCTION` time, invisible in the source. Fix: `REVOKE … FROM PUBLIC`, then re-grant deliberately. Three surfaces stay anon-reachable **by design** — the whistleblower submit and status paths, and a token-gated result read — encoded in an allowlist and **printed on every run** rather than disappearing into CONFORM.

## Three detectors were miscalibrated

Each had been alarming on false positives, some for weeks. All three fixed by replacing an enumerated exclusion or a substring match with a behavioural test — **never by weakening a rule.**

| Detector | Was | Actually |
|---|---|---|
| **WS31-01** | BLOCKING since 08-19, "9 unguarded writers" | 8 were readers. One assigner: an AFTER trigger reacting to an already-vetted transition, on a table whose BEFORE trigger redirects machine writes first → **0** |
| **WS24-05** | HIGH since 08-16, "4 contracts lack backfill" | All four have **no tenant column** — backfill is *not applicable*, not incomplete. Every tenant-scoped contract was already complete → **7 of 7** |
| **WS49-01** | flagged its own preserved grant | allowlist corrected, acceptance marked provisional with its weakness printed |

## The evidence ledger (WS54–WS55)

Series 001 must preserve **defects, refusals, corrections and successful retests — not merely the final green state.** I checked whether that evidence was assemblable before agreeing it was. It was not.

`m2m_conformance_audit` has **zero foreign keys**. On 2026-08-28 alone: 12 SEL rows and 27 conformance rows, correlatable only by timestamp proximity and by reading prose. The evidence for one defect sat in **four unjoined stores** — conformance holds the before/after verdict but never *why*; the execution log holds the why in free text; the refusal ledger holds the typed refusals; git holds the defective code, since `pg_get_functiondef` now returns only corrected bodies.

A link column was impossible: `trg_m2m_conformance_audit_finding_frozen` blocks `UPDATE`, so the rows that matter could never be backfilled. **An additive index is the only design that does not touch frozen evidence.**

Two honesty mechanisms live in the schema itself, not in prose:

- **`remediation_class`** separates `HOLE_CLOSED` (WS24-01, WS24-03, WS48-01 — a real hole shut) from `DETECTOR_CORRECTED` (WS31-01, WS24-05 — the check was wrong and the system was always fine) from `NEW_COVERAGE`. Merging these would overstate the work: **WS24-05 remediated nothing; it silenced a twelve-day false alarm.**
- **`verified_by`** is three tiers — `EXECUTION` (a typed artifact exists), `CATALOG_READ` (verified against live catalogs, reproducible), `ASSERTION_ONLY` (no artifact survives: the declines, and refusals proven by probes that were rolled back). WS54-01 prints the `ASSERTION_ONLY` count **every run** so it cannot be quietly dropped.

**49 rows across two series**, resolving in one join across all four stores. Series 000 indexes PR #1's twelve commits — verified against the commits read from the GitHub API rather than the PR body, and against live rows; all 14 SEL records named there exist and are Approved. Five of its eight defects are the machine's own, including **a recurrence of the same ledger-citation defect two days after it was first corrected.**

The subtlety that justifies the exercise: **the defective WS48-01 run reported verdict `CONFORM`.** Not a wrong verdict — a wrong *count* that still passed. A package built from final green state would show it as a clean pass and never surface the defect.

Noted and deliberately **not** fixed: my WS48-02 refusal was written to `m2m_conformance_audit` rather than `muon_refusal_ledger`, diverging from the house pattern. Writing a refusal-ledger row for it now would be back-dating a refusal after the fact — the same manufacture-evidence hazard the series exists to avoid. The contemporaneous conformance row stands.

## Result

| Check | Was | Now |
|---|---|---|
| WS24-01 | BLOCKING | **CONFORM** |
| WS24-03 | BLOCKING | **CONFORM** |
| WS24-05 | HIGH | **CONFORM** |
| WS31-01 | BLOCKING | **CONFORM** |
| WS48-01/-02, WS49-01, WS50-01, WS54-01 | — | **CONFORM** |

Anon-reachable `SECURITY DEFINER` functions **9 → 3**, all deliberate. Owner-executing views writable by anon **1 → 0**.

## Registry

`Kali-Dedwen/m2m-sovereign-stack` confirmed **canonical** by Founder decision 2026-08-28. The competing free-text claim on `Kali-Dedwen/drivenbydesign1-tech` is marked **superseded in place**, prior text retained. This repository was **absent from the registry entirely** while holding PR #1 and PR #2; now registered as `working-authorization-hardening` — not the stack of record.

Recorded with it: **the canonical repository is not reachable from this session.** The mechanism is session repository scoping fixed at session start — not a permissions gap on the account. Established by capability test, not by reading the repository catalog: a `list_branches` call against the canonical repo returned *"not configured for this session; allowed repositories: drivenbydesign1-tech/m2m-"*. The account connector may well expose both organisations; **this session** is scoped to one repo. Nothing in the canonical repository has been reviewed from here. That is why PRs #5 and #14 — referenced in `SEL-20260827-AF9B1D84` and `SEL-20260827-14D65378` — cannot be checked from here, and a repository/evidence crosswalk requires a session created with the canonical repo as a source.

## Held, not done — preserved for the next cycle

Per Founder instruction 2026-08-28, scope is closed and these are **not** taken:

- **WS24-02** — 4 of 211 functions carry a mutable `search_path` (MEDIUM).
- **WS24-04** — 63 of 185 RLS-enabled tables lack a policy, against a baseline of 57 (MEDIUM). RLS-on-with-no-policy is **deny-all**, so the drift is fail-*closed*: a functionality risk, not new exposure. Deserves later triage for which six and whether any are live surfaces.

No G6 declaration, no migration 369, no FL/II cutover, no root-key activation, no authority transfer, no merge. **No authentication performed by the machine** — the gate refused this session on the record, which is the point.

Migration filenames match their **applied** versions so filename and `schema_migrations` agree.