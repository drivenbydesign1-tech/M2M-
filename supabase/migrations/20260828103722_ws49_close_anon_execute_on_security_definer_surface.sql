-- ============================================================================
-- WS49 · Close anon EXECUTE on the SECURITY DEFINER surface, and encode the
--        public surfaces that are anon-reachable by design.
--
-- ROOT CAUSE, and it is not "someone granted anon"
--   Eight of the nine carry `=X/postgres` in proacl -- the PUBLIC grant.
--   Supabase resolves PUBLIC to anon and authenticated. Nobody granted anon
--   anything; the grant was inherited at CREATE FUNCTION time and is invisible
--   in the function source. Only assert_founder_session carried an explicit
--   anon grant. So the fix is REVOKE ... FROM PUBLIC, then re-grant deliberately.
--
-- TWO CORRECTIONS TO MY OWN EARLIER REPORT
--   I told the Founder that FOUR anon-reachable functions write
--   m2m_conformance_audit as owner. Wrong, twice:
--
--   1 fn_canonical_last_write CANNOT write. It is STABLE, and its whole body is
--       select greatest(max(created_at) from sovereign_execution_log,
--                       max(audited_at) from m2m_conformance_audit,
--                       max(created_at) from loop_executions)
--     -- a liveness heartbeat that READS the audit table. My detection was
--     `prosrc ILIKE '%m2m_conformance_audit%'`, which cannot tell a reader from
--     a writer. Same substring error as ws31, and as WS48-01. Third time.
--
--   2 fn_flii_machine_redirect is a TRIGGER function (prorettype = trigger),
--     bound to trg_aa_flii_redirect on loop_executions and judge_verdicts.
--     PostgREST does not expose trigger-returning functions over /rpc, and
--     trigger firing does not consult EXECUTE grants. It was never reachable.
--     Revoked for hygiene only; the triggers are unaffected.
--
--   The true injection set is THREE: ws31, ws32, ws33. All VOLATILE, all
--   INSERT into m2m_conformance_audit as owner, all anon+authenticated
--   EXECUTE-able. An anon key holder could write conformance findings --
--   evidence integrity, open at BLOCKING under WS24-03 since 2026-08-19.
--
-- SAFE TO REVOKE
--   cron.job ws10_conformance_daily runs as username 'postgres', which owns
--   these functions, so the daily battery is unaffected. Nothing else in the
--   schema calls ws31/32/33.
--
-- ACCEPTED, NOT REMOVED
--   submit_whistleblower_report   -- an anonymous reporter must be able to file
--   whistleblower_report_status   -- and to check status by tracking id
--   roi_result_by_token           -- token-gated result retrieval
--   Removing anon here would break the confidential reporting channel. The
--   acceptance is encoded in WS49-01's allowlist and printed in its evidence.
--
-- NOT DONE HERE
--   No G6, no migration 369, no FL/II cutover, no root key, no authority
--   transfer, no authentication. WS24-01's narrow scan scope is reported in the
--   ledger row, not rewritten -- rewriting another detector on the way past is
--   how scope creep enters a security change.
-- ============================================================================

-- 1 · The three real injection vectors: service_role only.
revoke all on function public.ws31_flii_guard_bypass_check(uuid)   from public, anon, authenticated;
revoke all on function public.ws32_ledger_immutability_check(uuid) from public, anon, authenticated;
revoke all on function public.ws33_flii_single_writer_check(uuid)  from public, anon, authenticated;
grant execute on function public.ws31_flii_guard_bypass_check(uuid)   to service_role;
grant execute on function public.ws32_ledger_immutability_check(uuid) to service_role;
grant execute on function public.ws33_flii_single_writer_check(uuid)  to service_role;

-- 2 · Trigger function: never RPC-reachable. Hygiene only; triggers unaffected.
revoke all on function public.fn_flii_machine_redirect() from public, anon, authenticated;

-- 3 · assert_founder_session only ever raises, and leaks no identifier. Drop the
--     anon grant; keep authenticated so a Founder session can probe its own state.
--     SECURITY DEFINER callers run as owner and never needed the caller's grant.
revoke all on function public.assert_founder_session() from public, anon;
grant execute on function public.assert_founder_session() to authenticated, service_role;

-- 4 · STABLE read-only heartbeat. Effective access preserved exactly; the grant
--     is now deliberate instead of inherited. (See WS49-01a for its disposition.)
revoke all on function public.fn_canonical_last_write() from public;
grant execute on function public.fn_canonical_last_write() to anon, authenticated, service_role;

-- 5 · Accepted public surfaces: explicit, not inherited.
revoke all on function public.roi_result_by_token(text) from public;
grant execute on function public.roi_result_by_token(text) to anon, authenticated, service_role;

revoke all on function public.whistleblower_report_status(text) from public;
grant execute on function public.whistleblower_report_status(text) to anon, authenticated, service_role;

revoke all on function public.submit_whistleblower_report(text,text,text,text,text,text,date) from public;
grant execute on function public.submit_whistleblower_report(text,text,text,text,text,text,date)
  to anon, authenticated, service_role;

-- 6 · Detector. NOTE: the allowlist below was incomplete on first ship and was
--     corrected the same hour by WS49-01a -- see that migration. Retained here
--     as the applied history rather than edited in place.
create or replace function public.ws49_anon_definer_surface_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c_accepted constant text[] := array[
    'submit_whistleblower_report','whistleblower_report_status','roi_result_by_token'];
  v_total int; v_accepted int; v_unexpected int; v_writers int;
  v_names text[]; v_writer_names text[];
  v_verdict text; v_severity text; v_observed text;
begin
  select count(*),
         count(*) filter (where p.proname = any(c_accepted)),
         count(*) filter (where p.proname <> all(c_accepted)),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.proname <> all(c_accepted)), '{}'),
         count(*) filter (where p.proname <> all(c_accepted) and p.provolatile = 'v'),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.proname <> all(c_accepted) and p.provolatile = 'v'), '{}')
    into v_total, v_accepted, v_unexpected, v_names, v_writers, v_writer_names
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.prorettype <> 'trigger'::regtype
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and p.proname <> 'ws49_anon_definer_surface_check';

  v_observed :=
    v_total || ' SECURITY DEFINER function(s) anon-EXECUTE-able; '
    || v_accepted || ' accepted by design (' || array_to_string(c_accepted, ', ') || '); '
    || v_unexpected || ' unexpected'
    || case when v_unexpected > 0 then ' (' || array_to_string(v_names, ', ') || ')' else '' end
    || '; ' || v_writers || ' of the unexpected are VOLATILE and so able to write'
    || case when v_writers > 0 then ' (' || array_to_string(v_writer_names, ', ') || ')' else '' end;

  v_verdict  := case when v_unexpected = 0 then 'CONFORM' else 'DEVIATION' end;
  v_severity := case when v_writers > 0 then 'BLOCKING'
                     when v_unexpected > 0 then 'HIGH' else 'INFO' end;

  insert into m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  values (p_run_id, 'platform', 'WS49-01',
    'Is any SECURITY DEFINER function anon-EXECUTE-able other than the three public surfaces that are anon-reachable by design?',
    'exactly the three accepted surfaces and nothing else',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'anon_executable_secdef_total', v_total,
      'accepted_by_design', to_jsonb(c_accepted),
      'unexpected_count', v_unexpected,
      'unexpected_names', to_jsonb(v_names),
      'unexpected_and_writable', v_writers,
      'why', 'Eight of the original nine carried the PUBLIC grant (=X/postgres in proacl), which Supabase resolves to anon and authenticated. ws31, ws32 and ws33 are VOLATILE and INSERT into m2m_conformance_audit as owner, so an anon key holder could inject conformance findings.',
      'corrections', 'fn_canonical_last_write is STABLE and only READS the audit table. fn_flii_machine_redirect is a trigger function, never exposed over PostgREST. Both were wrongly named as writers in an earlier report; this check tests provolatile and prorettype instead of prosrc substrings.',
      'coverage_note', 'WS24-01 reports 1 anon-reachable function where three independent counts found 9. WS49-01 provides the true coverage; WS24-01 is reported, not rewritten.',
      'read_from', 'pg_proc x pg_namespace, has_function_privilege(), provolatile, prorettype'),
    jsonb_build_object(
      'universe','every SECURITY DEFINER function in schema public that does not return trigger',
      'universe_count', v_total, 'examined_count', v_total, 'method','FULL',
      'source','pg_proc x pg_namespace',
      'excluded','ws49_anon_definer_surface_check itself (per ws37_exclude_self_from_credential_scan); and trigger-returning functions'),
    (v_verdict <> 'CONFORM'));
end;
$function$;

revoke all on function public.ws49_anon_definer_surface_check(uuid) from public, anon, authenticated;
grant execute on function public.ws49_anon_definer_surface_check(uuid) to service_role;

comment on function public.ws49_anon_definer_surface_check(uuid) is
  'WS49-01. Anon-EXECUTE-able SECURITY DEFINER surface, judged against a declared allowlist. CONFORM when nothing outside the allowlist is anon-reachable.';

-- 7 · Wire into the existing daily battery. No new schedule.
select cron.schedule('ws10_conformance_daily', '0 13 * * *', $cron$
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
end $b$;
$cron$);

-- 8 · Ledger row inserted at apply time (Pending). See the change record at
--     docs/CHANGE-2026-08-28-anon-definer-surface.md for its full text.
