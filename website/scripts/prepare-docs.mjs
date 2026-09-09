// Copies the repo's markdown docs into src/content/docs/docs/ with Starlight
// frontmatter and rewritten cross-links. Regenerates from scratch on every run.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const out = path.resolve(here, '..', 'src', 'content', 'docs', 'docs');
const BASE = (process.env.CUSTOM_DOMAIN ? '' : (process.env.BASE ?? '/gothalo')).replace(/\/$/, '');
const GH = 'https://github.com/dipeshdulal/gothalo';
// hand-written pages the wipe must never delete
const KEEP = new Set(['index.mdx', 'install.md']);

// source file -> route under /docs/
const MAP = new Map([
  ['docs/API.md', 'reference/api'],
  ['docs/ARCHITECTURE.md', 'reference/architecture'],
  ['docs/PUSH.md', 'guides/push'],
  ['docs/AGENT-INTEGRATION.md', 'guides/agent-integration'],
  ['docs/TESTING.md', 'guides/testing'],
  ['docs/ROADMAP.md', 'project/roadmap'],
  ['docs/DECISIONS.md', 'project/decisions'],
  ['CONTRACT.md', 'contracts/events'],
]);
for (const f of fs.readdirSync(path.join(repo, 'docs'))) {
  if (/^CONTRACT-.+\.md$/.test(f)) {
    MAP.set(`docs/${f}`, `contracts/${f.slice(9, -3).toLowerCase()}`);
  }
}

const url = (route) => `${BASE}/docs/${route}/`;
// basename (lowercased) -> site url, for resolving relative links
const byName = new Map();
for (const [src, route] of MAP) byName.set(path.basename(src).toLowerCase(), url(route));

function titleOf(h1) {
  return h1
    .replace(/^#\s+/, '')
    .replace(/^CONTRACT\s*[—-]\s*/i, '')
    .replace(/`/g, '')
    .trim();
}

function describe(body) {
  for (const block of body.split(/\n\s*\n/)) {
    const t = block.trim();
    if (!t || /^[#>|`\-*[]|^\d+\./.test(t)) continue;
    const flat = t.replace(/\s+/g, ' ').replace(/`|\*\*|\[|\]\([^)]*\)/g, '').trim();
    if (flat.length > 20) return flat.length > 160 ? flat.slice(0, 157).trimEnd() + '...' : flat;
  }
  return 'gothalo documentation.';
}

function rewrite(body, srcDir) {
  return body.replace(/\]\((?!https?:|#|mailto:)([^)\s]+)(\s+"[^"]*")?\)/g, (m, target, title) => {
    const cut = target.indexOf('#');
    const file = cut === -1 ? target : target.slice(0, cut);
    const hash = cut === -1 ? '' : target.slice(cut);
    if (!file) return m;
    const name = path.basename(file).toLowerCase();
    if (name === 'readme.md') return `](${GH}/blob/main/README.md${hash}${title ?? ''})`;
    const hit = byName.get(name);
    if (hit && file.endsWith('.md')) return `](${hit}${hash}${title ?? ''})`;
    const abs = path.posix.normalize(path.posix.join(srcDir, file)).replace(/^\.\//, '');
    return `](${GH}/blob/main/${abs}${hash}${title ?? ''})`;
  });
}

fs.mkdirSync(out, { recursive: true });
for (const e of fs.readdirSync(out)) {
  if (!KEEP.has(e)) fs.rmSync(path.join(out, e), { recursive: true, force: true });
}

let n = 0;
for (const [src, route] of MAP) {
  const raw = fs.readFileSync(path.join(repo, src), 'utf8');
  const lines = raw.split('\n');
  const i = lines.findIndex((l) => /^#\s+/.test(l));
  const title = i === -1 ? path.basename(src, '.md') : titleOf(lines[i]);
  if (i !== -1) lines.splice(i, 1);
  const body = rewrite(lines.join('\n').replace(/^\s+/, ''), path.posix.dirname(src));

  const fm = [
    '---',
    `title: ${JSON.stringify(title)}`,
    `description: ${JSON.stringify(describe(body))}`,
    `editUrl: ${JSON.stringify(`${GH}/edit/main/${src}`)}`,
    ...(route === 'contracts/events' ? ['sidebar:', '  order: 0'] : []),
    '---',
    '',
  ].join('\n');

  const dest = path.join(out, `${route}.md`);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, fm + body + '\n');
  n++;
}

console.log(`prepare-docs: wrote ${n} pages to src/content/docs/docs (base ${BASE || '/'})`);
