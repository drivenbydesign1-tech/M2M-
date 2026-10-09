-- Classify new loops at stage 1 (SIGNAL) on insert, so they enter the nine-stage
-- cycle instead of accumulating unclassified where the sweep cannot see them.
--
-- Context: m2m_cycle_sweep_preview_daily was scheduled earlier today but reports
-- eligible_now 1 against unclassified_now 14, because m2m_cycle_sweep selects
-- WHERE cycle_stage IS NOT NULL AND cycle_stage < 9. Roughly two NULL-stage loops
-- arrive per day from cron and none of them are ever visible to the driver.
--
-- Why stage 1 is safe to assert at INSERT, and only at INSERT:
--   Stage 1 SIGNAL's exit test is 'Named requester, objective and material
--   consequence exist', which m2m_cycle_exit_test evaluates as loop_name IS NOT
--   NULL AND trigger_source IS NOT NULL. Both columns are NOT NULL in the table
--   definition, so a row that exists has necessarily satisfied stage 1. The
--   classification is earned by the schema, not assumed.
--
-- Why this is INSERT-only and backfills nothing:
--   The 14 existing NULL-stage rows have already diverged in status -- one CLOSED,
--   five HUMAN_REQUIRED, eight RUNNING. Mapping a finished or human-blocked loop
--   back to 'signal received' would be false, and m2m_cycle_exit_test itself
--   declines that mapping: it returns UNCLASSIFIED with the note that status maps
--   to stages 2 through 6 ambiguously. Those rows are left alone for a Founder
--   decision. At INSERT there is no such ambiguity -- the loop has just arrived.

alter table public.loop_executions alter column cycle_stage set default 1;

comment on column public.loop_executions.cycle_stage is
  'Position in the nine-stage cycle (m2m_cycle_stage). Defaults to 1 (SIGNAL) on insert: loop_name and trigger_source are NOT NULL, so stage 1''s exit test is satisfied by any row that exists. NULL means unclassified and is invisible to m2m_cycle_sweep.';

-- The default covers inserts that omit the column. The trigger additionally covers
-- inserts that pass an explicit NULL, which a default cannot catch. Both are needed
-- because the loop-creating paths are several -- pg_cron, the m2m-loop-webhook Edge
-- Function, and Make scenarios -- and not all are visible from the database.
create or replace function public.trgfn_loop_default_cycle_stage()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
BEGIN
  IF NEW.cycle_stage IS NULL THEN
    NEW.cycle_stage := 1;
  END IF;
  RETURN NEW;
END; $function$;

comment on function public.trgfn_loop_default_cycle_stage() is
  'Backstop for the cycle_stage default: coerces an explicitly-inserted NULL to stage 1 (SIGNAL). Fires BEFORE INSERT only, so it can never reclassify an existing loop.';

drop trigger if exists trg_ab_cycle_stage_default on public.loop_executions;

create trigger trg_ab_cycle_stage_default
  before insert on public.loop_executions
  for each row
  execute function public.trgfn_loop_default_cycle_stage();
