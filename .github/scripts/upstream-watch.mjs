// Upstream watch: follows the entries of .github/upstream-watch.json (posted
// patch series, Patchwork searches, GitHub PRs/issues/searches, fork branches,
// master files, tags and releases) and reports what changed since the last run.
//
// State lives in one GitHub issue labelled "upstream-watch" (a compressed
// snapshot in an HTML comment of its body). A change is posted as a comment
// on that issue and marked with the label "upstream-change"; a Claude session
// in this repository is told about it at start (.claude/hooks/) and removes
// the label after updating UPSTREAM-TRACKING.md. Nothing is committed.
//
// Environment: GITHUB_TOKEN (issues: write), GITHUB_REPOSITORY (owner/repo).
// DRY_RUN=1 prints the report instead of touching the issue.

import fs from 'node:fs';
import zlib from 'node:zlib';

const CONFIG = '.github/upstream-watch.json';
const LABEL = 'upstream-watch';
const CHANGE_LABEL = 'upstream-change';
const TITLE = 'Upstream watch';
const STATE_RE = /<!-- upstream-watch-state\n([A-Za-z0-9+/=\n]+)\n-->/;
const TOKEN = process.env.GITHUB_TOKEN;
const REPO = process.env.GITHUB_REPOSITORY;
const DRY = process.env.DRY_RUN === '1';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function http(url, { gh = false, raw = false, method = 'GET', body } = {}) {
  const headers = { 'User-Agent': 'upstream-watch (github.com/' + (REPO || 'local') + ')' };
  if (gh) {
    headers.Accept = raw ? 'application/vnd.github.raw' : 'application/vnd.github+json';
    if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  }
  if (body) headers['Content-Type'] = 'application/json';
  let last;
  // patchwork.ozlabs.org answers back-to-back searches with 502: space them out
  const patchwork = url.includes('patchwork.');
  if (patchwork) await sleep(10000);
  for (let attempt = 0; attempt < (patchwork ? 5 : 3); attempt++) {
    try {
      // Patchwork searches can take a minute; nothing should hang the run
      const res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(120000) });
      if (res.status === 404) return null;
      if (res.ok) return raw ? res.text() : res.status === 204 ? null : res.json();
      last = new Error(`${method} ${url}: HTTP ${res.status}`);
      if (res.status < 500 && res.status !== 429 && res.status !== 403) break;
    } catch (e) {
      last = e;
    }
    await sleep((patchwork ? 30000 : 3000) * (attempt + 1));
  }
  throw last;
}

const ghApi = (path, opts = {}) => http(`https://api.github.com${path}`, { ...opts, gh: true });
const short = (s, n = 90) => (s.length > n ? s.slice(0, n - 1) + '…' : s);

// ── one function per entry type: returns { value, items? } ───────────────────
// value: compact snapshot for comparison; items: id -> text for new-item reports

async function patchworkSeries(e) {
  const s = await http(`${e.server}/api/series/${e.series}/`);
  if (!s) return { value: { missing: true } };
  const patches = await http(`${e.server}/api/patches/?series=${e.series}&per_page=100`);
  const states = {};
  for (const p of patches) states[p.id] = p.state;
  return {
    value: { version: s.version, states },
    label: `series ${e.series} "${s.name}" v${s.version} (${s.submitter.name})`,
    names: Object.fromEntries(patches.map((p) => [p.id, p.name])),
    link: s.web_url,
  };
}

async function patchworkSearch(e) {
  const url = `${e.server}/api/patches/?project=${encodeURIComponent(e.project)}&q=${encodeURIComponent(e.q)}&order=-date&per_page=30`;
  const list = await http(url);
  const value = {};
  const items = {};
  for (const p of list) {
    value[p.id] = p.state;
    items[p.id] = `${p.date.slice(0, 10)} ${p.state}: ${short(p.name)} (${p.submitter.name}) ${p.web_url}`;
  }
  return { value, items };
}

async function githubItem(e) {
  const i = await ghApi(`/repos/${e.repo}/issues/${e.number}`);
  if (!i) return { value: { missing: true } };
  const merged = i.pull_request ? (i.pull_request.merged_at ? 'merged' : '') : '';
  return {
    value: { state: merged || i.state, comments: i.comments, updated: i.updated_at },
    label: `${e.repo}#${e.number} "${short(i.title, 70)}"`,
    link: i.html_url,
  };
}

async function githubSearch(e) {
  const r = await ghApi(`/search/issues?q=${encodeURIComponent(e.q)}&sort=updated&order=desc&per_page=30`);
  const value = {};
  const items = {};
  for (const i of r.items) {
    const key = `${i.repository_url.split('/repos/')[1]}#${i.number}`;
    const kind = i.pull_request ? 'PR' : 'issue';
    value[key] = `${i.state}/${i.comments}`;
    items[key] = `${kind} ${key} ${i.state}, ${i.comments} comments, updated ${i.updated_at.slice(0, 10)}: ${short(i.title)} ${i.html_url}`;
  }
  await sleep(2500); // search API: 30 requests a minute
  return { value, items };
}

async function githubBranches(e) {
  const list = await ghApi(`/repos/${e.repo}/branches?per_page=100`);
  return { value: Object.fromEntries(list.map((b) => [b.name, b.commit.sha.slice(0, 10)])) };
}

async function githubCommits(e) {
  const list = await ghApi(`/repos/${e.repo}/commits?sha=${encodeURIComponent(e.branch)}&per_page=1`);
  const c = list[0];
  return {
    value: { head: c.sha.slice(0, 10) },
    label: `${e.repo} ${e.branch} at ${c.sha.slice(0, 10)} ${c.commit.committer.date.slice(0, 10)} "${short(c.commit.message.split('\n')[0], 70)}"`,
    link: c.html_url,
  };
}

async function githubFile(e) {
  const text = await ghApi(`/repos/${e.repo}/contents/${e.path}${e.ref ? `?ref=${e.ref}` : ''}`, { raw: true });
  if (text === null) return { value: { missing: true } };
  const value = { matches: new RegExp(e.pattern, 'm').test(text) };
  if (e.hash) {
    const { createHash } = await import('node:crypto');
    value.hash = createHash('sha256').update(text).digest('hex').slice(0, 12);
  }
  return { value, label: `${e.repo}/${e.path}`, link: `https://github.com/${e.repo}/blob/HEAD/${e.path}` };
}

async function githubTags(e) {
  const list = await ghApi(`/repos/${e.repo}/tags?per_page=30`);
  return { value: Object.fromEntries(list.map((t) => [t.name, t.commit.sha.slice(0, 10)])) };
}

async function githubReleases(e) {
  const list = await ghApi(`/repos/${e.repo}/releases?per_page=15`);
  return { value: Object.fromEntries(list.map((r) => [r.tag_name, r.published_at ? r.published_at.slice(0, 10) : 'draft'])) };
}

const HANDLERS = {
  'patchwork-series': patchworkSeries,
  'patchwork-search': patchworkSearch,
  'github-item': githubItem,
  'github-search': githubSearch,
  'github-branches': githubBranches,
  'github-commits': githubCommits,
  'github-file': githubFile,
  'github-tags': githubTags,
  'github-releases': githubReleases,
};

// ── compare one entry's old and new snapshot; returns report lines ───────────

function diff(e, old, now) {
  const lines = [];
  const v = now.value;
  if (old === undefined) return lines; // new entry: baseline only
  switch (e.type) {
    case 'patchwork-series':
      if (old.version !== v.version) lines.push(`new version v${v.version} (was v${old.version})`);
      for (const [id, st] of Object.entries(v.states || {})) {
        if (!(id in (old.states || {}))) lines.push(`new patch ${now.names[id]}: ${st}`);
        else if (old.states[id] !== st) lines.push(`${short(now.names[id])}: ${old.states[id]} → ${st}`);
      }
      break;
    case 'patchwork-search':
    case 'github-search':
      for (const [id, st] of Object.entries(v)) {
        if (!(id in old)) lines.push(`new: ${now.items[id]}`);
        else if (old[id] !== st) lines.push(`changed (${old[id]} → ${st}): ${now.items[id]}`);
      }
      break;
    case 'github-item':
      if (old.state !== v.state) lines.push(`state ${old.state} → ${v.state}`);
      if (old.comments !== v.comments) lines.push(`${v.comments - old.comments} new comment(s)`);
      else if (old.updated !== v.updated && old.state === v.state) lines.push(`updated ${v.updated.slice(0, 10)}`);
      break;
    case 'github-branches':
    case 'github-tags':
    case 'github-releases':
      for (const [k, val] of Object.entries(v)) {
        if (!(k in old)) lines.push(`new ${e.type.replace('github-', '').replace(/es$|s$/, '')}: ${k} (${val})`);
        else if (e.type === 'github-branches' && old[k] !== val) lines.push(`branch ${k} moved ${old[k]} → ${val}`);
      }
      if (e.type === 'github-branches') for (const k of Object.keys(old)) if (!(k in v)) lines.push(`branch ${k} removed`);
      break;
    case 'github-commits':
      if (old.head !== v.head) lines.push(`new commits: ${now.label}`);
      break;
    case 'github-file':
      if (old.missing !== v.missing) lines.push(v.missing ? 'file is gone' : 'file exists again');
      else if (old.matches !== v.matches)
        lines.push(v.matches ? `pattern matches again (${e.while_matching})` : `**pattern no longer matches**: no longer true that ${e.while_matching}`);
      else if (e.hash && old.hash !== v.hash) lines.push('file content changed');
      break;
  }
  return lines;
}

// ── issue holding the state ──────────────────────────────────────────────────

function encodeState(state) {
  return zlib.gzipSync(JSON.stringify(state)).toString('base64').replace(/(.{100})/g, '$1\n');
}
function decodeState(body) {
  const m = STATE_RE.exec(body || '');
  if (!m) return {};
  return JSON.parse(zlib.gunzipSync(Buffer.from(m[1].replace(/\n/g, ''), 'base64')).toString());
}

async function ensureLabel(name, color, description) {
  if (await ghApi(`/repos/${REPO}/labels/${name}`)) return;
  await ghApi(`/repos/${REPO}/labels`, { method: 'POST', body: { name, color, description } });
}

function issueBody(state, results, errors, when) {
  const rows = results
    .map(({ e, now }) => `| \`${e.id}\` | ${e.type} | ${e.row} | ${now.link ? `[link](${now.link})` : ''} |`)
    .join('\n');
  return [
    'Followed by `.github/workflows/upstream-watch.yml` from the list in `.github/upstream-watch.json`; tracker: `UPSTREAM-TRACKING.md`.',
    '',
    `Last run: ${when}. A change is posted as a comment and labels this issue \`${CHANGE_LABEL}\`. After updating UPSTREAM-TRACKING.md, remove that label (\`gh issue edit <n> --remove-label ${CHANGE_LABEL}\`). Keep this issue open: it holds the snapshot.`,
    errors.length ? `\nEntries that failed this run (kept at their last value):\n${errors.map((x) => `- \`${x}\``).join('\n')}` : '',
    '',
    '| Entry | Type | Tracker row | |',
    '|---|---|---|---|',
    rows,
    '',
    `<!-- upstream-watch-state\n${encodeState(state)}\n-->`,
  ].join('\n');
}

// ── main ─────────────────────────────────────────────────────────────────────

const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
let issue = null;
if (!DRY) {
  if (!TOKEN || !REPO) throw new Error('GITHUB_TOKEN and GITHUB_REPOSITORY are required (or DRY_RUN=1)');
  await ensureLabel(LABEL, '5319e7', 'Holds the upstream watch snapshot');
  await ensureLabel(CHANGE_LABEL, 'd93f0b', 'Upstream watch found changes not reviewed yet');
  const found = await ghApi(`/repos/${REPO}/issues?labels=${LABEL}&state=open&per_page=5`);
  issue = found && found.length ? found[0] : null;
}
const oldState = issue ? decodeState(issue.body) : DRY && fs.existsSync('upstream-watch-state.json') ? JSON.parse(fs.readFileSync('upstream-watch-state.json', 'utf8')) : {};

// ONLY=<id,id> limits a (dry) run to some entries, for testing; the others keep their snapshot
const only = process.env.ONLY ? process.env.ONLY.split(',') : null;
const newState = only ? { ...oldState } : {};
const results = [];
const errors = [];
const report = [];
for (const e of cfg.watch) {
  if (only && !only.includes(e.id)) continue;
  const handler = HANDLERS[e.type];
  if (!handler) throw new Error(`unknown type ${e.type} in entry ${e.id}`);
  const t0 = Date.now();
  try {
    const now = await handler(e);
    console.error(`${e.id}: ok (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
    newState[e.id] = now.value;
    results.push({ e, now });
    const lines = diff(e, oldState[e.id], now);
    if (lines.length) report.push(`### \`${e.id}\` (${e.row})\n${now.label ? `${now.label}${now.link ? ` — ${now.link}` : ''}\n` : ''}${lines.map((l) => `- ${l}`).join('\n')}`);
  } catch (err) {
    console.error(`${e.id}: ${err.message}`);
    errors.push(e.id);
    if (oldState[e.id] !== undefined) newState[e.id] = oldState[e.id];
    results.push({ e, now: {} });
  }
}

const when = new Date().toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
const body = issueBody(newState, results, errors, when);
const comment = `Changes found ${when}:\n\n${report.join('\n\n')}\n\nNext: update the named rows of UPSTREAM-TRACKING.md (drop a patch whose "Drop when" is met, note contribution chances), then remove the label \`${CHANGE_LABEL}\`.`;

console.log(report.length ? comment : `No changes (${results.length} entries, ${errors.length} failed).`);
if (DRY) {
  fs.writeFileSync('upstream-watch-state.json', JSON.stringify(newState));
} else if (!issue) {
  await ghApi(`/repos/${REPO}/issues`, { method: 'POST', body: { title: TITLE, body, labels: [LABEL] } });
  console.log('Created the watch issue with the first snapshot (no changes reported on a first run).');
} else {
  await ghApi(`/repos/${REPO}/issues/${issue.number}`, { method: 'PATCH', body: { body } });
  if (report.length) {
    await ghApi(`/repos/${REPO}/issues/${issue.number}/comments`, { method: 'POST', body: { body: comment } });
    await ghApi(`/repos/${REPO}/issues/${issue.number}/labels`, { method: 'POST', body: { labels: [CHANGE_LABEL] } });
  }
}
if (errors.length === cfg.watch.length) process.exit(1);
