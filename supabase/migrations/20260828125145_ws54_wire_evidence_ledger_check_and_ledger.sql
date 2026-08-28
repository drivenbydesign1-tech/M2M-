-- WS54 (part 2) · Wire WS54-01 into the daily battery; ledger the change.
-- Full DO block as applied, plus the SEL row (Pending). See
-- docs/CHANGE-2026-08-28-evidence-ledger-series-001.md for the full record.

select cron.schedule('ws10_conformance_daily','0 13 * * *', $cron$
do $b$ declare v uuid := gen_random_uuid();
begin
  perform public.bp004_run_conformance_battery(v);
  perform public.ws31_flii_guard_bypass_check(v);
  perform public.ws32_ledger_immutability_check(v);
  perform public.ws33_flii_single_writer_check(v);
  perform public.ws34_render_inventory_check(v);
  perform public.ws35_secret_transit_check(v);
  perform public.ws36_competitor_disposition_check(v);
  perform public.ws37_embedded_credential_check(v);
  perform public.ws38_deliverable_auth_backlog_check(v);
  perform public.ws39_supersession_integrity_check(v);
  perform public.ws40_citation_integrity_check(v);
  perform public.ws41_cycle_integrity_check(v);
  perform public.ws42_registry_reality_check(v);
  perform public.ws43_cycle_gate_reachability_check(v);
  perform public.ws44_gate_verdict_provenance_check(v);
  perform public.ws45_sweep_harness_liveness_check(v);
  perform public.ws46_cycle_applier_integrity_check(v);
  perform public.ws48_authentication_surface_gate_check(v);
  perform public.ws49_anon_definer_surface_check(v);
  perform public.ws50_view_write_exposure_check(v);
  perform public.ws54_evidence_ledger_integrity_check(v);
end $b$;
$cron$);

-- Ledger row SEL-20260828-0F15B881 inserted at apply time (Pending).
