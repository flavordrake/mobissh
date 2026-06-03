#!/usr/bin/env node
// scripts/render-release-notes.mjs — Render native-release-notes.md sections to HTML.
//
// Replaces the hand-rolled awk/sed markdown in gen-apk-install-page.sh, which
// dropped indented sub-bullets and rendered **bold** / `code` literally (#713).
//
// The notes file is split on lines starting with "## " into sections. The FIRST
// section is the curated "What to verify" list; each SUBSEQUENT section becomes a
// collapsible <details class="clog"> changelog entry. Intro prose before the
// first "## " is ignored (matches the prior behavior).
//
// Markdown is rendered by `marked` (zero-dep, resolved from server/node_modules).
// Input is our own trusted notes, so no HTML sanitizer is needed.
//
// Usage:   node scripts/render-release-notes.mjs <notes-file>
// Output:  JSON on stdout: { heading, verifyHtml, changelogHtml }
//   heading        first section title (sans "## "), or "What to verify"
//   verifyHtml      marked() of the first section body (emits its own <ul>)
//   changelogHtml   joined <details> blocks for sections[1..]
//
// Fails LOUDLY (non-zero exit, message on stderr) if marked can't be imported or
// the notes file can't be read — the caller must not emit broken HTML silently.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const notesPath = process.argv[2];
if (!notesPath) {
  console.error('render-release-notes: missing notes file path argument');
  process.exit(2);
}

// marked lives in server/node_modules (zero-dep). This script sits in scripts/,
// so a bare `import 'marked'` won't resolve. Resolve it explicitly relative to
// server/package.json via createRequire, then import the resolved file URL.
let marked;
try {
  const here = dirname(fileURLToPath(import.meta.url));
  const serverRequire = createRequire(
    pathToFileURL(join(here, '..', 'server', 'package.json'))
  );
  const markedPath = serverRequire.resolve('marked');
  ({ marked } = await import(pathToFileURL(markedPath).href));
} catch (err) {
  console.error('render-release-notes: cannot import "marked" — run `npm install` in server/');
  console.error(String(err && err.message ? err.message : err));
  process.exit(3);
}

let raw;
try {
  raw = readFileSync(notesPath, 'utf8');
} catch (err) {
  console.error(`render-release-notes: cannot read notes file: ${notesPath}`);
  console.error(String(err && err.message ? err.message : err));
  process.exit(4);
}

// Split into sections on lines that start with "## ". Each section keeps its
// title (the text after "## ") and its body (everything up to the next "## ").
const lines = raw.split('\n');
const sections = [];
let cur = null;
for (const line of lines) {
  const m = /^## (.*)$/.exec(line);
  if (m) {
    if (cur) sections.push(cur);
    cur = { title: m[1].trim(), body: [] };
  } else if (cur) {
    cur.body.push(line);
  }
  // lines before the first "## " (intro prose) are dropped
}
if (cur) sections.push(cur);

// marked configuration: GitHub-flavored defaults are fine. Input is trusted
// (our own release notes), so the default HTML passthrough is acceptable.
marked.setOptions({ gfm: true, breaks: false });

const renderBody = (bodyLines) => marked.parse(bodyLines.join('\n').trim());

// Defensive escape for the <summary> title text (our own trusted text, but keep
// the markup valid if a title ever contains angle brackets/ampersands).
const escTitle = (t) =>
  t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

let heading = 'What to verify';
let verifyHtml = '<ul>\n<li>(curate user-facing notes in native-release-notes.md)</li>\n</ul>';
let changelogHtml = '';

if (sections.length > 0) {
  heading = sections[0].title || 'What to verify';
  const firstHtml = renderBody(sections[0].body);
  if (firstHtml.trim()) verifyHtml = firstHtml;

  const blocks = [];
  for (const s of sections.slice(1)) {
    const inner = renderBody(s.body);
    blocks.push(
      `  <details class="clog"><summary>${escTitle(s.title)}</summary>${inner}</details>`
    );
  }
  changelogHtml = blocks.join('\n');
}

process.stdout.write(JSON.stringify({ heading, verifyHtml, changelogHtml }));
