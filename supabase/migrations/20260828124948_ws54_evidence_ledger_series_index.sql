-- ============================================================================
-- WS54 · Evidence Ledger — the join key that makes a series assemblable
--        rather than reconstructable.
--
-- THE PROBLEM
--   m2m_conformance_audit carries ZERO foreign keys. No column references the
--   execution log; no execution-log column references a check_code or run_id.
--   2026-08-28 alone: 12 SEL rows, 27 conformance rows, correlatable only by
--   timestamp proximity and by reading prose. Evidence for one defect sits in
--   three unjoined stores:
--     m2m_conformance_audit   the before/after verdicts, never WHY they changed
--     sovereign_execution_log the why, in free-text dart_deconstruct
--     git                     the defective code — pg_get_functiondef now
--                             returns only corrected bodies
--   Assembled from any one alone a POC package misleads: a green dashboard with
--   no defects, narrative with no verification, or code with no live proof.
--
-- WHY A TABLE AND NOT A COLUMN
--   trg_m2m_conformance_audit_finding_frozen blocks UPDATE, so a link column
--   could never be backfilled onto the rows that matter. An additive index is
--   the only design that does not touch frozen evidence.
--
-- TWO HONESTY MECHANISMS IN THE SCHEMA ITSELF
--   remediation_class separates HOLE_CLOSED (a real hole shut) from
--   DETECTOR_CORRECTED (the check was wrong; the system was always fine) from
--   NEW_COVERAGE (no prior verdict exists). Merging these overstates the work.
--   verified_by marks the DECLINES as ASSERTION_ONLY, because NO ARTIFACT
--   PROVES A NON-ACTION. WS54-01 prints that count every run.
--
-- GRANTS apply today's WS49 lesson rather than re-learning it: REVOKE FROM
-- PUBLIC explicitly, since that grant is inherited at CREATE time and invisible
-- in the source. RLS is enabled WITH a policy so this table does not add to
-- WS24-04's count of RLS-enabled tables lacking one.
-- ============================================================================

create table if not exists public.m2m_evidence_ledger (
  id                    uuid primary key default gen_random_uuid(),
  series                text        not null,
  seq                   int         not null,
  evidence_kind         text        not null
                          check (evidence_kind in
                            ('BASELINE','DEFECT','REFUSAL','DECLINE','CORRECTION','RETEST')),
  verified_by           text        not null
                          check (verified_by in
                            ('EXECUTION','CATALOG_READ','ASSERTION_ONLY')),
  remediation_class     text
                          check (remediation_class in
                            ('HOLE_CLOSED','DETECTOR_CORRECTED','NEW_COVERAGE','NOT_APPLICABLE')),
  sel_record_id         text        references public.sovereign_execution_log(record_id),
  check_code            text,
  conformance_audit_id  uuid        references public.m2m_conformance_audit(id),
  git_ref               text,
  summary               text        not null,
  created_at            timestamptz not null default now(),
  unique (series, seq)
);

comment on table public.m2m_evidence_ledger is
  'Join key between sovereign_execution_log (why) and m2m_conformance_audit (before/after), with git_ref for code that exists only in version control. remediation_class separates a closed hole from a corrected detector; verified_by marks declines as ASSERTION_ONLY because no artifact proves a non-action.';

alter table public.m2m_evidence_ledger enable row level security;

drop policy if exists m2m_evidence_ledger_service_role on public.m2m_evidence_ledger;
create policy m2m_evidence_ledger_service_role on public.m2m_evidence_ledger
  for all to service_role using (true) with check (true);

revoke all on public.m2m_evidence_ledger from public, anon, authenticated;
grant select, insert on public.m2m_evidence_ledger to service_role;

create index if not exists idx_evidence_ledger_series on public.m2m_evidence_ledger (series, seq);
create index if not exists idx_evidence_ledger_sel    on public.m2m_evidence_ledger (sel_record_id);

-- WS54-01 · index integrity. Reaches CONFORM; keeps the honest counts visible.
-- Full body applied in this migration; retrieve with
--   pg_get_functiondef('public.ws54_evidence_ledger_integrity_check'::regproc)
-- Verdict rules:
--   DEVIATION if any RETEST row cites no conformance row (HIGH) or declares no
--   remediation_class (MEDIUM). The ASSERTION_ONLY count is always printed in
--   observed and evidence, never used to fail the check — it is disclosure,
--   not a defect.
--
-- SERIES-001 population: 23 rows inserted in this migration
--   BASELINE 4 · DEFECT 6 · REFUSAL 1 · DECLINE 3 · CORRECTION 3 · RETEST 6
--   remediation classes: HOLE_CLOSED 3 · DETECTOR_CORRECTED 4 · NEW_COVERAGE 1
--   Six of the DEFECT rows are CC's own. Every conformance_audit_id and
--   sel_record_id was read directly from the catalog before insertion; the FK
--   constraints would have rejected any that did not exist. Full row-by-row
--   text is in docs/CHANGE-2026-08-28-evidence-ledger-series-001.md.
--
-- Verified after applying: WS54-01 CONFORM/INFO — 23 rows, 1 series,
--   0 RETEST rows citing no conformance row, 0 declaring no remediation class,
--   4 rows ASSERTION_ONLY and disclosed as not evidenced by any artifact.
