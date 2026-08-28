-- Stop the watcher recording 96 empty polls a day, without breaking it.
--
-- Finding SEL-20260822-1BD26D3B: loop_watcher_signals held 5,767 rows of which
-- 5,595 carried a NULL loop_id. Confirmed against the Make blueprint for scenario
-- 5403849 (M2M-LOOP-WATCHER, 900s interval): module 1 searches loop_executions for
-- status = 'INITIATED' limit 1, and module 2 writes a CLAIM row unconditionally.
-- A new loop defaults to status INITIATED, so the 11:00 UTC cron loop is claimed on
-- the 11:11 poll and the remaining 95 polls that day find nothing and record it.
--
-- Fixing this in Make would mean editing a live blueprint that does real work daily.
-- The database side is safer and fully reversible: discard the no-op row and keep a
-- per-day tally instead, so the poll's liveness is still observable at one row a day
-- rather than ninety-six. Make continues to receive a success response and needs no
-- change; if the blueprint is later given a proper filter, this trigger simply stops
-- having anything to discard.

create table if not exists public.loop_watcher_poll_tally (
  poll_date    date        primary key,
  empty_polls  integer     not null default 0,
  last_poll_at timestamptz not null default now()
);

comment on table public.loop_watcher_poll_tally is
  'One row per day counting watcher polls that found no INITIATED loop. Replaces 96 NULL-loop_id rows per day in loop_watcher_signals. A day missing from this table with no signals either means the watcher is down or every poll found work.';

alter table public.loop_watcher_poll_tally enable row level security;

do $$ begin
  if not exists (select 1 from pg_policy where polrelid='public.loop_watcher_poll_tally'::regclass
                   and polname='loop_watcher_poll_tally_read') then
    create policy loop_watcher_poll_tally_read on public.loop_watcher_poll_tally
      for select to authenticated using (true);
  end if;
end $$;

create or replace function public.trgfn_loop_watcher_suppress_noop()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
BEGIN
  -- A CLAIM with no loop attached is a poll that found nothing. Count it, drop it.
  IF NEW.loop_id IS NULL THEN
    INSERT INTO loop_watcher_poll_tally (poll_date, empty_polls, last_poll_at)
    VALUES (current_date, 1, now())
    ON CONFLICT (poll_date) DO UPDATE
      SET empty_polls  = loop_watcher_poll_tally.empty_polls + 1,
          last_poll_at = now();
    RETURN NULL;   -- BEFORE INSERT returning NULL discards the row; Make still sees success
  END IF;
  RETURN NEW;
END; $function$;

comment on function public.trgfn_loop_watcher_suppress_noop() is
  'Discards loop_watcher_signals rows with a NULL loop_id and counts them in loop_watcher_poll_tally instead. Signal rows carrying a real loop_id pass through untouched.';

drop trigger if exists trg_watcher_suppress_noop on public.loop_watcher_signals;

create trigger trg_watcher_suppress_noop
  before insert on public.loop_watcher_signals
  for each row
  execute function public.trgfn_loop_watcher_suppress_noop();
