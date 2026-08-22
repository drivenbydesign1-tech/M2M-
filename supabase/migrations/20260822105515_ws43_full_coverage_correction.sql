-- Correction to the WS43-01 detector shipped minutes earlier in this session.
-- The first version declared method FULL while examining only rows with a
-- non-null cycle_stage (191 of 203). BP-004 Rule 1 refused the insert, correctly:
-- a CONFORM cannot rest on partial coverage. The gate caught the author's own
-- overclaim before it ever reached the audit table.
--
-- The fix is to widen the scan rather than narrow the claim: every row in
-- loop_executions is now exercised, including the 12 with a NULL cycle_stage,
-- which return UNCLASSIFIED without reaching the stage 4/5 branch. They are
-- counted in their own bucket rather than excluded from the universe.
create or replace function public.ws43_cycle_gate_reachability_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_universe int; v_examined int := 0;
  v_raised int := 0; v_blocked int := 0; v_evaluated int := 0; v_unclassified int := 0;
  v_errs jsonb := '[]'::jsonb;
  v_link_type text; v_doc_type text; v_type_ok boolean;
  r record; v record;
BEGIN
  SELECT count(*) INTO v_universe FROM loop_executions;

  -- 1. STATIC type-compatibility test. This is the test that would have caught
  --    the 2026-08-22 defect on the day it shipped: uuid vs text, never equal.
  SELECT data_type INTO v_link_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='loop_executions' AND column_name='doc_ref';
  SELECT data_type INTO v_doc_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='m2m_claim_register' AND column_name='doc_id';
  v_type_ok := (v_link_type IS NOT NULL AND v_doc_type IS NOT NULL AND v_link_type = v_doc_type);

  -- 2. DYNAMIC execution test across the full universe.
  FOR r IN SELECT id, cycle_stage FROM loop_executions LOOP
    v_examined := v_examined + 1;
    BEGIN
      SELECT * INTO v FROM m2m_cycle_exit_test(r.id);
      IF v.verdict = 'BLOCKED_NO_DELIVERABLE_LINK' THEN
        v_blocked := v_blocked + 1;
      ELSIF v.verdict = 'UNCLASSIFIED' THEN
        v_unclassified := v_unclassified + 1;
      ELSE
        v_evaluated := v_evaluated + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_raised := v_raised + 1;
      IF jsonb_array_length(v_errs) < 20 THEN
        v_errs := v_errs || jsonb_build_array(jsonb_build_object(
          'loop', r.id, 'stage', r.cycle_stage, 'sqlstate', SQLSTATE, 'error', SQLERRM));
      END IF;
    END;
  END LOOP;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'lifecycle','WS43-01',
    'Can the stage 4/5 claim-and-citation gate actually execute for every loop, and does its linking column share a type with the claim register it must join? (Loops blocked for want of a Founder document binding are accepted per decision 2026-08-22 and excluded from the verdict.)',
    '0 gate executions raising an exception, and loop_executions.doc_ref type-compatible with m2m_claim_register.doc_id',
    v_raised||' of '||v_examined||' gate executions raised; link type '||
      coalesce(v_link_type,'MISSING')||' vs claim type '||coalesce(v_doc_type,'MISSING')||
      '; '||v_blocked||' blocked awaiting Founder binding, '||v_evaluated||' evaluated, '||
      v_unclassified||' unclassified',
    CASE WHEN v_raised = 0 AND v_type_ok THEN 'CONFORM' ELSE 'DEVIATION' END,
    CASE WHEN v_raised > 0 OR NOT v_type_ok THEN 'HIGH' ELSE 'INFO' END,
    jsonb_build_object(
      'raised_count', v_raised,
      'raised_sample', v_errs,
      'blocked_awaiting_founder_binding', v_blocked,
      'evaluated', v_evaluated,
      'unclassified', v_unclassified,
      'link_column_type', v_link_type,
      'claim_register_doc_id_type', v_doc_type,
      'type_compatible', v_type_ok,
      'why','Precedent 2026-08-22: the stage 4/5 gate raised SQLSTATE 42883 comparing text doc_id to uuid deliverable_id. The comparison was unreachable because the column was NULL on all 203 rows, so the defect was invisible to every check that only inspected current data. A gate that cannot execute reads the same as a gate that passes.',
      'author_correction','The first version of this detector declared method FULL while examining only the 191 rows with a non-null cycle_stage. BP-004 Rule 1 refused the insert. The scan was widened to the full universe rather than the claim narrowed.',
      'accepted_risk','Loops blocked for want of a doc_ref are a known gap, not a fault. Binding a loop to a document is a Founder decision; no deterministic rule in the live data supports it. m2m_loop_deliverable_match_preview() reports 0 MATCHED, 0 AMBIGUOUS, 203 UNMATCHED.',
      'accepted_on','2026-08-22'),
    jsonb_build_object('universe','all rows in loop_executions',
      'universe_count', v_universe, 'examined_count', v_examined, 'method','FULL',
      'source','public.loop_executions via public.m2m_cycle_exit_test',
      'excluded','none'),
    (v_raised > 0 OR NOT v_type_ok));
END; $function$;

revoke execute on function public.ws43_cycle_gate_reachability_check(uuid) from anon, public;

-- Wire as the 14th check in the existing daily conformance job.
select cron.alter_job(
  (select jobid from cron.job where jobname = 'ws10_conformance_daily'),
  command := $cmd$
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
end $b$;
$cmd$);
