-- ============================================================================
-- WS55 · Add the refusal link WS54 was missing, and index SERIES-000.
--
-- MY DEFECT IN WS54, FOUND WHILE INDEXING SERIES-000
--   I built m2m_evidence_ledger with links to sovereign_execution_log and
--   m2m_conformance_audit, and asserted that DECLINES are ASSERTION_ONLY
--   because "no artifact proves a non-action". Both true. But I did not know
--   public.muon_refusal_ledger existed -- 17 rows, typed, carrying control_ref,
--   control_kind, refused_actor, attempted_action, ground and SQLSTATE.
--
--   So WS54 gave REFUSAL rows nowhere to point except a conformance row. For
--   SERIES-001 that happened to work: my one refusal was captured as the
--   WS48-02 conformance row. For SERIES-000 it does not -- three refusals there
--   are recorded in muon_refusal_ledger and nowhere else. A REFUSAL is the most
--   load-bearing artifact in either series, and the join key built to make them
--   assemblable could not reach the table that holds them.
--
--   Fixed additively: refusal_id column, FK to muon_refusal_ledger(refusal_id),
--   index, and WS54-01 extended so a REFUSAL must cite a conformance row OR a
--   refusal row. Nothing existing altered.
--
--   Related, noted and NOT retro-fixed: my WS48-02 refusal was written to
--   m2m_conformance_audit rather than muon_refusal_ledger, diverging from the
--   house pattern SERIES-000 established. Writing a refusal-ledger row for it
--   now would be back-dating a refusal after the fact -- the same
--   manufacture-evidence hazard the series exists to avoid. The contemporaneous
--   conformance row stands; the divergence is recorded instead.
--
-- SERIES-000 · PR #1, twelve commits, 2026-08-22 to 2026-08-27, 26 rows
--   Verified against the twelve commits read from the GitHub commits API, NOT
--   from the PR body, and against live rows. All 14 SEL records named across
--   those commits exist and are Approved. Every conformance_audit_id and
--   refusal_id was read from the catalog; the FKs would reject any that did not.
--
--   Two threads run from SERIES-000 into SERIES-001:
--     - bp004_scan_provenance_gate refused a CONFORM finding on 2026-08-22
--       (SERIES-000 seq 11, SQLSTATE 23514) and downgraded my malformed WS48-02
--       row on 2026-08-28 (SERIES-001 seq 21). Same guard, six days apart.
--     - SERIES-000 seq 91 held "9 further anon-executable SECURITY DEFINER
--       functions predate this session". WS49 took that set 9 -> 4 and WS51
--       took it to 3. The held item and its closure are both on the record.
--
--   Row shape: BASELINE 1 · DEFECT 8 · REFUSAL 4 · DECLINE 6 · CORRECTION 2 ·
--   RETEST 3 (SERIES-000 alone). Full row-by-row text in
--   docs/CHANGE-2026-08-28-evidence-ledger-series-000.md.
-- ============================================================================

alter table public.m2m_evidence_ledger
  add column if not exists refusal_id uuid references public.muon_refusal_ledger(refusal_id);

create index if not exists idx_evidence_ledger_refusal
  on public.m2m_evidence_ledger (refusal_id);

comment on column public.m2m_evidence_ledger.refusal_id is
  'Link to muon_refusal_ledger for refusals captured as typed refusal records rather than as conformance findings. Added by WS55 after SERIES-000 revealed WS54 had no path to the refusal table.';

-- WS54-01 replaced with the refusal-artifact rule added; superseded in the same
-- session by WS55-01a (see 20260828151118). Retrieve the live body with
--   pg_get_functiondef('public.ws54_evidence_ledger_integrity_check'::regproc)
--
-- SERIES-000 population: 26 rows inserted in this migration.
