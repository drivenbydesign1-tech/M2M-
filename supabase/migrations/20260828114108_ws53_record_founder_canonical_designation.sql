-- ============================================================================
-- WS53 · Record the Founder's canonical designation and de-conflict the registry.
--
-- Founder decision, 2026-08-28: Kali-Dedwen/m2m-sovereign-stack is CANONICAL.
--
-- This migration RECORDS a decision the Founder made; it does not make one.
-- The designation was put to him as an explicit binary with the evidence on
-- both sides, and answered. Flagged as a contradiction since 2026-08-26.
--
-- WHAT WAS CONTRADICTORY
--   Kali-Dedwen/m2m-sovereign-stack   role = 'canonical'
--   Kali-Dedwen/drivenbydesign1-tech  role = 'application', but notes opened
--                                     with "Canonical; model2message.net"
--   Two rows claiming the same status, one structured and one free text. The
--   structured column is confirmed correct.
--
-- The superseded claim is NOT deleted -- it is marked superseded in place with
-- its prior text retained verbatim, so the record shows how the system was
-- understood before rather than reading as though it was always right.
--
-- Also recorded: the canonical repository is NOT reachable from this session.
-- Nothing held there has been reviewed, and no claim about it is verifiable
-- from this side. That is the standing prerequisite for the Atlas/CC lane split
-- and for reviewing PRs #5 and #14, which are referenced in
-- SEL-20260827-AF9B1D84 and SEL-20260827-14D65378 but do not exist in the only
-- repository this session can reach.
--
-- SCOPE CLOSED HERE. Per Founder instruction 2026-08-28: current
-- authorization-hardening scope is complete; WS24-02 (4 of 211 functions with a
-- mutable search_path) and WS24-04 (63 of 185 RLS-enabled tables lacking a
-- policy, against a baseline of 57 -- fail-CLOSED, a functionality risk rather
-- than new exposure) are preserved as documented MEDIUM follow-up findings for
-- the next hardening cycle and are deliberately NOT taken. No further
-- production changes under this authorization.
-- ============================================================================

update public.m2m_repository_registry
   set notes = 'CANONICAL — confirmed by Founder decision 2026-08-28. Carried role=canonical since registration; the competing free-text claim on Kali-Dedwen/drivenbydesign1-tech is superseded. NOT REACHABLE from the Claude Code remote session as of 2026-08-28: it must be attached before any review of its contents is possible, and until then any claim about work held there is unverifiable from this side. '
               || coalesce(notes,''),
       last_reviewed = current_date
 where repo_full_name = 'Kali-Dedwen/m2m-sovereign-stack';

update public.m2m_repository_registry
   set notes = 'SUPERSEDED 2026-08-28: the opening "Canonical" claim in the note below is superseded by Founder decision 2026-08-28, which designates Kali-Dedwen/m2m-sovereign-stack as canonical. This repository''s role remains application (model2message.net). Prior note retained verbatim for the record. || '
               || coalesce(notes,''),
       last_reviewed = current_date
 where repo_full_name = 'Kali-Dedwen/drivenbydesign1-tech';

update public.m2m_repository_registry
   set role  = 'working-authorization-hardening',
       notes = 'Role assigned 2026-08-28 after the Founder settled canonical (Kali-Dedwen/m2m-sovereign-stack). This is the working repository for the WS48-WS53 authorization-hardening series, not the stack of record. '
               || coalesce(notes,'')
 where repo_full_name = 'drivenbydesign1-tech/M2M-';

-- Ledger row inserted at apply time (Pending).
