-- ============================================================================
-- WS50 · Close anon DML on an owner-executing view over FL/II provenance,
--        and correct WS31-01 from substring matching to behaviour.
--
-- Full reasoning, evidence and rollback:
--   docs/CHANGE-2026-08-28-flii-view-write-exposure.md
--
-- CORRECTION OF RECORD. I reported -- in the WS49 migration, in WS49-01's
-- evidence, in PR #2 and in SEL-20260828-A2018879 which the Founder has already
-- AUTHENTICATED -- that WS24-01's scan scope was too narrow for anon-reachable
-- SECURITY DEFINER functions. Wrong. WS24-01 measures owner-executing VIEWS;
-- the function check is WS24-03. WS24-01 was never defective, and its "1
-- anon-reachable" was a true finding. Consequently WS49 did NOT close WS24-03:
-- it went from five unexpected entries to one, that one being
-- fn_canonical_last_write -- the provisional acceptance I created.
--
-- THE FINDING WS24-01 POINTED AT. public.v_flii_provenance_review is an
-- owner-executing, auto-updatable view over loop_executions projecting
-- fl_ii_authenticated_by AS claimed_actor, granted arwdDxtm to BOTH anon and
-- authenticated. Owner-executing views run base-table permission and RLS checks
-- as the VIEW OWNER, so the service_role-only RLS policy on loop_executions did
-- not contain writes routed through it. An anon key holder could have rewritten
-- who is recorded as having authenticated a sovereign task, or deleted the
-- provenance rows under review -- the WS48 defect class, reachable anonymously.
-- Not demonstrated by execution: writing through the view would have forged the
-- exact record this protects.
--
-- The Founder decision of 2026-08-14 accepted AUTHENTICATED READ on these views.
-- It did not cover DML. SELECT is preserved for authenticated; anon holds nothing.
--
-- WS31-01 was reporting 8 false positives: its universe matched any function
-- MENTIONING fl_ii_authenticated, counting readers as writers. Exactly one
-- function assigns the columns -- fn_fl_ii_close_loop, an AFTER trigger that
-- reacts to an already-vetted transition on a table whose BEFORE trigger
-- fn_flii_machine_redirect redirects machine writes to machine_verified first.
-- Corrected to assignment matching. NOT a weakening: an ungated, unredirected
-- assigner still fails at BLOCKING. It had sat at BLOCKING since 2026-08-19.
--
-- NOT DONE: no G6, no migration 369, no FL/II cutover, no root key, no authority
-- transfer, no authentication. WS24-01 and WS24-03 deliberately NOT rewritten --
-- they measure correctly; my claim about them was the defect.
-- ============================================================================

-- 1 · Close the write path.
revoke all on public.v_flii_provenance_review from anon;
revoke all on public.v_flii_provenance_review from authenticated;
grant select on public.v_flii_provenance_review to authenticated;

-- 2 · WS50-01 · owner-executing views carrying write privileges.
--     WS24-01 tests SELECT reachability only, which is why this was invisible.
create or replace function public.ws50_view_write_exposure_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_total int; v_anon_w int; v_auth_w int;
  v_anon_names text[]; v_auth_names text[];
  v_verdict text; v_severity text; v_observed text;
begin
  select count(*),
         count(*) filter (where has_table_privilege('anon', c.oid,'INSERT')
                             or has_table_privilege('anon', c.oid,'UPDATE')
                             or has_table_privilege('anon', c.oid,'DELETE')),
         coalesce(array_agg(c.relname order by c.relname)
           filter (where has_table_privilege('anon', c.oid,'INSERT')
                      or has_table_privilege('anon', c.oid,'UPDATE')
                      or has_table_privilege('anon', c.oid,'DELETE')), '{}'),
         count(*) filter (where has_table_privilege('authenticated', c.oid,'INSERT')
                             or has_table_privilege('authenticated', c.oid,'UPDATE')
                             or has_table_privilege('authenticated', c.oid,'DELETE')),
         coalesce(array_agg(c.relname order by c.relname)
           filter (where has_table_privilege('authenticated', c.oid,'INSERT')
                      or has_table_privilege('authenticated', c.oid,'UPDATE')
                      or has_table_privilege('authenticated', c.oid,'DELETE')), '{}')
    into v_total, v_anon_w, v_anon_names, v_auth_w, v_auth_names
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v'
    and coalesce((select option_value from pg_options_to_table(c.reloptions)
                  where option_name='security_invoker'),'false') not in ('on','true');

  v_observed :=
    v_total || ' owner-executing view(s); '
    || v_anon_w || ' writable by anon'
    || case when v_anon_w > 0 then ' (' || array_to_string(v_anon_names, ', ') || ')' else '' end
    || '; ' || v_auth_w || ' writable by authenticated'
    || case when v_auth_w > 0 then ' (' || array_to_string(v_auth_names, ', ') || ')' else '' end;

  v_verdict  := case when v_anon_w = 0 and v_auth_w = 0 then 'CONFORM' else 'DEVIATION' end;
  v_severity := case when v_anon_w > 0 then 'BLOCKING'
                     when v_auth_w > 0 then 'HIGH' else 'INFO' end;

  insert into m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  values (p_run_id, 'platform', 'WS50-01',
    'Does any owner-executing view carry INSERT, UPDATE or DELETE for anon or authenticated?',
    '0 writable by anon and 0 by authenticated; read access is governed separately by WS24-01',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'owner_executing_views', v_total,
      'anon_writable', v_anon_w, 'anon_writable_names', to_jsonb(v_anon_names),
      'authenticated_writable', v_auth_w, 'authenticated_writable_names', to_jsonb(v_auth_names),
      'why','v_flii_provenance_review was an auto-updatable owner-executing view over loop_executions, granted arwdDxtm to both anon and authenticated. Its projection aliases fl_ii_authenticated_by as claimed_actor. Because an owner-executing view runs base-table permission and RLS checks as the view owner, the service_role-only RLS policy on loop_executions did not apply to writes routed through it. An anon key holder could have rewritten who is recorded as having authenticated a sovereign task, or deleted the provenance rows under review.',
      'relationship_to_ws24_01','WS24-01 measures SELECT reachability on the same universe and does so correctly. It has no write dimension, which is why this exposure was invisible to it. WS50-01 adds the write dimension; neither check supersedes the other.',
      'accepted_risk','Founder decision 2026-08-14 retained AUTHENTICATED read access on these views. That decision covered reads. It did not cover DML, and DML on FL/II provenance is not within it. SELECT is preserved for authenticated; write is revoked from both roles.',
      'not_demonstrated','Writing through the view to prove the path would have forged exactly the authentication record this check protects. Established statically from pg_class.reloptions, information_schema.views.is_updatable and relacl.',
      'read_from','pg_class(relkind=v) x pg_options_to_table(reloptions) x has_table_privilege'),
    jsonb_build_object(
      'universe','public views that are owner-executing (security_invoker not on/true)',
      'universe_count', v_total, 'examined_count', v_total, 'method','FULL',
      'source','pg_class x pg_namespace x pg_options_to_table x has_table_privilege',
      'excluded','none'),
    (v_verdict <> 'CONFORM'));
end;
$function$;

revoke all on function public.ws50_view_write_exposure_check(uuid) from public, anon, authenticated;
grant execute on function public.ws50_view_write_exposure_check(uuid) to service_role;

-- 3 · WS31-01 · from "mentions the column" to "assigns the column".
--     The replacement body and the corrected ws49_anon_definer_surface_check
--     body are applied as migration 20260828112312 and are reproducible with
--     pg_get_functiondef(); see the change record for the full text and the
--     rollback path back to the 20260828103722 versions.

create or replace function public.ws31_flii_guard_bypass_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_universe int; v_mentions int; v_bad int; v_names text[]; v_assigners text[];
  c_instruments constant text[] := array[
    'ws31_flii_guard_bypass_check','ws32_ledger_immutability_check',
    'ws33_flii_single_writer_check','ws26_flii_self_auth_check',
    'fn_flii_machine_redirect','authenticate_sovereign_task'];
  c_assign constant text := 'fl_ii_authenticated(_at|_by)?\s*:?=';
begin
  -- Everything that mentions the columns, for context only.
  select count(*) into v_mentions
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and pg_get_functiondef(p.oid) ilike '%fl_ii_authenticated%';

  -- Universe that actually matters: functions that ASSIGN the columns.
  select count(*), coalesce(array_agg(p.proname order by p.proname),'{}')
    into v_universe, v_assigners
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and pg_get_functiondef(p.oid) ~* c_assign;

  -- Of those, the ones neither gated nor covered by the machine redirect.
  select count(*), coalesce(array_agg(p.proname order by p.proname),'{}')
    into v_bad, v_names
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and not (p.proname = any(c_instruments))
    and pg_get_functiondef(p.oid) ~* c_assign
    and pg_get_functiondef(p.oid) not ilike '%assert_founder_session%'
    and pg_get_functiondef(p.oid) not ilike '%machine_verified%'
    -- An AFTER trigger reacting to an already-vetted transition is not an
    -- assertion path: fn_flii_machine_redirect is a BEFORE trigger on the same
    -- table (trg_aa_flii_redirect, named to sort first) and redirects machine
    -- writes to machine_verified before any AFTER trigger observes them.
    and not exists (
      select 1 from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      where t.tgfoid = p.oid and not t.tgisinternal
        and (t.tgtype & 2) = 0
        and exists (select 1 from pg_trigger t2
                    join pg_proc p2 on p2.oid = t2.tgfoid
                    where t2.tgrelid = c.oid and not t2.tgisinternal
                      and (t2.tgtype & 2) = 2
                      and p2.proname = 'fn_flii_machine_redirect'));

  insert into m2m_conformance_audit(
    run_id, audit_scope, check_code, check_question, expected, observed,
    verdict, severity, evidence, requires_authentication, scan_scope)
  values (p_run_id, 'WS-31 FL/II GUARD SURFACE', 'WS31-01',
    'Can any function write fl_ii_authenticated without passing assert_founder_session(), the machine_verified redirect, or a BEFORE redirect on its own table?',
    '0 unguarded writers',
    v_bad || ' unguarded writer(s)'
      || case when v_bad > 0 then ' (' || array_to_string(v_names, ', ') || ')' else '' end
      || '; ' || v_universe || ' function(s) assign the columns ('
      || array_to_string(v_assigners, ', ') || '); '
      || v_mentions || ' merely mention them',
    case when v_bad = 0 then 'CONFORM' else 'DEVIATION' end,
    case when v_bad = 0 then 'INFO' else 'BLOCKING' end,
    jsonb_build_object('count', v_bad, 'unguarded', to_jsonb(v_names),
      'assigning_functions', to_jsonb(v_assigners),
      'mentioning_functions_total', v_mentions,
      'excluded_instruments', to_jsonb(c_instruments),
      'exclusion_rationale','Governance instruments that reference the column to measure or redirect it. Named explicitly so the exclusion is reviewable.',
      'scope_correction','Until 2026-08-28 this check matched any function whose definition MENTIONED fl_ii_authenticated. That counted readers as writers: trgfn_ws7_outcome_required_loop and _ins read it into a smallint metric, ws7_platform_integrity_sentinel reads it in a WHERE predicate, ws41_cycle_integrity_check names it inside detector SQL strings, and m2m_cycle_advance, m2m_cycle_exit_test, process_loop_watcher_signal and ws46_cycle_applier_integrity_check only reference it. Exactly one function assigns the columns. The check therefore sat at BLOCKING from 2026-08-19 on 8 false positives -- and a check that reports a violation forever is one people stop reading. The rule is unchanged in strength: a function that assigns the columns while ungated and unredirected still fails at BLOCKING.',
      'remaining_assigner','fn_fl_ii_close_loop is an AFTER trigger on loop_executions that REACTS to a false->true transition -- it stamps fl_ii_authenticated_at, sets status CLOSED and writes loop_audit_trail. It does not cause the transition. fn_flii_machine_redirect is a BEFORE trigger on the same table (trg_aa_flii_redirect) and redirects machine writes to machine_verified before any AFTER trigger observes them.',
      'distinct_from','WS26 detects the data symptom. WS31 detects the code path. WS33 detects writer coverage. WS50 detects the view write path.'),
    v_bad > 0,
    jsonb_build_object('universe','public functions (prokind=f) that ASSIGN fl_ii_authenticated, _at or _by',
      'universe_count', v_universe, 'examined_count', v_universe,
      'method','FULL','source','pg_proc + pg_get_functiondef, assignment-matched',
      'excluded','governance instruments listed in evidence.excluded_instruments; and AFTER-trigger functions on a table already carrying the fn_flii_machine_redirect BEFORE trigger'));
end $function$;

-- 4 · ws49_anon_definer_surface_check is replaced in this migration ONLY to
--     correct its coverage_note, which was stamping my WS24-01 error into every
--     row it emitted. The corrected text reads, in full:
--
--       "CORRECTED 2026-08-28. An earlier version of this field claimed WS24-01
--        had too narrow a scan scope for anon-reachable SECURITY DEFINER
--        functions. That was wrong and the error was mine. WS24-01 measures
--        owner-executing VIEWS, not functions, and its scope is correct. The
--        check covering anon-executable SECURITY DEFINER functions is WS24-03.
--        WS49 did NOT close WS24-03: it reduced the unexpected set from five to
--        one, and the remaining entry is fn_canonical_last_write, the
--        provisional acceptance recorded above. WS24-03 stays DEVIATION until
--        that grant is revoked or its allowlist is amended."
--
--     Logic, allowlist, verdict and severity rules are otherwise byte-identical
--     to migration 20260828103841. Body omitted here to keep the diff to the
--     change it makes; retrieve the live text with pg_get_functiondef().

-- 5 · Wire WS50-01 into the daily battery (full DO block as applied).
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
end $b$;
$cron$);

-- 6 · Ledger row inserted at apply time (Pending). Full text in the change record.
