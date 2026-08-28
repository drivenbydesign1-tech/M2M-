-- Attack corpus for public.muon_validate_source_url.
-- Run against the live database. Expected result: 30 total, 30 passed, FAILED [].
-- A null byte case is deliberately absent: PostgreSQL cannot represent \x00 in
-- text at all, so that vector belongs in the Edge Function tests, not here.
with corpus(url, expect, note) as (values
  ('https://www.bcg.com/capabilities/artificial-intelligence', true,  'allowlisted host'),
  ('https://reports.weforum.org/docs/WEF_Future_of_Jobs_Report_2025.pdf', true, 'subdomain of allowlisted'),
  ('https://drive.google.com/file/d/1kDMiWhUgF15cppiSCV2BPwGwkLnm-WXO/view', true, 'narrow host allow'),
  ('https://bcg.com/', true, 'apex domain'),
  ('https://www.bcg.com:443/x', true, 'explicit 443'),
  ('https://WWW.BCG.COM/X', true, 'uppercase host normalises'),
  ('http://www.bcg.com/x', false, 'http scheme'),
  ('file:///etc/passwd', false, 'file scheme'),
  ('gopher://www.bcg.com/', false, 'gopher scheme'),
  ('javascript:alert(1)', false, 'javascript scheme'),
  ('https://169.254.169.254/latest/meta-data/', false, 'cloud metadata IPv4'),
  ('https://127.0.0.1/', false, 'loopback literal'),
  ('https://10.0.0.5/admin', false, 'RFC1918 literal'),
  ('https://[::1]/', false, 'IPv6 loopback literal'),
  ('https://[fd00::1]/', false, 'IPv6 ULA literal'),
  ('https://2130706433/', false, 'decimal-encoded 127.0.0.1'),
  ('https://0x7f000001/', false, 'hex-encoded 127.0.0.1'),
  ('https://www.bcg.com@evil.test/', false, 'userinfo host confusion'),
  ('https://evil.test/', false, 'not allowlisted'),
  ('https://notbcg.com/', false, 'suffix-match confusion'),
  ('https://bcg.com.evil.test/', false, 'prefix-match confusion'),
  ('https://www.bcg.com:8080/', false, 'non-443 port'),
  ('https://metadata.google.internal/computeMetadata/v1/', false, 'metadata DENY rule'),
  ('https://db.jnmywpfdykuybrxkdcmc.supabase.co/rest/v1/', false, 'platform control plane DENY'),
  ('https://localhost/', false, 'localhost'),
  ('https://intranet.local/', false, 'internal namespace'),
  ('https://www.bcg.com/x' || chr(10) || 'Host: evil.test', false, 'header injection via newline'),
  ('www.bcg.com/x', false, 'no scheme'),
  ('', false, 'empty'),
  (null, false, 'null')
)
select jsonb_pretty(jsonb_build_object(
  'total', count(*),
  'passed', count(*) filter (where ((muon_validate_source_url(url)->>'allowed')::boolean) = expect),
  'FAILED', coalesce(jsonb_agg(jsonb_build_object(
      'url', url, 'note', note, 'expected_allowed', expect,
      'got_allowed', (muon_validate_source_url(url)->>'allowed')::boolean,
      'reasons', muon_validate_source_url(url)->'reasons'))
     filter (where ((muon_validate_source_url(url)->>'allowed')::boolean) <> expect), '[]'::jsonb)
)) from corpus;
