# Atlas ↔ CC repository / evidence crosswalk — opening pass

**Date:** 2026-08-28 · **Author:** CC (adversarial lane) · **Status:** CC side populated, Atlas side unfilled
**Scope:** record reconciliation only. No production changes. Nothing merged, nothing authenticated.

---

## 0 · What this document can and cannot establish

This pass was run from a Claude Code remote session scoped to `drivenbydesign1-tech/M2M-`.
It reads that repository and the live Supabase project `jnmywpfdykuybrxkdcmc` directly.

**It cannot read `Kali-Dedwen/m2m-sovereign-stack`,** the canonical repository. Every claim
below about canonical is therefore either (a) read from a database row written by someone
else, or (b) an open question for Atlas. Nothing here verifies canonical's contents.

Reachability was established by capability test, not by reading a repository catalog —
that catalog returned three different answers within twenty minutes on 2026-08-28 and is
not trustworthy as evidence. Four independent probes:

| Probe | Result |
|---|---|
| `list_branches Kali-Dedwen/m2m-sovereign-stack` (session MCP) | `not configured for this session; allowed: drivenbydesign1-tech/m2m-` |
| `list_branches` (separate account connector) | `404 Not Found` |
| `add_repo Kali-Dedwen/m2m-sovereign-stack` | `cross-tier adds are not supported in v1` |
| account repo listing | 10 repos, all `drivenbydesign1-tech`, no `Kali-Dedwen` |

**Mechanism: session repository scoping, fixed at session start.** Not an account
permissions gap, and not a credential identity swap — both of which I asserted earlier
today and both of which were wrong. The Claude GitHub App was installed on
`drivenbydesign1-tech` at ~16:10Z with read+write; that fixed pushes and PR writes to
*this* repo and did **not** open canonical. The remedy named by the tooling is a new
session created with the canonical repo as its initial source. More permissions will not
open it from here.

---

## 1 · Repository roles — from `public.m2m_repository_registry` (12 rows)

Read from the live registry, not asserted. `access_status` is that table's own field and
reflects a **push credential**, not this session's reachability.

| Repository | Role | Access status (registry) | Reachable from this session |
|---|---|---|---|
| `Kali-Dedwen/m2m-sovereign-stack` | **canonical** | push-admin | **NO** |
| `Kali-Dedwen/drivenbydesign1-tech` | application (model2message.net) | push-admin | NO |
| `Kali-Dedwen/m2m-sovereign-compute` | sovereign-compute | push-admin | NO |
| `Kali-Dedwen/m2m-assessment` | assessment | push-admin | NO |
| `Kali-Dedwen/M2M` | public-repo (default branch ≠ main) | push-admin-nonmain | NO |
| `Kali-Dedwen/M2M-` | **empty** | empty-skip | NO |
| `Kali-Dedwen/nextjs-boilerplate` · `kevin-smith-notes` · `m2m-platform-demo` · `sovereign-stack-showcase` | boilerplate / notes / demo / showcase | push-admin | NO |
| `drivenbydesign1-tech/human-heart-core` | skills-core | **inaccessible-404** | NO |
| `drivenbydesign1-tech/M2M-` | working-authorization-hardening | push-admin | **YES** |

**Naming hazard, load-bearing:** `Kali-Dedwen/M2M-` and `drivenbydesign1-tech/M2M-` differ
only by owner. The former is registered **empty**; the latter holds PR #1 and PR #2. Any
reference to "M2M-" without an owner prefix is ambiguous and must be treated as unresolved.

**Canonical designation** is settled: `Kali-Dedwen/m2m-sovereign-stack`, by Founder decision
2026-08-28 (WS53, applied as `20260828114108`). The competing free-text "Canonical" claim in
the `Kali-Dedwen/drivenbydesign1-tech` row is marked superseded in place, prior text retained.

---

## 2 · Migration provenance — the bridge that does not bridge

`public.muon_repo_migration_hash` is the only table in the stack that looks like a
repository↔database provenance link. Column `repo_body_sha256` asserts, by its name, that
it holds the hash of a repository file. **For 98% of its versions it does not.**

1,125 rows · 374 distinct versions · 4 posting runs · every row carries a `git_sha`.
Split by the `normaliser` column:

| Normaliser | Rows | Versions | What was hashed |
|---|---|---|---|
| `v1-reconstructed-functional` | 1,096 | 366 | a body **reconstructed from the live database** |
| `v1-local-verified` | 24 | 24 | actual repository file bytes |
| `v1-byte-original` | 5 | 2 | actual bytes |

The 18 versions where one version carries two different bodies are **not** two repositories
disagreeing. They split cleanly along the normaliser: the single `v1-local-verified` run
(`claude-code-manual`, 2026-08-18) disagrees with the three later reconstructed runs, which
agree with each other **exactly**. Three independent runs producing byte-identical
"repo" hashes is the signature of a deterministic derivation, not three independent reads
of a repository.

**Consequence.** A hash derived from the database and then compared against the database
cannot detect drift between repository and database. It is circular. For 366 of 374
versions this table cannot answer the one question a crosswalk needs it to answer:
*does the repository file match what was applied?*

> Stated at the right strength: this is inferred from the `normaliser` values plus the
> observed identical-across-runs behaviour. The posting code lives in a repository this
> session cannot read, so it is **CATALOG_READ**, not **EXECUTION**. Atlas should confirm
> or refute by reading the posting script.

**The bridge is also stale.** Last posting 2026-08-24. 14 applied migrations carry no hash
row at all — WS46 and WS47 from PR #1, and **all twelve** WS48–WS55 migrations. The
authorization-hardening series has zero repo-hash provenance.

Six hash versions have no matching applied migration (`20260611`, `20260718`, `20260724`,
`20260725`, and two `20260813_*`). All six are `v1-local-verified` and use a version format
`schema_migrations` does not carry. Open question, not a finding.

Totals: **382** applied migrations in `schema_migrations`; **374** versions hashed; overlap
**368**.

---

## 3 · Branch and PR lineage — CC side, verified

| | PR #1 | PR #2 |
|---|---|---|
| Repo | `drivenbydesign1-tech/M2M-` | same |
| Branch | `claude/2m-build-status-sequence-a4ya61` | `claude/atlas-authorization-hardening-hlkdb0` |
| Base | `main` (`b552743`) | `main` (`b552743`) |
| Head | `4bd96e5` | `edcfbba` |
| Commits | 12 | 11 |
| State | open, **draft**, unmerged | open, **draft**, mergeable clean, unmerged |
| CI | — | `build` SUCCESS on `edcfbba`, 16:12:07Z |
| Review threads | 0 | 0 |
| Evidence series | SERIES-000, 26 rows | SERIES-001, 23 rows |

Neither PR is merged. `main` has not moved. **PRs #5 and #14**, cited in
`SEL-20260827-AF9B1D84` and `SEL-20260827-14D65378`, do not exist in this repository and
belong to a repo this session cannot read — unresolved, and the reason a crosswalk was
called for.

---

## 4 · Evidence and execution records — CC side, verified

- `m2m_evidence_ledger` — **49** rows, 2 series, joining four stores
  (`sovereign_execution_log`, `m2m_conformance_audit`, `muon_refusal_ledger`, git).
- `sovereign_execution_log` — **397** rows, **16** not Approved (none from WS48–WS55).
- `muon_refusal_ledger` — **17** typed refusals.
- Detectors CONFORM: WS24-01, WS24-03, WS24-05, WS31-01, WS48-01, WS48-02, WS49-01,
  WS50-01, WS54-01.

---

## 5 · Defect found in CC's own work by this pass

Three of twelve migrations on `claude/atlas-authorization-hardening-hlkdb0` carried
filenames that did not match their applied versions:

| Applied version | Repo filename (before) | Corrected to |
|---|---|---|
| `20260828112835` ws51 | `20260828114500_ws51_…` | `20260828112835_ws51_…` |
| `20260828113530` ws52 | `20260828115900_ws52_…` | `20260828113530_ws52_…` |
| `20260828114108` ws53 | `20260828120400_ws53_…` | `20260828114108_ws53_…` |

PR #2's body closed with: *"Migration filenames match their applied versions so filename and
`schema_migrations` agree."* **That statement was false when published**, and PR #2's own
table cited the three wrong versions. Both corrected; files renamed to match the database,
which is authoritative because these already applied.

This is a recurrence of **DBC-001** from PR #1 — *"my ledger rows cited migrations by name,
not version"* — the third appearance of the same defect class in seven days. The pattern is
not carelessness about digits; it is **citing an identifier from the artifact I wrote rather
than from the catalog that owns it.**

I also nearly recorded a fourth mismatch. WS48 appeared wrong because `git log
--diff-filter=A` reports a file's name *at the commit that added it*, and WS48 had been
renamed in a later commit. It was already correct. Checking the tree state rather than the
add-time name is what caught it — the same class of error as trusting a probe that cannot
fail.

---

## 6 · Open slots — Atlas to fill from canonical

Not questions about opinion. Each has a definite answer readable from the canonical repo.

1. **Branch/PR lineage.** What are PR #5 and PR #14 in `Kali-Dedwen/m2m-sovereign-stack`?
   Head SHAs, base, state, merged-or-not. `SEL-20260827-AF9B1D84` and
   `SEL-20260827-14D65378` cite them.
2. **`mcp/hardening-reconciliation-001`.** Commits `3d15017`, `7a6a8c7`, `f73971a`,
   `931ef37` and their artifacts are **ASSERTION_ONLY** from this side — reported, not
   verified. Confirm they exist at those SHAs on that branch.
3. **The hash poster.** Read the script behind `ddl-recon-001-*` and
   `authcontain-001-postmerge-parity`. Does `v1-reconstructed-functional` derive its body
   from the live database? If yes, §2's circularity finding stands and the table needs a
   normaliser that hashes repository bytes.
4. **Which repository do the four `git_sha` values belong to?**
   `d5d3378c9bcc`, `ef292df72535`, `43b062bbb9cd`, `17bc7998b4da` — none resolve in
   `drivenbydesign1-tech/M2M-`.
5. **Migration overlap.** Do canonical's `supabase/migrations/` files include the WS48–WS55
   versions, or are the two histories fully disjoint? This determines whether the
   authorization-hardening work must be ported or merely referenced.
6. **Duplicate/conflicting claims.** Does canonical contain a competing record of the
   canonical designation, the repository registry, or the evidence ledger?

---

## 7 · What would falsify this document

- Any canonical file proving `v1-reconstructed-functional` hashes repository bytes → §2's
  central finding is wrong and should be struck, not softened.
- A session that reaches both repositories at once → §0's mechanism claim is wrong.
- A WS48–WS55 version appearing in canonical's migrations → §3's "separate histories"
  premise needs reworking.

The two histories stay **explicitly separate until reconciled.** Neither repository proves
the other. This document is one half of a crosswalk, and says so.

---

## 8 · Addendum — Atlas pass 2 returned, 2026-08-28

Appended, not edited. Sections 0–7 stand as originally written.

### 8.1 · Atlas's WS47 finding: CONFIRMED by execution, and it is mine

Atlas reports that the working tree names WS47 `20260827134500` while the contemporaneous
record reports the applied version as `20260827133939`. **Verified here against two primary
sources**, not accepted on report:

| Source | Value |
|---|---|
| `origin/claude/2m-build-status-sequence-a4ya61` (PR #1 branch, git tree) | `20260827134500_ws47_revoke_public_execute_on_new_security_definer_functions.sql` |
| `supabase_migrations.schema_migrations` (live catalog) | `20260827133939` · `ws47_revoke_public_execute_on_new_security_definer_functions` |

Rather than confirm only the row Atlas named, all **17** migrations on that branch were
swept by joining repo filename against the catalog on migration *name*. Result: **1 of 17
mismatched.** WS47 alone. WS43 ×4, WS44, WS45, WS46, the four `muon_*`, and the five
`m2m_*`/`loop_*` all agree exactly. WS46 — the immediate predecessor, same day, same
session — is correct, which rules out a clock or convention drift and isolates it to a
single hand-written filename.

**WS47 is NOT corrected here.** It lives on PR #1's branch, which is not this session's
designated branch; pushing to it requires explicit permission. Recorded as open.

### 8.2 · The correct occurrence count is four, and my own PR understated it

PR #2's correction item 8 calls the WS51/52/53 rename "the third appearance of the DBC-001
defect class in seven days." With WS47 confirmed, that is wrong. The true sequence:

| # | When | Where | Status |
|---|---|---|---|
| 1 | 2026-08-22/23 | DBC-001 — SEL rows citing migrations by *name*, not *version* | corrected in PR #1 |
| 2 | 2026-08-22/23 | recurrence, same series, after correction #1 | corrected |
| 3 | **2026-08-27** | **WS47 filename `134500` vs applied `133939`** | **OPEN** |
| 4 | 2026-08-28 | WS51/52/53 filenames vs applied versions | corrected, `18951e1` |

Four occurrences in seven days, one still open. Corrected in the PR body.

### 8.3 · Series 000 indexed PR #1 and did not catch this

This is the more serious half. `WS55` indexed PR #1's twelve commits as SERIES-000 and
reported them "verified against the commits read from the GitHub API rather than the PR
body, and against live rows." That verification checked **that the 14 named SEL records
exist and are Approved**. It never checked whether each migration's repo filename agrees
with its applied version.

So a 26-row evidence index built specifically to preserve defects passed over a live,
uncorrected instance of the exact defect class it was indexing. The index verified
*citation existence*, not *identifier agreement* — a narrower question than the one it
appeared to answer. Same shape as WS31-01 matching mentions instead of assignments: a
check whose stated scope is wider than its actual predicate.

Atlas found it from the canonical side. That is the crosswalk working as intended, in the
direction that matters — the other party catching what this side's own index missed.

### 8.4 · Atlas's port gate

The proposed chain — live catalog → exact migration version → working artifact →
**independent repository-byte hash** → predecessor compatibility → rollback → canonical CI
→ adversarial review → Founder disposition — closes §2's circularity finding at the right
point. "Independent repository-byte hash" is the correct specification: it must be computed
by a normaliser that has never read the database, or it reproduces
`v1-reconstructed-functional` under a new name. Recommend the gate state that constraint
explicitly rather than leaving it to the implementer.

One addition, from 8.1: the gate's *predecessor compatibility* step must treat WS47 as
**open**, not merely present. WS46 and WS47 sit between canonical WS45 and WS48, and WS47's
repo filename does not name the version that actually applied. Porting WS48–WS55 over a
predecessor whose identifier is wrong would carry the defect into canonical.

### 8.5 · Slot status after this pass

| Slot | Status |
|---|---|
| 1 · PR #5 / #14 identity | **partially answered** — PR #14 reported mergeable=true, draft, unmerged, 11 ahead / 0 behind; earlier mergeable=false was transient GitHub computation. PR #5 still unaddressed. |
| 2 · `mcp/hardening-reconciliation-001` commits | **still ASSERTION_ONLY** — `3d15017`, `7a6a8c7`, `f73971a`, `931ef37`, `a102c54` all unreadable from here |
| 3 · what the hash poster hashes | **open** — the §2 finding stands unrefuted |
| 4 · which repo the four `git_sha` values belong to | **open** |
| 5 · migration overlap canonical ↔ WS48–WS55 | **advanced** — port assessment exists; WS46/WS47 identified as the intervening gap |
| 6 · duplicate/conflicting claims | **open** |

Atlas reports three workflows green on crosswalk head `7875a5cf` (Sovereign Security
Harness, Operational Core G2, repository-resilience) and no CI yet on `a102c54`. Both are
**ASSERTION_ONLY** from this side — reported, not verified, and correctly flagged as
not-yet-CI-verified by Atlas.

---

## 9 · WS47 closed — and §8.2 mischaracterised it

Fixed under explicit Founder authorization 2026-08-28. Commit `d81b3c9` on
`claude/2m-build-status-sequence-a4ya61` (PR #1's branch), pushed `4bd96e5..d81b3c9`.
Filename only; the file body is byte-identical.

**§8.2 called this "the fourth appearance of DBC-001." That is the wrong classification,
and the direction it gets wrong is the interesting part.**

DBC-001 was *my ledger rows citing migrations by name rather than version* — the **ledger**
was wrong and the repository was right. WS47 is the inverse. Checked before renaming:

```
SEL-20260827-28AF3D1B   human_review_status = Approved
deliverable_location    supabase/migrations/20260827133939_ws47_revoke_public_execute_…sql
```

The ledger records the **applied** version, correctly. The repository filed the same
migration as `…134500`. So the citation was never wrong — **its target was missing.** An
Approved, Founder-authenticated execution record had been pointing at a repository path
that did not exist, from 2026-08-27 until now.

That reframes the risk. A wrong citation is findable by reading the ledger. A *correct*
citation whose target is absent is only findable by resolving the reference against the
repository — which nothing in this stack was doing, because §2's hash bridge is the thing
that would have done it, and it is circular and stale. The two findings are the same gap
seen from opposite ends.

It also explains why the fix direction is not arbitrary. The database is authoritative
twice over here: it owns the applied version, *and* the already-approved ledger row names
the corrected filename. The file moves to meet the record; the record was never edited.

**Scope of the sweep, restated:** all 17 migrations on that branch, joined to the live
catalog on migration name. One mismatch. WS46 — same day, same session, immediate
predecessor — correct. Not drift; one hand-typed filename.

Verified after the push: `origin/claude/2m-build-status-sequence-a4ya61` now carries
`20260827133939_ws47_…`, and the repo-vs-catalog sweep across **both** branches (17 + 12 =
29 migrations) returns **zero** mismatches.

Corrected count for the record: **three** DBC-001 instances (two in PR #1's series, one
being the WS51/52/53 rename), plus **one** inverse-direction instance (WS47). Not four of
the same thing.
