-- SUPERSEDED IN THE SAME SESSION by 20260822105515_ws43_full_coverage_correction.sql,
-- 66 seconds later. Retained as a record of what was attempted and why it failed.
--
-- This migration created ws43_cycle_gate_reachability_check with a scan that
-- examined only loop_executions rows having a non-null cycle_stage (191 of 203)
-- while declaring method 'FULL'. The function was created successfully, but its
-- first execution was refused at INSERT time by the BP-004 scan-provenance gate:
--
--   ERROR: 23514: BP-004 scan-provenance gate [Rule 1]: verdict CONFORM is not
--   permitted below full coverage (examined 191 of 203). Use UNVERIFIABLE.
--
-- The gate was right: a CONFORM cannot rest on partial coverage. The correction
-- widened the scan to the full universe rather than narrowing the claim.
-- Refusal captured in muon_refusal_ledger as control_ref bp004_scan_provenance_gate.
--
-- Replaying this file is intentionally a no-op: the corrected definition in
-- 20260822105515 uses CREATE OR REPLACE and produces the final state on its own.
do $$ begin
  raise notice 'ws43 initial definition superseded by 20260822105515_ws43_full_coverage_correction';
end $$;
