-- ============================================================================
-- WS52 · A. Correct WS24-05 from an enumerated exclusion to a behavioural test.
--        B. Register the repository this work is done in. Canonical DESIGNATION
--           deliberately left NULL -- that is a Founder act.
--
-- A · WS24-05 HAD BEEN A FALSE POSITIVE AT HIGH SINCE 2026-08-16
--
--   Universe was `policy_applied and isolation_level <> 'PUBLIC_INTAKE'`, and
--   backfilled = false was treated as a defect. Live shape:
--
--     isolation_level      contracts  no tenant column  backfilled
--     ENTITY                   2            0               2
--     ENTITY_AND_ORG           5            0               5
--     INTERNAL_ADMIN_READ      4            4               0
--     PUBLIC_INTAKE            3            3               0
--
--   Every contract that HAS a tenant column is backfilled. Every contract
--   flagged as "lacking backfill" has entity_column IS NULL AND org_column IS
--   NULL -- nothing to backfill, so backfilled=false means NOT APPLICABLE, not
--   INCOMPLETE. The check already excluded PUBLIC_INTAKE, which has the
--   identical shape; it just did not exclude INTERNAL_ADMIN_READ.
--
--   True posture: 7 of 7 tenant-scoped contracts complete, zero gaps. A HIGH
--   alarm had masked that for twelve days.
--
--   Scoped behaviourally -- contracts that HAVE a tenant column -- rather than
--   by naming another level to skip, because enumerated exclusions rot as new
--   levels are added. Same correction as WS31-01 in WS50. NOT a weakening: a
--   tenant-scoped contract with policy applied and no backfill still fails HIGH.
--   The not-applicable count is REPORTED in observed and evidence, not dropped.
--
--   Only the WS24-05 block changed. WS24-01..04 reproduced byte-identical apart
--   from two additive evidence notes (WS24-01 'write_dimension' pointing at
--   WS50-01; WS24-04 'direction_note' recording that RLS-on-with-no-policy is
--   deny-all, so upward drift is fail-CLOSED -- a functionality risk, not an
--   exposure). Retrieve the applied text with
--   pg_get_functiondef('public.ws24_definer_regression_check'::regproc).
--
--   The corrected WS24-05 universe, verbatim:
--
--     select count(*),
--            count(*) filter (where not backfilled),
--            coalesce(string_agg(table_name,', ') filter (where not backfilled),'none')
--       into v_pa_total, v_pa_missing, v_pa_tables
--     from public.muon_tenant_contract
--     where policy_applied
--       and (entity_column is not null or org_column is not null);
--
--     select count(*) into v_pa_na
--     from public.muon_tenant_contract
--     where policy_applied
--       and entity_column is null and org_column is null;
--
--   Verified after applying:
--     WS24-01 CONFORM · WS24-03 CONFORM
--     WS24-05 CONFORM/INFO -- "0 of 7 tenant-scoped policy_applied contracts
--             lack backfill; 7 contract(s) have no tenant column and are not
--             applicable"  (was DEVIATION / HIGH)
--     WS24-02 DEVIATION/MEDIUM and WS24-04 DEVIATION/MEDIUM unchanged.
--
-- B · THE WORKING REPOSITORY WAS NOT IN THE REGISTRY
--
--   m2m_repository_registry held 11 rows, none of them drivenbydesign1-tech/M2M-
--   -- the repository holding PR #1 (28 migrations, +3,359) and PR #2 (WS48
--   through WS52). A near-namesake under a DIFFERENT owner, Kali-Dedwen/M2M-,
--   was registered as role=empty / access_status=empty-skip.
--
--   The row below records only what this session verified directly. role is left
--   NULL: the registry contradicts itself about canonical --
--   Kali-Dedwen/m2m-sovereign-stack carries role='canonical' while
--   Kali-Dedwen/drivenbydesign1-tech carries role='application' with notes
--   reading "Canonical; model2message.net". That is NOT resolved here.
-- ============================================================================

-- A · see header; full replacement applied to ws24_definer_regression_check.

-- B · additive registry row, role NULL.
insert into public.m2m_repository_registry
  (repo_full_name, owner, name, role, host, is_private, default_branch,
   push_path, access_status, branch_protection, ci_harness, codeowners,
   secret_scanning, dependabot, notes, last_reviewed)
values
  ('drivenbydesign1-tech/M2M-','drivenbydesign1-tech','M2M-', null,'github', true,'main',
   'Claude Code remote session (verified: pushes land)','push-admin',
   'off','present-and-passing','pending','pending','pending',
   'Registered 2026-08-28 by CC. Absent from the registry while holding PR #1 and PR #2. VERIFIED: default branch main; branch_protection OFF, not pending (both branches report protected=false live); CI harness present and passing; push access works. NOT VERIFIED, left pending: secret_scanning, dependabot, codeowners. role LEFT NULL DELIBERATELY -- canonical designation is a Founder act and the registry currently contradicts itself.',
   current_date)
on conflict (repo_full_name) do nothing;

-- Ledger row inserted at apply time (Pending).
