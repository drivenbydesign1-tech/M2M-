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
