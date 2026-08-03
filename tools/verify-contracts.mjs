#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const read = relative => JSON.parse(readFileSync(join(root, relative), 'utf8'));
const fail = message => { throw new Error(`contract check failed: ${message}`); };
const assert = (condition, message) => { if (!condition) fail(message); };

const fixture = read('schemas/fixtures/engine-transcript-v1.json');
for (const key of ['engine', 'model', 'version', 'settings', 'text', 'audio_duration_ms', 'processing_duration_ms', 'words', 'segments', 'diagnostics', 'context']) {
  assert(Object.hasOwn(fixture, key), `fixture is missing ${key}`);
}
assert(fixture.words.length > 0, 'fixture needs timed words');
for (const word of fixture.words) {
  assert(word.text && Number.isInteger(word.start_ms) && Number.isInteger(word.end_ms), 'word shape is invalid');
  assert(word.start_ms <= word.end_ms, `word ${word.text} ends before it starts`);
  assert(word.confidence == null || word.confidence >= 0 && word.confidence <= 1, `word ${word.text} confidence is invalid`);
}

const registry = read('models/registry.json');
assert(registry.registry_version === 1, 'unknown model registry version');
const ids = new Set();
for (const model of registry.models) {
  assert(!ids.has(model.id), `duplicate model ${model.id}`);
  ids.add(model.id);
  assert(/^https:\/\//.test(model.source), `${model.id} source is not HTTPS`);
  assert(Number.isInteger(model.download_bytes) && model.download_bytes > 0, `${model.id} has no size`);
  assert(model.archive_sha256 || model.manifest || model.files?.length, `${model.id} has no verification material`);
  if (model.archive_sha256) assert(/^[a-f0-9]{64}$/.test(model.archive_sha256), `${model.id} archive hash is invalid`);
  for (const file of model.files ?? []) assert(/^[a-f0-9]{64}$/.test(file.sha256), `${model.id}/${file.path} hash is invalid`);
}

const totals = mode => registry.models
  .filter(model => model.quality_modes.includes(mode))
  .reduce((byPlatform, model) => {
    for (const platform of model.platforms) byPlatform[platform] = (byPlatform[platform] ?? 0) + model.download_bytes;
    return byPlatform;
  }, {});
for (const bytes of Object.values(totals('standard'))) assert(bytes <= 1_500_000_000, 'standard model budget exceeded');
for (const bytes of Object.values(totals('max_accuracy'))) assert(bytes <= 3_000_000_000, 'max-accuracy model budget exceeded');

console.log(`verified ${registry.models.length} pinned models and the shared engine transcript fixture`);
