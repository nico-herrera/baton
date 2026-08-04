#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith('--') || value == null) {
    throw new Error('usage: bootstrap-corpus.mjs --recordings DIR --out FILE');
  }
  args.set(key.slice(2), value);
}
for (const required of ['recordings', 'out']) {
  if (!args.has(required)) throw new Error(`missing --${required}`);
}

const recordings = resolve(args.get('recordings'));
const output = resolve(args.get('out'));
if (existsSync(output)) {
  throw new Error(`refusing to overwrite existing corpus draft: ${output}`);
}

const outputDirectory = dirname(output);
const items = [];
let meetingSeconds = 0;
for (const entry of readdirSync(recordings, { withFileTypes: true }).filter(entry => entry.isDirectory())) {
  const sessionDirectory = join(recordings, entry.name);
  const metaPath = join(sessionDirectory, 'meta.json');
  if (!existsSync(metaPath)) continue;
  const meta = JSON.parse(readFileSync(metaPath, 'utf8'));
  if (meta.clean_stop !== true || !Number.isFinite(meta.duration_seconds) || meta.duration_seconds <= 0) continue;

  let included = false;
  for (const [track, filename] of Object.entries(meta.files ?? {}).sort()) {
    if (typeof filename !== 'string') continue;
    const audioPath = join(sessionDirectory, filename);
    if (!existsSync(audioPath) || !statSync(audioPath).isFile()) continue;
    included = true;
    items.push({
      id: `${entry.name}-${track}`,
      session_id: entry.name,
      audio: relative(outputDirectory, audioPath).split(sep).join('/'),
      reference: '',
      reference_status: 'draft',
      duration_seconds: meta.duration_seconds,
      categories: ['needs_labeling', track === 'mic' ? 'microphone' : 'system_audio'],
      technical_terms: [],
      context_terms: [],
      readability_preference: 'unscored',
    });
  }
  if (included) meetingSeconds += meta.duration_seconds;
}

mkdirSync(outputDirectory, { recursive: true });
writeFileSync(output, `${JSON.stringify({
  corpus_version: 1,
  name: 'patchthrough-private-corrected-meetings',
  private: true,
  items,
}, null, 2)}\n`);

console.log(`wrote ${items.length} track items from ${(meetingSeconds / 3600).toFixed(2)} meeting hours to ${output}`);
console.log('references are intentionally blank; correct every track, set reference_status to corrected, and replace needs_labeling before scoring');
