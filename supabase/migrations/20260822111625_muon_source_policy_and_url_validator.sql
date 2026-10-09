-- Semantic packet, item 1: controlled source-fetch with SSRF protections.
-- This migration is the POLICY layer only. It performs no network access.
--
-- NOTE ON FIDELITY: as applied, this migration also created the first version of
-- muon_validate_source_url. That version appended bare string literals to a text[]
-- and raised 22P02 instead of returning a refusal verdict; it was replaced 60
-- seconds later by 20260822111725. The corrected definition lives there and is
-- omitted here so the two files do not disagree. Replaying both in order produces
-- the live state exactly.
--
-- Policy stance: deny by default. https only, port 443 only, no IP literals,
-- no userinfo, no internal hostnames, and the registered domain must carry an
-- ALLOW rule. DENY beats ALLOW.

create table if not exists public.muon_source_policy (
  policy_id     bigint generated always as identity primary key,
  host_suffix   text not null,
  disposition   text not null check (disposition in ('ALLOW','DENY')),
  active        boolean not null default true,
  rationale     text not null,
  sel_record_id text,
  added_by      text not null default 'unattributed',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (host_suffix, disposition)
);

comment on table public.muon_source_policy is
  'Host policy for controlled source fetching. Deny by default: a host with no ALLOW rule is refused. DENY rules override ALLOW. Adding an ALLOW rule widens what the platform will reach over the network and is a Founder decision.';

alter table public.muon_source_policy enable row level security;

do $$ begin
  if not exists (select 1 from pg_policy where polrelid='public.muon_source_policy'::regclass and polname='muon_source_policy_read') then
    create policy muon_source_policy_read on public.muon_source_policy for select to authenticated using (true);
  end if;
end $$;

-- Seed. ALLOW entries are the registered domains already cited by rows in
-- muon_evidence — hosts the platform has already relied upon, not a speculative
-- list. DENY entries are belt-and-braces against the cloud metadata namespaces.
insert into public.muon_source_policy (host_suffix, disposition, rationale, sel_record_id, added_by)
values
 ('bcg.com','ALLOW','Cited by EVD-BCG-102070-2026 and EVD-BCG-WORKFORCE-2026','SEL-20260822-113D8031','claude-code-agent'),
 ('imda.gov.sg','ALLOW','Cited by EVD-IMDA-MGF-AGENTIC-V15','SEL-20260822-113D8031','claude-code-agent'),
 ('mddi.gov.sg','ALLOW','Cited by EVD-IMDA-MGF-AGENTIC-V10','SEL-20260822-113D8031','claude-code-agent'),
 ('kornferry.com','ALLOW','Cited by EVD-KORNFERRY-AIREADY-2026','SEL-20260822-113D8031','claude-code-agent'),
 ('protiviti.com','ALLOW','Cited by EVD-PROTIVITI-AIPULSE5-2026','SEL-20260822-113D8031','claude-code-agent'),
 ('workday.com','ALLOW','Cited by EVD-WDAY-SANA-CLOSE-2025 and EVD-WDAY-SANA-GA-2026','SEL-20260822-113D8031','claude-code-agent'),
 ('reworked.co','ALLOW','Cited by EVD-WDAY-SANA-REGSOV-2026','SEL-20260822-113D8031','claude-code-agent'),
 ('weforum.org','ALLOW','Cited by EVD-WEF-FOJ-2025','SEL-20260822-113D8031','claude-code-agent'),
 ('drive.google.com','ALLOW','Cited by EVD-NCHUB-4024802 and EVD-SAF-MSA-V2. Narrow host, not google.com.','SEL-20260822-113D8031','claude-code-agent'),
 ('metadata.google.internal','DENY','Cloud instance metadata. Never fetchable.','SEL-20260822-113D8031','claude-code-agent'),
 ('instance-data','DENY','Cloud instance metadata alias. Never fetchable.','SEL-20260822-113D8031','claude-code-agent'),
 ('supabase.co','DENY','Platform control plane. A source fetch must never reach the platform hosting it.','SEL-20260822-113D8031','claude-code-agent'),
 ('supabase.in','DENY','Platform control plane.','SEL-20260822-113D8031','claude-code-agent')
on conflict (host_suffix, disposition) do nothing;
