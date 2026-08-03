'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const {
  copyFileToClipboard,
  copyToClipboard,
  handToWeb,
  launchAgent,
} = require('../src/patchthrough');

function temporaryDirectory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'patchthrough-platform-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// Records every spawn and answers with the status the test asks for. The
// platform also comes from the test, so a Mac runs the Windows paths.
function fakeSpawn(statusFor = () => 0) {
  const calls = [];
  const spawn = (command, args, options) => {
    calls.push({ command, args, options });
    return { status: statusFor(command, args, options) };
  };
  spawn.calls = calls;
  return spawn;
}

function decodedScript(call) {
  const index = (call.args || []).indexOf('-EncodedCommand');
  return index < 0 ? '' : Buffer.from(call.args[index + 1], 'base64').toString('utf16le');
}

function pastedText(call) {
  return call.options.input.slice(2).toString('utf16le');
}

function fakeSession(dir) {
  return {
    dir,
    name: '2026.07.30-1000',
    sourcePath: dir,
    transcript: '**[0:01] me:** Ship the Windows build.\n',
    document: '# Meeting handoff: 2026.07.30-1000\n\nShip the Windows build.\n',
    duration: '1m05s',
    cleanStop: true,
  };
}

test('a Windows text copy declares UTF-16LE, so accents survive the console codepage', () => {
  const spawn = fakeSpawn();
  const text = 'Héllo, ✓ dôné';
  assert.equal(copyToClipboard(text, { platform: 'win32', spawn }), true);
  assert.equal(spawn.calls.length, 1);
  const [call] = spawn.calls;
  assert.match(call.command, /clip\.exe$/);
  assert.deepEqual([...call.options.input.slice(0, 2)], [0xff, 0xfe]);
  assert.equal(pastedText(call), text);
});

test('a Windows text copy reports the failure of clip.exe', () => {
  const spawn = fakeSpawn(() => 1);
  assert.equal(copyToClipboard('notes', { platform: 'win32', spawn }), false);
});

test('a macOS text copy still goes through pbcopy', () => {
  const spawn = fakeSpawn();
  assert.equal(copyToClipboard('notes', { platform: 'darwin', spawn }), true);
  assert.equal(spawn.calls[0].command, '/usr/bin/pbcopy');
  assert.equal(spawn.calls[0].options.input, 'notes');
});

test('a platform with no clipboard tool reports failure and spawns nothing', () => {
  const spawn = fakeSpawn();
  assert.equal(copyToClipboard('notes', { platform: 'linux', spawn }), false);
  assert.equal(spawn.calls.length, 0);
});

test('a Windows file copy sends the path through the environment, never through the script', (t) => {
  const dir = temporaryDirectory(t);
  const file = path.join(dir, 'handoff.md');
  fs.writeFileSync(file, '# handoff\n');
  const spawn = fakeSpawn();

  assert.equal(copyFileToClipboard(file, { platform: 'win32', spawn }), true);
  const [call] = spawn.calls;
  assert.match(call.command, /powershell\.exe$/);
  const script = decodedScript(call);
  assert.match(script, /SetFileDropList/);
  assert.match(script, /ContainsFileDropList/);
  assert.match(script, /\$env:PATCHTHROUGH_CLIP_FILE/);
  assert.equal(call.options.env.PATCHTHROUGH_CLIP_FILE, file);
  assert.doesNotMatch(script, /handoff\.md/);
});

test('a Windows file copy refuses a path that does not exist', (t) => {
  const dir = temporaryDirectory(t);
  const spawn = fakeSpawn();
  assert.equal(copyFileToClipboard(path.join(dir, 'missing.md'), { platform: 'win32', spawn }), false);
  assert.equal(spawn.calls.length, 0);
});

test('a Windows web handoff attaches the file and leaves the paste to the user', (t) => {
  const dir = temporaryDirectory(t);
  const spawn = fakeSpawn();

  const result = handToWeb('claude', fakeSession(dir), { platform: 'win32', spawn });
  assert.equal(result.attached, true);
  assert.equal(result.copiedText, false);
  assert.equal(result.pasted, false);
  const opened = spawn.calls.find((call) => decodedScript(call).includes('Start-Process'));
  assert.match(opened.options.env.PATCHTHROUGH_URL, /^https:\/\/claude\.ai\/new\?q=/);
  assert.doesNotMatch(decodedScript(opened), /claude\.ai/);
});

test('a failed Windows file copy sends the handoff text and opens a plain chat', (t) => {
  const dir = temporaryDirectory(t);
  const session = fakeSession(dir);
  // Fail the file drop only. That is what a session with no interactive
  // desktop does, and the prefilled prompt then names a file nobody sent.
  const spawn = fakeSpawn((command, args) => (
    decodedScript({ args }).includes('SetFileDropList') ? 1 : 0
  ));

  const result = handToWeb('claude', session, { platform: 'win32', spawn });
  assert.equal(result.attached, false);
  assert.equal(result.copiedText, true);
  const copy = spawn.calls.find((call) => /clip\.exe$/.test(call.command));
  assert.equal(pastedText(copy), session.document);
  const opened = spawn.calls.find((call) => decodedScript(call).includes('Start-Process'));
  assert.equal(opened.options.env.PATCHTHROUGH_URL, 'https://claude.ai/new');
});

test('a destination from the config reaches the same Windows path', (t) => {
  const dir = temporaryDirectory(t);
  // A user-defined site can already carry a query string. The prompt has to
  // join that query rather than replace it.
  const targets = {
    internal: {
      label: 'Internal tool',
      newChatURL: 'https://tool.example.com/chat?team=eng',
      prefillsPrompt: true,
      uploadsToCloud: false,
      isCustom: true,
    },
  };
  const spawn = fakeSpawn();

  const result = handToWeb('internal', fakeSession(dir), { platform: 'win32', spawn, targets });
  assert.equal(result.attached, true);
  const opened = spawn.calls.find((call) => decodedScript(call).includes('Start-Process'));
  const url = new URL(opened.options.env.PATCHTHROUGH_URL);
  assert.equal(url.searchParams.get('team'), 'eng');
  assert.match(url.searchParams.get('q'), /transcript of a meeting/);
});

test('a web handoff still refuses a platform with no system clipboard', (t) => {
  const dir = temporaryDirectory(t);
  const spawn = fakeSpawn();
  assert.throws(
    () => handToWeb('claude', fakeSession(dir), { platform: 'linux', spawn }),
    /macOS or Windows/,
  );
  assert.equal(spawn.calls.length, 0);
});

test('a Windows shim agent gets the prompt on the clipboard, never on a command line', (t) => {
  const dir = temporaryDirectory(t);
  const shim = path.join(dir, 'claude.CMD');
  fs.writeFileSync(shim, '@echo off\n');
  // cmd.exe reads this newline as the end of the command, which is why the
  // prompt has to travel on the clipboard.
  const prompt = 'Read .meeting/meeting.md.\n\nThen tell me what it asks of this codebase.';
  const spawn = fakeSpawn();

  const status = launchAgent('claude', prompt, dir, { PATH: dir, PATHEXT: '.CMD' }, { platform: 'win32', spawn });
  assert.equal(status, 0);
  const copy = spawn.calls.find((call) => /clip\.exe$/.test(call.command));
  assert.equal(pastedText(copy), prompt);
  const launch = spawn.calls.find((call) => call.command.includes('claude.CMD'));
  assert.equal(launch.command, `"${shim}"`);
  assert.deepEqual(launch.args, []);
  assert.equal(launch.options.shell, true);
  for (const call of spawn.calls) {
    const argv = (call.args || []).map(String);
    assert.ok(!argv.some((arg) => arg.includes('meeting.md')), 'the prompt must stay off every command line');
  }
});

test('a Windows native agent still takes the prompt as one argument', (t) => {
  const dir = temporaryDirectory(t);
  fs.writeFileSync(path.join(dir, 'codex.EXE'), '');
  const prompt = 'Read .meeting/meeting.md.';
  const spawn = fakeSpawn();

  launchAgent('codex', prompt, dir, { PATH: dir, PATHEXT: '.EXE' }, { platform: 'win32', spawn });
  assert.equal(spawn.calls.length, 1);
  assert.deepEqual(spawn.calls[0].args, [prompt]);
  assert.equal(spawn.calls[0].options.shell, undefined);
});
