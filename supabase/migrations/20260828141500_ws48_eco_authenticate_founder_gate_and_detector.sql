-- ============================================================================
-- WS48 · Close the last unguarded Founder-authentication write path
--
-- CONDITION
--   public.eco_authenticate(uuid, text, text) writes
--       eco_tasks.auth_status = 'AUTHENTICATED'
--   and inserts a child task whose metadata carries actor 'Kevin A. Smith'.
--   Its only authority check is:
--       IF current_user NOT IN ('service_role','postgres','supabase_admin')
--   That is a *containment* check. It verifies which database role is calling,
--   not which human. service_role is what Edge Functions, MCP clients,
--   automation and agent sessions hold. Any of them can therefore write a
--   record asserting that the Founder personally authenticated a task.
--
--   Verified live 2026-08-28 against project jnmywpfdykuybrxkdcmc:
--     - eco_authenticate  prosecdef = false, prosrc has no assert_founder_session
--     - proacl            postgres=X, service_role=X   (no `authenticated` grant)
--     - this review session: current_user = 'postgres', auth.uid() = NULL
--       -> ACCEPTED by eco_authenticate's containment check
--       -> REFUSED  by assert_founder_session() ("no user session")
--   The same caller passes one gate and fails the other. The Founder's own
--   PostgREST session (current_user = 'authenticated') is rejected outright
--   and holds no EXECUTE grant, so the only human who may authenticate is the
--   one caller currently locked out.
--
--   The bypass was NOT demonstrated by execution. Calling eco_authenticate to
--   prove it would have manufactured exactly the false authorization record
--   this migration exists to prevent. Static evidence is conclusive without it.
--
-- PRECEDENT — the lock already exists; this conforms to it, it does not invent
--   assert_founder_session() is live and is already used by five sibling
--   surfaces, every one SECURITY DEFINER + granted to `authenticated` only:
--     muon_founder_authenticate, muon_founder_authenticate_deliverable,
--     muon_ratify_binding, muon_score_refusal, authenticate_sovereign_task
--   eco_authenticate is the lone outlier on every axis. This is a second write
--   path around an existing control, not a missing control.
--
-- PRIOR RECORD
--   SEL-20260827-AF9B1D84 recorded this finding and recommended exactly
--   (a) assert_founder_session() in eco_authenticate and (b) a WS-series
--   detector for auth_status transitions to AUTHENTICATED. Both are held
--   Pending. This migration executes that held recommendation.
--
-- ORDER (reversible; each step independently revertible)
--   1  detector, additive and inert — reports the CURRENT state as BLOCKING
--   2  gate the function body
--   3  move the EXECUTE grant to the caller who can actually satisfy the gate
--   4  wire the detector into ws10_conformance_daily
--   5  ledger, Pending
--
-- NOT DONE HERE, DELIBERATELY
--   No G6 declaration. No migration 369. No FL/II authority cutover. No root
--   key. No production authority transfer. No authentication performed.
--   The 9 anon-executable SECURITY DEFINER functions are a separate scope.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1 · Detector, shipped BEFORE the fix so the condition is visible either way
-- ---------------------------------------------------------------------------
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
  v_verdict       text;
  v_severity      text;
  v_observed      text;
begin
  -- Universe: every public function that writes eco_tasks.auth_status.
  select count(*),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.prosrc not ilike '%assert_founder_session%'), '{}'),
         count(*) filter (where p.prosrc not ilike '%assert_founder_session%'),
         count(*) filter (where has_function_privilege('service_role', p.oid, 'EXECUTE')
                            and p.prosrc not ilike '%assert_founder_session%')
    into v_universe, v_ungated_names, v_ungated, v_svc_reachable
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.prosrc ilike '%eco_tasks%'
    and p.prosrc ilike '%auth_status%'
    and p.prosrc ilike '%update%';

  -- Row-level: an AUTHENTICATED row whose record carries no verified session.
  select count(*) filter (where auth_status = 'AUTHENTICATED'),
         count(*) filter (where auth_status = 'AUTHENTICATED'
                            and coalesce(metadata->>'attribution_verified','false') <> 'true')
    into v_authed_rows, v_unattributed
  from eco_tasks;

  v_observed :=
    v_universe || ' function(s) write eco_tasks.auth_status; '
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
    'every function that writes eco_tasks.auth_status calls assert_founder_session(), none of them is EXECUTE-able by service_role, and every row at AUTHENTICATED carries attribution_verified=true',
    v_observed,
    v_verdict, v_severity,
    jsonb_build_object(
      'functions_writing_auth_status', v_universe,
      'ungated_functions',             v_ungated,
      'ungated_function_names',        to_jsonb(v_ungated_names),
      'ungated_and_service_role_reachable', v_svc_reachable,
      'eco_tasks_authenticated_rows',  v_authed_rows,
      'authenticated_without_verified_attribution', v_unattributed,
      'why', 'eco_authenticate gated on current_user IN (service_role, postgres, supabase_admin). That checks which database role is calling, not which human. service_role is held by Edge Functions, MCP clients and agent sessions, so any of them could write a record asserting the Founder personally authenticated a task. The same session that assert_founder_session() refuses was accepted here.',
      'precedent', 'assert_founder_session() is already the gate on muon_founder_authenticate, muon_founder_authenticate_deliverable, muon_ratify_binding, muon_score_refusal and authenticate_sovereign_task. This check holds eco_authenticate to the pattern its five siblings already follow.',
      'prior_record', 'SEL-20260827-AF9B1D84 recommended this detector and left it Held.',
      'not_demonstrated', 'The bypass was never executed. Calling eco_authenticate to prove it would have manufactured the false authorization record this check exists to detect.',
      'read_from', 'pg_proc x pg_namespace, has_function_privilege(), public.eco_tasks'),
    jsonb_build_object(
      'universe', 'every public function whose body updates eco_tasks.auth_status, plus every eco_tasks row',
      'universe_count', v_universe,
      'examined_count', v_universe,
      'method', 'FULL',
      'source', 'pg_proc x pg_namespace x public.eco_tasks',
      'excluded', 'none'),
    (v_verdict <> 'CONFORM'));
end;
$function$;

revoke all on function public.ws48_authentication_surface_gate_check(uuid) from public, anon, authenticated;
grant execute on function public.ws48_authentication_surface_gate_check(uuid) to service_role;

comment on function public.ws48_authentication_surface_gate_check(uuid) is
  'WS48-01. Detects any write path that can set eco_tasks.auth_status = AUTHENTICATED without a verified Founder session. Reaches CONFORM once every such function is gated and every AUTHENTICATED row carries verified attribution.';


-- ---------------------------------------------------------------------------
-- 2 · Gate the function body
--
--     The role-containment check added by 20260824005933
--     (authcontain_tier3_interim_hardening) was explicitly interim. It is
--     superseded here, not merely supplemented: keeping it would reject the
--     Founder's own session (current_user = 'authenticated') and so make the
--     function unreachable by the only caller permitted to satisfy the gate.
--
--     Body shape follows public.muon_founder_authenticate verbatim: gate first,
--     validate decision, canonical actor literal for fn_sel_audit_guard's
--     vocabulary, and the real auth.uid() recorded alongside it as evidence.
-- ---------------------------------------------------------------------------
create or replace function public.eco_authenticate(
  p_task_id  uuid,
  p_decision text,
  p_notes    text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_task      eco_tasks%rowtype;
  v_claude    uuid;
  v_auth_task uuid;
  v_actor     text;
  v_uid       uuid;
begin
  -- Gate first. Raises for service_role, MCP, agent connections and the SQL editor.
  perform public.assert_founder_session();

  if upper(p_decision) not in ('AUTHENTICATED','REJECTED') then
    raise exception 'ECO: decision must be AUTHENTICATED or REJECTED (got %)', p_decision;
  end if;

  select * into v_task from eco_tasks where task_id = p_task_id;
  if not found then
    raise exception 'ECO: task % not found', p_task_id;
  end if;

  -- Session already verified as the Founder above. The canonical literal is what
  -- fn_sel_audit_guard accepts; the real session uid is recorded next to it so the
  -- record carries its own proof rather than a name typed by whoever called.
  v_actor := 'Kevin A. Smith';
  v_uid   := auth.uid();

  update eco_tasks
     set auth_status = upper(p_decision),
         metadata = metadata || jsonb_build_object(
           'auth_notes',            coalesce(p_notes,''),
           'auth_at',               now(),
           'executed_by_role',      current_user,
           'session_uid',           v_uid,
           'attribution_verified',  true)
   where task_id = p_task_id;

  select model_id into v_claude from eco_models where model_code = 'claude';

  insert into eco_tasks (
    ecosystem_id, model_id, parent_task_id, task_type, task_description,
    gate_status, auth_status, fl_ii_class, completed_at, metadata)
  values (
    v_task.ecosystem_id, v_claude, p_task_id, 'authentication',
    'Founder authentication: ' || upper(p_decision) || ' — task ' || p_task_id,
    'UNGATED', 'NOT_REQUIRED', 'AUTHENTICATE', now(),
    jsonb_build_object(
      'actor',                v_actor,
      'decision',             upper(p_decision),
      'executed_by_role',     current_user,
      'session_uid',          v_uid,
      'attribution_verified', true))
  returning task_id into v_auth_task;

  return jsonb_build_object(
    'task_id',            p_task_id,
    'auth_status',        upper(p_decision),
    'auth_event_task_id', v_auth_task,
    'authenticated_by',   v_actor,
    'session_uid',        v_uid);
end;
$function$;

comment on function public.eco_authenticate(uuid, text, text) is
  'Founder-gated. Calls assert_founder_session() before any write, matching muon_founder_authenticate. Supersedes the interim role-containment check from 20260824005933, which verified the calling database role rather than the human.';

-- ---------------------------------------------------------------------------
-- 3 · Move the EXECUTE grant to the caller who can satisfy the gate
--
--     service_role loses it: assert_founder_session() would refuse it anyway,
--     so the grant only advertised a door that no longer opens.
--     authenticated gains it: that is the Founder's PostgREST session role,
--     and the gate narrows it to one uid. Same shape as the five siblings.
--
--     Safe to revoke: eco_tasks holds 1 row, at NOT_REQUIRED. No authentication
--     has ever succeeded through this path, so there is no live caller to break.
-- ---------------------------------------------------------------------------
revoke all on function public.eco_authenticate(uuid, text, text)
  from public, anon, service_role;
grant execute on function public.eco_authenticate(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4 · Wire WS48-01 into the existing daily battery (no new schedule)
-- ---------------------------------------------------------------------------
select cron.schedule(
  'ws10_conformance_daily',
  '0 13 * * *',
  $cron$
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
end $b$;
  $cron$
);

-- ---------------------------------------------------------------------------
-- 5 · Ledger. Pending. Authentication is not mine to perform.
-- ---------------------------------------------------------------------------
insert into public.sovereign_execution_log (
  entity, action_description, action_category,
  dart_deconstruct, dart_domain, dart_risk_level, dart_test,
  governance_tier, declared_action, validation_method, rollback_path,
  human_review_required, human_review_status)
values (
  'M2M~Inc.',
  'WS48 — gate public.eco_authenticate behind assert_founder_session(), move its EXECUTE grant from service_role to authenticated, and ship WS48-01 to detect recurrence.',
  'Governance',
  'eco_authenticate guarded authorization state with current_user IN (service_role, postgres, supabase_admin) — a containment check on the calling database role, not on the human. service_role is held by Edge Functions, MCP clients and agent sessions, any of which could therefore write eco_tasks.auth_status = AUTHENTICATED and a child record naming the Founder as actor. Proved by contradiction on a live session: current_user = postgres with auth.uid() = NULL was ACCEPTED by eco_authenticate and REFUSED by assert_founder_session(). The Founder''s own session (current_user = authenticated) was rejected by the containment check and held no EXECUTE grant, so the one caller who should authenticate was the one caller locked out. Not a missing control: assert_founder_session() already gates five sibling surfaces. eco_authenticate was a second write path around it.',
  'Complicated',
  'High',
  'Re-run ws48_authentication_surface_gate_check: expect CONFORM (0 ungated writers, 0 service_role-reachable ungated writers, 0 AUTHENTICATED rows without verified attribution). Then confirm assert_founder_session() refuses a service_role session against eco_authenticate, and that a Founder PostgREST session reaches it.',
  'HITL',
  'Function gated and grants moved. WS48-01 created and wired into ws10_conformance_daily. NO authentication performed, NO eco_tasks row written, NO G6 declaration, NO migration 369, NO FL/II cutover, NO root-key activation, NO production authority transfer. The bypass was deliberately NOT demonstrated by execution — calling eco_authenticate to prove it would have manufactured the exact false authorization record this change prevents.',
  'Static verification against live catalogs in project jnmywpfdykuybrxkdcmc: pg_proc.prosrc, pg_proc.proacl, has_function_privilege(), cron.job, and a read-only probe of current_user / auth.uid(). No authentication, no write to eco_tasks or eco_models.',
  'Restore the prior definition and grants:
   (a) CREATE OR REPLACE FUNCTION public.eco_authenticate(uuid,text,text) with SECURITY INVOKER, no SET search_path, the body beginning
       IF current_user NOT IN (''service_role'',''postgres'',''supabase_admin'') THEN RAISE EXCEPTION ''AUTH-CONTAINMENT: unauthorized caller role %'', current_user USING ERRCODE = ''42501''; END IF;
       and metadata built without session_uid / attribution_verified — the exact text is preserved in docs/CHANGE-2026-08-28-eco-authenticate-founder-gate.md;
   (b) REVOKE EXECUTE ... FROM authenticated; GRANT EXECUTE ... TO service_role;
   (c) DROP FUNCTION public.ws48_authentication_surface_gate_check(uuid);
   (d) re-run cron.schedule(''ws10_conformance_daily'', ''0 13 * * *'', ...) with the WS48 line removed.
   eco_tasks holds 1 row at NOT_REQUIRED, so no data migration is involved in either direction.',
  true, 'Pending');

-- Deliberately NOT setting supersedes = 'SEL-20260827-AF9B1D84'. That record is the
-- finding this migration executes, and it is still Pending. Marking it superseded
-- would retire it from the review queue before the Founder had reviewed either row.
-- Both stay open, independently, and the relationship is stated in the text above.
