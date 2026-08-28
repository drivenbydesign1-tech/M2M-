-- WS49-01a · My inconsistency, caught by my own detector on its first run.
--
-- WS49 deliberately PRESERVED anon EXECUTE on fn_canonical_last_write -- it is a
-- STABLE heartbeat returning one timestamp, and I could not identify its consumer,
-- so breaking it was the worse risk. Then I wrote WS49-01 with an allowlist that
-- did not include it. The detector immediately flagged a grant I had just chosen
-- to keep: DEVIATION / HIGH on my own decision, on its first run.
--
-- Resolution is to encode the acceptance, not to widen the verdict rule. The
-- allowlist gains a fourth entry with its rationale AND its weakness stated: its
-- anon reachability was inherited from the PUBLIC grant, never deliberately
-- designed, and no consumer has been identified. Accepted provisionally and
-- printed on every run, so it stays visible rather than disappearing into CONFORM.
--
-- Severity is also split so the check cannot go quiet on the part that matters:
-- an unexpected anon-reachable VOLATILE function is BLOCKING, an unexpected
-- read-only one is HIGH.
--
-- To lock the heartbeat down instead, one line reverses it:
--   revoke execute on function public.fn_canonical_last_write() from anon;
-- and remove it from c_accepted below. That is a Founder call, not mine to make
-- on a surface whose consumer I could not establish.

create or replace function public.ws49_anon_definer_surface_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c_accepted constant text[] := array[
    'submit_whistleblower_report','whistleblower_report_status',
    'roi_result_by_token','fn_canonical_last_write'];
  v_total int; v_accepted int; v_unexpected int; v_writers int;
  v_names text[]; v_writer_names text[]; v_accepted_live text[];
  v_verdict text; v_severity text; v_observed text;
begin
  select count(*),
         count(*) filter (where p.proname = any(c_accepted)),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.proname = any(c_accepted)), '{}'),
         count(*) filter (where p.proname <> all(c_accepted)),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.proname <> all(c_accepted)), '{}'),
         count(*) filter (where p.proname <> all(c_accepted) and p.provolatile = 'v'),
         coalesce(array_agg(p.proname order by p.proname)
                  filter (where p.proname <> all(c_accepted) and p.provolatile = 'v'), '{}')
    into v_total, v_accepted, v_accepted_live, v_unexpected, v_names, v_writers, v_writer_names
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.prorettype <> 'trigger'::regtype
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and p.proname <> 'ws49_anon_definer_surface_check';

  v_observed :=
    v_total || ' SECURITY DEFINER function(s) anon-EXECUTE-able; '
    || v_accepted || ' accepted by design (' || array_to_string(v_accepted_live, ', ') || '); '
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
    'Is any SECURITY DEFINER function anon-EXECUTE-able other than the surfaces accepted as anon-reachable by design?',
    'exactly the four accepted surfaces and nothing else; and in particular nothing unexpected that is VOLATILE and so able to write',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'anon_executable_secdef_total', v_total,
      'accepted_by_design', to_jsonb(c_accepted),
      'accepted_present',   to_jsonb(v_accepted_live),
      'accepted_count',     v_accepted,
      'unexpected_count',   v_unexpected,
      'unexpected_names',   to_jsonb(v_names),
      'unexpected_and_writable',   v_writers,
      'unexpected_writable_names', to_jsonb(v_writer_names),
      'why', 'Eight of the original nine carried the PUBLIC grant (=X/postgres in proacl), which Supabase resolves to anon and authenticated. Nobody granted anon anything -- it was inherited at CREATE FUNCTION time and is invisible in the function source. ws31, ws32 and ws33 are VOLATILE and INSERT into m2m_conformance_audit as owner, so an anon key holder could inject conformance findings. Evidence integrity, open at BLOCKING under WS24-03 since 2026-08-19, closed by WS49.',
      'acceptance_rationale', 'submit_whistleblower_report and whistleblower_report_status are the confidential reporting channel -- an anonymous reporter must be able to file and to check status. roi_result_by_token is a token-gated result read. All three are deliberate.',
      'provisional_acceptance', 'fn_canonical_last_write is accepted PROVISIONALLY and is the weakest entry on this list. It is STABLE and returns a single greatest(max(...)) timestamp, so it cannot write; but its anon reachability was INHERITED from the PUBLIC grant, never deliberately designed, and no consumer has been identified. It leaks only a last-activity timestamp. Kept because breaking an unidentified consumer was judged the worse risk. To lock it down: revoke execute on function public.fn_canonical_last_write() from anon, and drop it from this allowlist. Founder call.',
      'corrections', 'Two functions were wrongly named as conformance writers in an earlier report of mine. fn_canonical_last_write is STABLE and only READS the audit table. fn_flii_machine_redirect is a trigger function, never exposed over PostgREST and unaffected by EXECUTE grants. Both errors came from matching prosrc substrings rather than testing behaviour -- this check tests provolatile and prorettype instead. A third instance of the same class: WS49-01 as first shipped omitted fn_canonical_last_write from its own allowlist and so flagged a grant WS49 had just deliberately preserved.',
      'coverage_note', 'WS24-01 reports 1 anon-reachable SECURITY DEFINER function where three independent counts found 9. Its declared scan scope is too narrow. WS49-01 provides the true coverage; WS24-01 is reported, not rewritten.',
      'read_from', 'pg_proc x pg_namespace, has_function_privilege(), provolatile, prorettype'),
    jsonb_build_object(
      'universe','every SECURITY DEFINER function in schema public that does not return trigger',
      'universe_count', v_total, 'examined_count', v_total, 'method','FULL',
      'source','pg_proc x pg_namespace',
      'excluded','ws49_anon_definer_surface_check itself (per ws37_exclude_self_from_credential_scan); and trigger-returning functions, which PostgREST does not expose and whose firing ignores EXECUTE grants'),
    (v_verdict <> 'CONFORM'));
end;
$function$;

-- Ledger row inserted at apply time (Pending).
