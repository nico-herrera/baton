import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = resolve(import.meta.dirname, '..');

test('creates a local review packet from shared corpus runs', () => {
  const directory = mkdtempSync(join(tmpdir(), 'patchthrough-review-'));
  const output = join(directory, 'review.html');
  const result = spawnSync(process.execPath, [
    join(root, 'quality/prepare-review.mjs'),
    '--manifest', join(root, 'quality/fixtures/corpus.json'),
    '--run', `parakeet=${join(root, 'quality/fixtures/baseline.json')}`,
    '--run', `candidate=${join(root, 'quality/fixtures/candidate.json')}`,
    '--seed', 'parakeet',
    '--out', output,
  ], { encoding: 'utf8' });

  assert.equal(result.status, 0, result.stderr);
  const html = readFileSync(output, 'utf8');
  assert.match(html, /Patchthrough transcript review/u);
  assert.match(html, /technical/u);
  assert.match(html, /parakeet/u);
  assert.match(html, /candidate/u);
  assert.match(html, /Export reviewed manifest/u);
});

