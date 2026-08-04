#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function usage() {
  return 'usage: prepare-review.mjs --manifest FILE --run NAME=FILE [--run NAME=FILE ...] --seed NAME [--audio-dir DIR] --out FILE';
}

function parseArguments(argv) {
  const values = new Map();
  const runs = [];
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || value == null) throw new Error(usage());
    if (key === '--run') runs.push(value);
    else values.set(key.slice(2), value);
  }
  for (const required of ['manifest', 'out']) {
    if (!values.has(required)) throw new Error(`missing --${required}`);
  }
  if (runs.length === 0) throw new Error('at least one --run NAME=FILE is required');
  return { values, runs };
}

function loadJSON(file) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

function parseRun(specification) {
  const separator = specification.indexOf('=');
  if (separator <= 0 || separator === specification.length - 1) {
    throw new Error(`invalid --run ${specification}; expected NAME=FILE`);
  }
  const name = specification.slice(0, separator);
  if (!/^[a-z0-9][a-z0-9_-]*$/u.test(name)) {
    throw new Error(`invalid engine name ${name}`);
  }
  return { name, file: resolve(specification.slice(separator + 1)) };
}

function escapeEmbeddedJSON(value) {
  return JSON.stringify(value)
    .replaceAll('&', '\\u0026')
    .replaceAll('<', '\\u003c')
    .replaceAll('>', '\\u003e');
}

function browserAudioURL(audioPath, audioDirectory, itemID) {
  if (!audioDirectory || !existsSync(audioPath)) return pathToFileURL(audioPath).href;
  if (process.platform !== 'darwin') {
    throw new Error('--audio-dir currently requires macOS afconvert');
  }
  const safeID = itemID.replaceAll(/[^a-z0-9._-]/giu, '_');
  const output = join(audioDirectory, `${safeID}.m4a`);
  mkdirSync(audioDirectory, { recursive: true });
  if (!existsSync(output)) {
    execFileSync('/usr/bin/afconvert', [audioPath, output, '-f', 'm4af', '-d', '0'], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
  }
  return pathToFileURL(output).href;
}

function buildPayload(manifestPath, runSpecifications, seedName, audioDirectory) {
  const manifest = loadJSON(manifestPath);
  if (!Array.isArray(manifest.items) || manifest.items.length === 0) {
    throw new Error('manifest has no items');
  }

  const runEntries = runSpecifications.map(parseRun);
  const names = new Set();
  const runs = new Map();
  for (const entry of runEntries) {
    if (names.has(entry.name)) throw new Error(`duplicate engine name ${entry.name}`);
    names.add(entry.name);
    const run = loadJSON(entry.file);
    const items = new Map();
    for (const item of run.items ?? []) {
      if (items.has(item.id)) throw new Error(`${entry.name} contains duplicate item ${item.id}`);
      items.set(item.id, item);
    }
    runs.set(entry.name, items);
  }

  const seed = seedName ?? runEntries[0].name;
  if (!runs.has(seed)) throw new Error(`seed engine ${seed} was not supplied as --run`);
  const manifestDirectory = dirname(manifestPath);
  const items = manifest.items.map(item => {
    const hypotheses = {};
    for (const entry of runEntries) {
      const hypothesis = runs.get(entry.name).get(item.id);
      if (!hypothesis) throw new Error(`${entry.name} is missing ${item.id}`);
      hypotheses[entry.name] = {
        text: hypothesis.text ?? '',
        processing_ms: hypothesis.processing_ms ?? 0,
      };
    }
    const audioPath = resolve(manifestDirectory, item.audio);
    return {
      id: item.id,
      session_id: item.session_id ?? item.id,
      audio_url: browserAudioURL(audioPath, audioDirectory, item.id),
      audio_exists: existsSync(audioPath),
      duration_seconds: item.duration_seconds,
      categories: item.categories,
      reference: item.reference,
      reference_status: item.reference_status,
      hypotheses,
    };
  });

  return {
    manifest,
    manifest_path: manifestPath,
    seed_engine: seed,
    engine_names: runEntries.map(entry => entry.name),
    items,
  };
}

function documentFor(payload) {
  const encoded = escapeEmbeddedJSON(payload);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Patchthrough transcript review</title>
  <style>
    :root { color-scheme: light dark; font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #101113; color: #f3f2ed; }
    button, textarea, select { font: inherit; }
    button { border: 1px solid #4b4d52; border-radius: 9px; padding: .55rem .75rem; background: #25272b; color: inherit; cursor: pointer; }
    button:hover { background: #303339; }
    header { position: sticky; top: 0; z-index: 2; display: flex; gap: 1rem; align-items: center; justify-content: space-between; padding: 1rem 1.25rem; border-bottom: 1px solid #313338; background: rgba(16,17,19,.95); backdrop-filter: blur(14px); }
    header h1 { font-size: 1rem; margin: 0; }
    .progress { color: #b8bac1; font-variant-numeric: tabular-nums; }
    main { max-width: 1180px; margin: auto; padding: 1.25rem; }
    .notice { padding: .9rem 1rem; border: 1px solid #554c2f; border-radius: 12px; background: #282316; color: #eee2b3; line-height: 1.45; }
    .toolbar { display: grid; grid-template-columns: minmax(0, 1fr) auto auto; gap: .6rem; margin: 1rem 0; }
    select { min-width: 0; border: 1px solid #4b4d52; border-radius: 9px; padding: .55rem .7rem; background: #1c1e22; color: inherit; }
    .metadata { display: flex; flex-wrap: wrap; gap: .45rem; margin-bottom: .8rem; color: #b8bac1; }
    .pill { border: 1px solid #3d4046; border-radius: 999px; padding: .2rem .5rem; font-size: .8rem; }
    audio { width: 100%; margin: .5rem 0 1rem; }
    h2 { font-size: 1rem; margin: 1.2rem 0 .55rem; }
    textarea { width: 100%; min-height: 220px; resize: vertical; border: 1px solid #474a50; border-radius: 12px; padding: .9rem; background: #17191c; color: inherit; line-height: 1.55; }
    .approval { display: flex; gap: .55rem; align-items: center; margin: .7rem 0 1.2rem; }
    .approval input { width: 1.1rem; height: 1.1rem; }
    .hypotheses { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: .8rem; }
    .hypothesis { border: 1px solid #34363b; border-radius: 12px; padding: .8rem; background: #17191c; }
    .hypothesis header { position: static; padding: 0 0 .6rem; border: 0; background: none; backdrop-filter: none; }
    .hypothesis h3 { margin: 0; font-size: .9rem; }
    .hypothesis p { max-height: 330px; overflow: auto; white-space: pre-wrap; color: #d2d3d6; line-height: 1.5; }
    .missing { color: #ff9e91; }
    @media (max-width: 640px) { .toolbar { grid-template-columns: 1fr 1fr; } .toolbar select { grid-column: 1 / -1; } }
  </style>
</head>
<body>
  <header><h1>Patchthrough transcript review</h1><div class="progress" id="progress"></div><button id="export">Export reviewed manifest</button></header>
  <main>
    <div class="notice">Machine text is only a starting point. Listen to the recording (or use an authorized, verified caption file), correct every spoken word, then mark the track reviewed. Nothing leaves this computer; Export downloads a new manifest and leaves unreviewed tracks as drafts.</div>
    <div class="toolbar"><select id="item"></select><button id="previous">Previous</button><button id="next">Next</button></div>
    <div class="metadata" id="metadata"></div>
    <audio id="audio" controls preload="metadata"></audio>
    <div class="missing" id="missing"></div>
    <h2>Human-corrected reference</h2>
    <textarea id="reference" spellcheck="true"></textarea>
    <label class="approval"><input id="corrected" type="checkbox"> I verified this track against the audio</label>
    <h2>Engine hypotheses for comparison</h2>
    <div class="hypotheses" id="hypotheses"></div>
  </main>
  <script type="application/json" id="payload">${encoded}</script>
  <script>
    const data = JSON.parse(document.getElementById('payload').textContent);
    const storageKey = 'patchthrough-review:' + data.manifest_path;
    const stored = JSON.parse(localStorage.getItem(storageKey) || '{}');
    const reviews = {};
    for (const item of data.items) {
      reviews[item.id] = stored[item.id] || {
        reference: item.reference_status === 'corrected' ? item.reference : item.hypotheses[data.seed_engine].text,
        corrected: item.reference_status === 'corrected'
      };
    }
    const select = document.getElementById('item');
    const reference = document.getElementById('reference');
    const corrected = document.getElementById('corrected');
    let index = 0;
    function save() {
      localStorage.setItem(storageKey, JSON.stringify(reviews));
      updateProgress();
    }
    function updateProgress() {
      const count = Object.values(reviews).filter(review => review.corrected).length;
      document.getElementById('progress').textContent = count + ' / ' + data.items.length + ' reviewed';
      for (let optionIndex = 0; optionIndex < data.items.length; optionIndex++) {
        const item = data.items[optionIndex];
        select.options[optionIndex].textContent = (reviews[item.id].corrected ? '✓ ' : '') + item.id;
      }
    }
    function render() {
      const item = data.items[index];
      const review = reviews[item.id];
      select.value = String(index);
      reference.value = review.reference;
      corrected.checked = review.corrected;
      const metadata = document.getElementById('metadata');
      metadata.replaceChildren();
      for (const value of [item.session_id, Math.round(item.duration_seconds) + ' sec', ...item.categories]) {
        const pill = document.createElement('span');
        pill.className = 'pill';
        pill.textContent = value;
        metadata.appendChild(pill);
      }
      const audio = document.getElementById('audio');
      audio.src = item.audio_url;
      document.getElementById('missing').textContent = item.audio_exists ? '' : 'Audio file was missing when this packet was generated.';
      const hypotheses = document.getElementById('hypotheses');
      hypotheses.replaceChildren();
      for (const engine of data.engine_names) {
        const hypothesis = item.hypotheses[engine];
        const card = document.createElement('section');
        card.className = 'hypothesis';
        const cardHeader = document.createElement('header');
        const title = document.createElement('h3');
        title.textContent = engine + ' · ' + (hypothesis.processing_ms / 1000).toFixed(1) + ' sec';
        const use = document.createElement('button');
        use.textContent = 'Use as draft';
        use.addEventListener('click', () => { reference.value = hypothesis.text; reviews[item.id].reference = hypothesis.text; reviews[item.id].corrected = false; corrected.checked = false; save(); });
        const text = document.createElement('p');
        text.textContent = hypothesis.text || '(no words)';
        cardHeader.append(title, use);
        card.append(cardHeader, text);
        hypotheses.appendChild(card);
      }
      updateProgress();
    }
    data.items.forEach((item, itemIndex) => {
      const option = document.createElement('option');
      option.value = String(itemIndex);
      select.appendChild(option);
    });
    select.addEventListener('change', () => { index = Number(select.value); render(); });
    document.getElementById('previous').addEventListener('click', () => { index = (index + data.items.length - 1) % data.items.length; render(); });
    document.getElementById('next').addEventListener('click', () => { index = (index + 1) % data.items.length; render(); });
    reference.addEventListener('input', () => { reviews[data.items[index].id].reference = reference.value; reviews[data.items[index].id].corrected = false; corrected.checked = false; save(); });
    corrected.addEventListener('change', () => { reviews[data.items[index].id].reference = reference.value; reviews[data.items[index].id].corrected = corrected.checked; save(); });
    document.getElementById('export').addEventListener('click', () => {
      const output = structuredClone(data.manifest);
      for (const item of output.items) {
        if (reviews[item.id].corrected) {
          item.reference = reviews[item.id].reference.trim();
          item.reference_status = 'corrected';
        } else if (item.reference_status !== 'corrected') {
          item.reference = '';
          item.reference_status = 'draft';
        }
      }
      const blob = new Blob([JSON.stringify(output, null, 2) + '\\n'], { type: 'application/json' });
      const link = document.createElement('a');
      link.href = URL.createObjectURL(blob);
      link.download = 'corpus.reviewed.json';
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    });
    render();
  </script>
</body>
</html>\n`;
}

const { values, runs } = parseArguments(process.argv);
const manifestPath = resolve(values.get('manifest'));
const output = resolve(values.get('out'));
if (existsSync(output)) throw new Error(`refusing to overwrite existing review packet: ${output}`);
const audioDirectory = values.has('audio-dir') ? resolve(values.get('audio-dir')) : null;
const payload = buildPayload(manifestPath, runs, values.get('seed'), audioDirectory);
writeFileSync(output, documentFor(payload));
console.log(`wrote private review packet for ${payload.items.length} tracks to ${output}`);
if (audioDirectory) console.log(`repackaged source audio for browser playback in ${audioDirectory}`);
console.log(`seeded draft references from ${payload.seed_engine}; review state stays in this browser until exported`);
