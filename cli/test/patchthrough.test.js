'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const test = require('node:test');
const {
  listSessions,
  readExternalTranscript,
  resolveRecordingsRoot,
  resolveSession,
  stageSession,
} = require('../src/patchthrough');

function temporaryDirectory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'patchthrough-cli-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function writeSession(root, name, text = 'Ship the command line split.') {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'transcript.md'), `# ${name}\n\nengine: test\n\n**[0:01] me:** ${text}\n`);
  fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify({ duration_seconds: 65, clean_stop: true }));
  return dir;
}

test('recordings root follows the shared app config', (t) => {
  const home = temporaryDirectory(t);
  const config = path.join(home, '.config', 'patchthrough', 'config.json');
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, JSON.stringify({ recordings_dir: '~/Meetings' }));
  assert.equal(resolveRecordingsRoot(undefined, { home }), path.join(home, 'Meetings'));
  assert.equal(resolveRecordingsRoot('/tmp/override', { home }), path.resolve('/tmp/override'));
});

test('newest transcribed session wins and pending sessions remain listable', (t) => {
  const root = temporaryDirectory(t);
  writeSession(root, '2026.07.30-0900', 'Older session.');
  writeSession(root, '2026.07.30-1000', 'Newest session.');
  const pending = path.join(root, '2026.07.30-1100');
  fs.mkdirSync(pending);
  fs.writeFileSync(path.join(pending, 'meta.json'), '{}');

  assert.equal(resolveSession(root).name, '2026.07.30-1000');
  const listed = listSessions(root);
  assert.deepEqual(listed.map((session) => session.name), [
    '2026.07.30-1100', '2026.07.30-1000', '2026.07.30-0900',
  ]);
  assert.equal(listed[0].status, 'pending');
});

test('app-authored handoff is staged verbatim and only local git excludes change', (t) => {
  const root = temporaryDirectory(t);
  const sessionDir = writeSession(root, '2026.07.30-1000');
  fs.writeFileSync(path.join(sessionDir, 'handoff.md'), '# canonical handoff\n');
  const repo = temporaryDirectory(t);
  spawnSync('git', ['init', '-q', repo], { stdio: 'ignore' });
  fs.writeFileSync(path.join(repo, '.gitignore'), 'node_modules/\n');

  const output = stageSession(resolveSession(root), repo);
  assert.equal(fs.readFileSync(output, 'utf8'), '# canonical handoff\n');
  assert.equal(fs.readFileSync(path.join(repo, '.gitignore'), 'utf8'), 'node_modules/\n');
  assert.match(fs.readFileSync(path.join(repo, '.git', 'info', 'exclude'), 'utf8'), /^\.meeting\/$/m);
});

test('old sessions get a self-contained fallback handoff', (t) => {
  const root = temporaryDirectory(t);
  writeSession(root, '2026.07.30-1000');
  const session = resolveSession(root);
  assert.match(session.document, /^# Meeting handoff/m);
  assert.match(session.document, /## Instructions/);
  assert.match(session.document, /Ship the command line split/);
});

test('a session from another recorder reads through the same contract', (t) => {
  const root = temporaryDirectory(t);
  const dir = path.join(root, '2026.08.03-1400');
  fs.mkdirSync(dir, { recursive: true });
  // A Windows recorder writes MP4 rather than CAF, names the tracks in the
  // `files` map, and ends its lines with CRLF. None of that reaches the
  // public contract, so every one of these assertions must hold.
  fs.writeFileSync(
    path.join(dir, 'transcript.md'),
    '# 2026.08.03-1400\r\n\r\nengine: test\r\n\r\n**[0:01] me:** Ship the Windows recorder.\r\n',
  );
  fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify({
    duration_seconds: 92,
    clean_stop: true,
    name: 'Windows port kickoff',
    files: { mic: 'mic.m4a', system: 'system.m4a' },
  }));
  fs.writeFileSync(path.join(dir, 'mic.m4a'), '');
  fs.writeFileSync(path.join(dir, 'system.m4a'), '');

  const session = resolveSession(root);
  // The directory stays the identifier, and the name is what a reader sees.
  assert.equal(session.name, '2026.08.03-1400');
  assert.equal(session.title, 'Windows port kickoff');
  assert.equal(session.duration, '1m32s');
  assert.equal(session.segments, 1);
  assert.match(session.document, /^# Meeting handoff: Windows port kickoff$/m);
  assert.match(session.document, /Ship the Windows recorder/);
  assert.deepEqual(listSessions(root).map((entry) => entry.status), ['ready']);
});

test('arbitrary transcript files work without the macOS app', (t) => {
  const dir = temporaryDirectory(t);
  const file = path.join(dir, 'planning notes.txt');
  fs.writeFileSync(file, 'We should separate the app and command line client.');
  const transcript = readExternalTranscript(file);
  assert.equal(transcript.name, 'planning-notes');
  assert.match(transcript.document, /separate the app and command line client/);
});

test('published executable stages a file without running an agent', (t) => {
  const dir = temporaryDirectory(t);
  const repo = path.join(dir, 'repo');
  fs.mkdirSync(repo);
  const transcript = path.join(dir, 'meeting.md');
  fs.writeFileSync(transcript, 'Move the command-line client into its own package boundary.');
  const bin = path.join(__dirname, '..', 'bin', 'patchthrough.js');
  const result = spawnSync(
    process.execPath,
    [bin, 'hand', '--file', transcript, '--dir', repo, '--no-launch'],
    { encoding: 'utf8' },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /staged .*\.meeting[\\/]meeting\.md/);
  assert.match(result.stdout, /Read \.meeting[\\/]meeting\.md/);
  assert.match(
    fs.readFileSync(path.join(repo, '.meeting', 'meeting.md'), 'utf8'),
    /command-line client into its own package boundary/,
  );
});
