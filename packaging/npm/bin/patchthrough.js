#!/usr/bin/env node
'use strict';

// Thin shim: exec the binary inside the installed app bundle, so the CLI and
// the menu-bar GUI are always literally the same build. execv-style handoff
// means signals, exit codes and the TTY all pass through untouched — which
// matters because `patchthrough hand claude` replaces itself with the agent.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const candidates = [
  path.join(os.homedir(), 'Applications/patchthrough.app/Contents/MacOS/patchthrough'),
  '/Applications/patchthrough.app/Contents/MacOS/patchthrough',
];

const bin = candidates.find((p) => {
  try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; }
});

if (!bin) {
  console.error(
    '\x1b[31mPatchthrough is not installed.\x1b[0m\n\n' +
    'The app bundle should be at one of:\n' +
    candidates.map((c) => `  ${c}`).join('\n') + '\n\n' +
    'If you installed with --ignore-scripts (which is a reasonable thing to\n' +
    'do), finish the install now:\n\n' +
    '  patchthrough-setup\n'
  );
  process.exit(1);
}

const r = spawnSync(bin, process.argv.slice(2), { stdio: 'inherit' });
if (r.error) {
  console.error(`\x1b[31mFailed to launch ${bin}: ${r.error.message}\x1b[0m`);
  process.exit(1);
}
// Preserve signal-death as a shell would report it.
if (r.signal) process.kill(process.pid, r.signal);
process.exit(r.status === null ? 1 : r.status);
