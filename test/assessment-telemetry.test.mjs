/**
 * Regression tests for the assessment app's telemetry layer.
 *
 * These lock in the two defects fixed alongside them:
 *   1. Failures were swallowed into console.warn, so lost writes were invisible.
 *   2. Auto-fired views were written into m2m_switch_assessments, the same table
 *      as real submissions, inflating the apparent submission count.
 *
 * Run: node test/assessment-telemetry.test.mjs
 */
import fs from 'fs';
import vm from 'vm';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT = path.dirname(fileURLToPath(import.meta.url)) + '/..';
const HTML = path.join(ROOT, 'assessment-baseline-2026-08-29.html');

let failures = 0;
const check = (name, cond, detail = '') => {
  if (cond) { console.log(`  PASS  ${name}`); }
  else { failures++; console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); }
};

/** Pull the telemetry functions out of the single inline <script> block. */
function extractTelemetrySource() {
  const html = fs.readFileSync(HTML, 'utf8');
  const block = /<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/.exec(html)[1];
  const lines = block.split(/\r?\n/);
  const at = (pred, from = 0) => {
    const i = lines.findIndex((l, n) => n >= from && pred(l));
    if (i < 0) throw new Error('telemetry source markers not found in ' + HTML);
    return i;
  };
  const a = at(l => l.startsWith('let sbClient=null;'));
  const b = at(l => l.startsWith("}catch(e){ m2mFail('supabase-init',e); }"));
  const c = at(l => l.startsWith('// Telemetry events go to m2m_web_traffic'));
  const d = at(l => l.startsWith('  },1200);'), c);
  return lines.slice(a, b + 1).join('\n') + '\n\n' + lines.slice(c, d + 2).join('\n');
}

/** Minimal browser stubs. `supabaseLoaded:false` simulates the CDN failing. */
function load({ supabaseLoaded = true } = {}) {
  const inserts = [];
  const errors = [];
  const store = {};
  const ctxObj = {
    sessionStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = v; } },
    location: { search: '?utm_source=li&utm_campaign=aug', pathname: '/' },
    document: { referrer: 'https://x.test/' },
    matchMedia: () => ({ matches: false }),
    crypto: { randomUUID: () => 'uuid-fixed' },
    console: { error: (...a) => errors.push(a.join(' ')), log: () => {} },
    URLSearchParams, Object, Promise, Date, String, Math, JSON, clearTimeout, setTimeout,
    SB_URL: 'u', SB_ANON: 'k',
    ctx: 'org',
    supabase: supabaseLoaded ? {
      createClient: () => ({
        from: (table) => ({
          insert: (row) => {
            inserts.push({ table, row });
            return Promise.resolve({ error: row.__forceErr ? { message: 'boom' } : null });
          }
        })
      })
    } : undefined,
  };
  ctxObj.window = ctxObj;
  vm.createContext(ctxObj);
  vm.runInContext(extractTelemetrySource(), ctxObj);
  return { ctx: ctxObj, inserts, errors };
}

console.log('assessment telemetry');

// --- no swallowed failures anywhere in the shipped file ---
{
  const html = fs.readFileSync(HTML, 'utf8');
  const warnCalls = html.match(/console\.warn\s*\(/g) || [];
  check('no console.warn call sites remain', warnCalls.length === 0, `${warnCalls.length} found`);
  check('no bare `if(!sbClient) return;`', !html.includes('if(!sbClient) return;'));
}

// --- views and submissions land in different tables ---
{
  const { ctx, inserts } = load();
  await ctx.sbInsertTraffic('form_view', { outcome: 'ok' });
  check('view event -> m2m_web_traffic', inserts.at(-1).table === 'm2m_web_traffic', inserts.at(-1).table);

  await ctx.sbInsertAssessment({ composite_score: 50, briefing_requested: true });
  const tables = inserts.slice(-2).map(i => i.table);
  check('submission -> m2m_switch_assessments then a traffic event',
    tables[0] === 'm2m_switch_assessments' && tables[1] === 'm2m_web_traffic', JSON.stringify(tables));
}

// --- telemetry rows satisfy the table contract and carry no PII ---
{
  const { ctx } = load();
  const row = ctx.trafficRow('form_view', { outcome: 'ok' });
  check('NOT NULL columns populated', !!row.event_kind && !!row.path);
  check('utm params captured', row.utm_source === 'li' && row.utm_campaign === 'aug');
  const pii = Object.keys(row).filter(k => /email|contact/.test(k) || k === 'name');
  check('row carries no PII', pii.length === 0, pii.join(','));
}

// --- an insert error is recorded three ways, never swallowed ---
{
  const { ctx, inserts, errors } = load();
  await ctx.sbInsertAssessment({ __forceErr: true });
  check('error pushed to window.__m2mFailures', ctx.__m2mFailures.length === 1,
    JSON.stringify(ctx.__m2mFailures));
  check('error emitted on console.error', errors.length === 1, errors.at(-1));
  const errRow = inserts.filter(i => i.row.event_kind === 'form_error').at(-1);
  check('error persisted as a form_error traffic row',
    !!errRow && errRow.row.outcome === 'error' && errRow.row.error_text === 'boom');
}

// --- when supabase-js never loads, nothing is dropped silently ---
{
  const { ctx } = load({ supabaseLoaded: false });
  check('init failure recorded', ctx.__m2mFailures.length === 1, JSON.stringify(ctx.__m2mFailures));

  await ctx.sbInsertAssessment({ composite_score: 1 });
  check('dropped assessment recorded', ctx.__m2mFailures.at(-1).stage === 'assessment-insert');

  await ctx.sbInsertTraffic('form_view', {});
  check('dropped traffic event recorded', ctx.__m2mFailures.at(-1).stage === 'traffic-insert');
  check('failure logging does not recurse', ctx.__m2mFailures.length === 3,
    'n=' + ctx.__m2mFailures.length);
}

// --- composes with the Cloudflare Worker beacon once it is live ---
{
  const { ctx } = load({ supabaseLoaded: false });
  const before = ctx.__m2mFailures.length;
  let seen = null;
  ctx.window.m2m = { formView: (k, x) => { seen = { k, x }; } };
  await ctx.sbInsertTraffic('form_view', { outcome: 'ok' });
  check('prefers window.m2m.formView when present', seen && seen.k === 'form_view');
  check('beacon path logs no failure', ctx.__m2mFailures.length === before);
}

console.log(failures ? `\n${failures} FAILED` : '\nall passed');
process.exit(failures ? 1 : 0);
