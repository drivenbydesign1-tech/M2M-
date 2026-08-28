-- WS55-01a · My classification error, caught by the rule I shipped an hour earlier.
--
-- WS54-01, with WS55's new refusal-artifact rule, reported on its first run over
-- SERIES-000:
--     DEVIATION / HIGH -- "2 of 6 REFUSAL row(s) cite no artifact"
-- Both were mine, both SERIES-000:
--   seq 61  fn_flii_machine_redirect proved working for the first time in its
--           existence, by a ROLLED-BACK PROBE
--   seq 80  stage 7 tightened to BLOCKED_UNBACKED_VERDICT, refusal OBSERVED
--           before apply was enabled
--
-- Both are genuine refusals and both were verified by execution. But the probes
-- were rolled back, so NO DURABLE ARTIFACT SURVIVES. Their evidentiary weight is
-- testimony -- exactly the weight of a DECLINE -- and marking them CATALOG_READ
-- claimed more than the record supports.
--
-- THE RULE WAS RIGHT AND MY CLASSIFICATION WAS WRONG. Corrected here, not the
-- rule. Three tiers now stated explicitly in the check's evidence:
--   EXECUTION       a typed artifact exists (muon_refusal_ledger row, or a
--                   conformance row written at the time)
--   CATALOG_READ    verified against live catalogs, reproducible
--   ASSERTION_ONLY  no artifact survives -- the declines, and refusals proven
--                   by probes that were rolled back
--
-- This RAISES the disclosed unartifacted count from 10 to 12, which is the true
-- number. Nothing is loosened: an unartifacted refusal claiming verification
-- still fails at HIGH.
--
-- These rows were minutes old and not yet authenticated, so this is correction
-- before the record settles, not rewriting a settled one.
--
-- Verified after applying: WS54-01 CONFORM/INFO -- 49 rows across 2 series
-- [SERIES-000=26, SERIES-001=23], 0 RETEST unlinked, 0 RETEST without a
-- remediation class, 0 of 6 REFUSAL claiming verification without an artifact
-- (2 attested only, disclosed), 12 ASSERTION_ONLY rows disclosed.

update public.m2m_evidence_ledger
   set verified_by = 'ASSERTION_ONLY',
       summary = summary || ' [WS55-01a: reclassified from CATALOG_READ to ASSERTION_ONLY — the probe was rolled back, so no durable artifact survives and this row is testimony, not evidence.]'
 where series = 'SERIES-000' and seq in (61, 80);

-- WS54-01 body replaced in this migration; retrieve the live text with
--   pg_get_functiondef('public.ws54_evidence_ledger_integrity_check'::regproc)
-- Ledger row SEL inserted at apply time (Pending).
