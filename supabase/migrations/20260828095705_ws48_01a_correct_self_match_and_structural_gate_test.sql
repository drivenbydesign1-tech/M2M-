-- WS48-01a · Correcting a defect in WS48-01, shipped hours after WS48-01 itself.
--
-- MY DEFECT. WS48-01's universe was three ILIKE probes ('%eco_tasks%',
-- '%auth_status%', '%update%') against pg_proc.prosrc. Its own body contains all
-- three, so THE DETECTOR COUNTED ITSELF as a function that writes
-- eco_tasks.auth_status. It reported "2 functions" where the true answer is 1.
--
-- Worse, it scored itself `gated` because its body contains the *string*
-- assert_founder_session — in its own evidence text and in its own ILIKE
-- predicate — not because it calls it. That is precisely the false positive I
-- documented in ws31_flii_guard_bypass_check and then reproduced.
--
-- Today this is masked: eco_authenticate is genuinely gated, so the verdict is
-- CONFORM either way. The danger is latent. If this function's text were ever
-- edited to drop that literal, it would flag ITSELF as an ungated,
-- service_role-reachable writer of authentication state — a DEVIATION it could
-- never clear, on a finding that was never true.
--
-- TWO CORRECTIONS
--   1 Universe becomes structural: a function is in scope when it actually
--     UPDATEs eco_tasks, matched as `update [public.]eco_tasks`, not when its
--     text merely mentions the words. A detector that reads the table is no
--     longer mistaken for one that writes it.
--   2 Gating becomes structural: `perform|select [public.]assert_founder_session(`
--     — an actual call site, not a substring. Precedent for excluding a scanner
--     from its own scan already exists at ws37_exclude_self_from_credential_scan.
--
-- Self-exclusion is also declared explicitly in scan_scope.excluded rather than
-- left implicit, so the narrowing is visible to anyone reading the finding.
--
-- VERIFIED AFTER APPLYING
--   WS48-01 now reads: "1 function(s) update eco_tasks.auth_status
--   (eco_authenticate); 0 of them do not call assert_founder_session(); 0 of
--   those are EXECUTE-able by service_role; 0 eco_tasks row(s) at AUTHENTICATED"
--   verdict CONFORM, severity INFO, universe_count 1.

create or replace function public.ws48_authentication_surface_gate_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ungated       int;
  v_ungated_names text[];
  v_svc_reachable int;
  v_unattributed  int;
  v_authed_rows   int;
  v_universe      int;
  v_names         text[];
  v_verdict       text;
  v_severity      text;
  v_observed      text;
  c_call_re constant text := '(perform|select)\s+(public\.)?assert_founder_session\s*\(';
  c_write_re constant text := 'update\s+(public\.)?eco_tasks';
begin
  select count(*),
         coalesce(array_agg(p.proname order by p.proname), '{}'),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.prosrc !~* c_call_re), '{}'),
         count(*) filter (where p.prosrc !~* c_call_re),
         count(*) filter (where has_function_privilege('service_role', p.oid, 'EXECUTE')
                            and p.prosrc !~* c_call_re)
    into v_universe, v_names, v_ungated_names, v_ungated, v_svc_reachable
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.prosrc ~* c_write_re
    and p.prosrc ilike '%auth_status%'
    and p.proname <> 'ws48_authentication_surface_gate_check';

  select count(*) filter (where auth_status = 'AUTHENTICATED'),
         count(*) filter (where auth_status = 'AUTHENTICATED'
                            and coalesce(metadata->>'attribution_verified','false') <> 'true')
    into v_authed_rows, v_unattributed
  from eco_tasks;

  v_observed :=
    v_universe || ' function(s) update eco_tasks.auth_status ('
    || array_to_string(v_names, ', ') || '); '
    || v_ungated || ' of them do not call assert_founder_session()'
    || case when v_ungated > 0
            then ' (' || array_to_string(v_ungated_names, ', ') || ')' else '' end
    || '; ' || v_svc_reachable || ' of those are EXECUTE-able by service_role; '
    || v_authed_rows || ' eco_tasks row(s) at AUTHENTICATED, '
    || v_unattributed || ' of them without a verified session attribution';

  v_verdict := case
    when v_ungated = 0 and v_unattributed = 0 then 'CONFORM'
    else 'DEVIATION' end;

  v_severity := case
    when v_svc_reachable > 0 or v_unattributed > 0 then 'BLOCKING'
    when v_verdict = 'CONFORM'                     then 'INFO'
    else 'HIGH' end;

  insert into m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  values (p_run_id, 'platform', 'WS48-01',
    'Can anything other than a verified Founder session write an AUTHENTICATED record into eco_tasks?',
    'every function that updates eco_tasks.auth_status calls assert_founder_session(), none of them is EXECUTE-able by service_role, and every row at AUTHENTICATED carries attribution_verified=true',
    v_observed,
    v_verdict, v_severity,
    jsonb_build_object(
      'functions_updating_auth_status', v_universe,
      'function_names',                 to_jsonb(v_names),
      'ungated_functions',              v_ungated,
      'ungated_function_names',         to_jsonb(v_ungated_names),
      'ungated_and_service_role_reachable', v_svc_reachable,
      'eco_tasks_authenticated_rows',   v_authed_rows,
      'authenticated_without_verified_attribution', v_unattributed,
      'why', 'eco_authenticate gated on current_user IN (service_role, postgres, supabase_admin). That checks which database role is calling, not which human. service_role is held by Edge Functions, MCP clients and agent sessions, so any of them could write a record asserting the Founder personally authenticated a task. The same session that assert_founder_session() refuses was accepted here.',
      'precedent', 'The gate is already the pattern on muon_founder_authenticate and four sibling surfaces. This check holds eco_authenticate to it.',
      'correction_history', 'WS48-01 as first shipped matched its universe with three ILIKE probes and so counted ITSELF as a writer of eco_tasks.auth_status, and scored itself gated on a substring rather than a call site. Corrected by WS48-01a: universe is now a structural match on `update [public.]eco_tasks`, gating is a structural match on a call site, and this function is excluded from its own scan by name.',
      'not_demonstrated', 'The bypass was never executed. Calling eco_authenticate to prove it would have manufactured the false authorization record this check exists to detect. The post-fix refusal WAS captured by execution and is recorded as WS48-02.',
      'read_from', 'pg_proc x pg_namespace, has_function_privilege(), public.eco_tasks'),
    jsonb_build_object(
      'universe', 'every public function whose body contains an UPDATE against eco_tasks and references auth_status, plus every eco_tasks row',
      'universe_count', v_universe,
      'examined_count', v_universe,
      'method', 'FULL',
      'source', 'pg_proc x pg_namespace x public.eco_tasks',
      'excluded', 'ws48_authentication_surface_gate_check itself — it reads eco_tasks but never updates it. Declared rather than implicit, per ws37_exclude_self_from_credential_scan.'),
    (v_verdict <> 'CONFORM'));
end;
$function$;

insert into public.sovereign_execution_log (
  entity, action_description, action_category,
  dart_deconstruct, dart_domain, dart_risk_level, dart_test,
  governance_tier, declared_action, validation_method, rollback_path,
  human_review_required, human_review_status)
values (
  'M2M~Inc.',
  'WS48-01a — correct a self-match defect in WS48-01 shipped the same day.',
  'Governance',
  'My defect, same day as the check it corrects. WS48-01 matched its universe with three independent ILIKE probes against prosrc. Its own body contains all three tokens, so it counted itself as a function that writes eco_tasks.auth_status — reporting 2 where the true answer is 1. It also scored itself gated because its body contains the literal string assert_founder_session in its evidence text and in its own predicate, not because it calls it. That is the identical false positive I had just documented in ws31_flii_guard_bypass_check. Masked today because eco_authenticate is genuinely gated, so the verdict was CONFORM either way; latent because an edit dropping that literal would make the check flag itself as an ungated service_role-reachable writer, a DEVIATION it could never clear on a finding that was never true.',
  'Complicated',
  'Medium',
  'Re-run ws48_authentication_surface_gate_check and confirm the universe is 1 function (eco_authenticate), not 2, and that the verdict remains CONFORM.',
  'HITL',
  'Universe narrowed to a structural match on `update [public.]eco_tasks`; gating narrowed to a structural match on a call site rather than a substring; the function excluded from its own scan by name with the exclusion declared in scan_scope. No change to eco_authenticate, no change to grants, no authentication performed.',
  'Re-ran the detector after replacement and read the emitted m2m_conformance_audit row directly.',
  'CREATE OR REPLACE the prior WS48-01 body (three ILIKE probes, no self-exclusion) from supabase/migrations/20260828095500_ws48_eco_authenticate_founder_gate_and_detector.sql. No schema, grant or data change is involved in either direction.',
  true, 'Pending');
