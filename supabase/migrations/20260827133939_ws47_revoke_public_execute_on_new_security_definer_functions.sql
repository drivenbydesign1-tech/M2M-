-- MY DEFECT, SAME DAY. Supabase grants EXECUTE on public schema functions to PUBLIC by
-- default, which in this project resolves to anon and authenticated. Every SECURITY
-- DEFINER function I created inherited that grant, so:
--
--   m2m_cycle_sweep_apply(integer)          SECURITY DEFINER, anon=X  <-- MUTATES loop_executions
--   ws45_sweep_harness_liveness_check(uuid) SECURITY DEFINER, anon=X
--   ws46_cycle_applier_integrity_check(uuid) SECURITY DEFINER, anon=X
--
-- SECURITY DEFINER runs as the owner and bypasses RLS entirely. m2m_cycle_sweep_apply
-- advances loop stages and writes loop_audit_trail, so anyone holding the project's
-- anon key could have driven the cycle machine over PostgREST RPC. Supabase's own
-- advisor flags all three as anon_security_definer_function_executable.
--
-- The convention already existed and I failed to follow it: m2m_cycle_sweep_preview and
-- muon_bind_loop_document both carry acl 'postgres | authenticated | service_role' with
-- no PUBLIC and no anon entry. Someone revoked those deliberately. I did not repeat it.
--
-- Aligning to that convention. The applier is stricter than the detectors because it is
-- the only one of the three that mutates business state: it is called by pg_cron as
-- postgres and needs no client-facing grant at all.
--
-- Ledgered SEL-20260827-28AF3D1B.

revoke execute on function public.m2m_cycle_sweep_apply(integer) from public;
revoke execute on function public.m2m_cycle_sweep_apply(integer) from anon;
revoke execute on function public.m2m_cycle_sweep_apply(integer) from authenticated;

revoke execute on function public.ws45_sweep_harness_liveness_check(uuid) from public;
revoke execute on function public.ws45_sweep_harness_liveness_check(uuid) from anon;

revoke execute on function public.ws46_cycle_applier_integrity_check(uuid) from public;
revoke execute on function public.ws46_cycle_applier_integrity_check(uuid) from anon;

-- Verify, and refuse to leave the migration in a half-applied state.
do $v$
declare v_bad text;
begin
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('m2m_cycle_sweep_apply','ws45_sweep_harness_liveness_check',
                      'ws46_cycle_applier_integrity_check')
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
         OR (p.proname = 'm2m_cycle_sweep_apply'
             AND has_function_privilege('authenticated', p.oid, 'EXECUTE')));
  if v_bad is not null then
    raise exception 'revoke did not take on: %', v_bad;
  end if;
end $v$;
