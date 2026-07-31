#!/usr/bin/env node
'use strict';

// Postinstall: fetch the signed Patchthrough.app from its GitHub release and
// install it to ~/Applications.
//
// SUPPLY-CHAIN POSTURE — deliberate, not default:
//
//   · The release tag and the artifact's SHA-256 are PINNED in artifact.json,
//     which ships inside this package. Nothing resolves "latest"; a given
//     version of this package can only ever install one exact byte sequence.
//   · After download we verify the hash, and then verify macOS's own code
//     signature and Team ID. The hash proves integrity; the signature proves
//     provenance — a chain that whoever serves the bytes cannot forge. Most
//     npm-wrapped binaries check only a hash, if that.
//   · Any failure aborts and leaves nothing behind. There is no "continue
//     anyway" path.
//   · No network access beyond the one pinned GitHub release URL.
//
// If you'd rather not run install scripts at all (reasonable), use
// `npm i -g patchthrough --ignore-scripts` — the bin wrapper will then tell
// you to run `patchthrough-setup` yourself.

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const { execFileSync, spawnSync } = require('child_process');
const crypto = require('crypto');

const artifact = require('./artifact.json');

const RED = '\x1b[31m', BOLD = '\x1b[1m', DIM = '\x1b[2m', RESET = '\x1b[0m';
const say = (m) => console.log(`${BOLD}${m}${RESET}`);
const dim = (m) => console.log(`${DIM}${m}${RESET}`);
function bail(msg) {
  console.error(`\n${RED}${msg}${RESET}\n`);
  process.exit(1);
}

// --- platform gate ---------------------------------------------------------

if (process.platform !== 'darwin') {
  bail(
    'Patchthrough is macOS-only.\n\n' +
    'It records system audio through Core Audio process taps and transcribes on\n' +
    `the Apple Neural Engine — neither exists on ${process.platform}.`
  );
}
if (process.arch !== 'arm64') {
  bail(
    `Patchthrough requires Apple Silicon (arm64); this is ${process.arch}.\n\n` +
    "Transcription runs on the Neural Engine, which Intel Macs don't have."
  );
}
const darwinMajor = Number(os.release().split('.')[0]);
if (darwinMajor && darwinMajor < 24) {   // Darwin 24 = macOS 15
  bail(
    'Patchthrough needs macOS 15 or newer.\n\n' +
    'System-audio capture uses Core Audio process taps.'
  );
}

// --- download --------------------------------------------------------------

const url =
  `https://github.com/${artifact.repo}/releases/download/` +
  `${artifact.tag}/${artifact.file}`;

function download(from, redirects = 0) {
  if (redirects > 5) return Promise.reject(new Error('too many redirects'));
  return new Promise((resolve, reject) => {
    https.get(from, { headers: { 'User-Agent': 'patchthrough-npm' } }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
        res.resume();
        return download(res.headers.location, redirects + 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} for ${from}`));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    }).on('error', reject);
  });
}

async function main() {
  say(`Patchthrough ${artifact.version} — installing for macOS arm64`);
  dim(`  ${url}`);

  let buf;
  try {
    buf = await download(url);
  } catch (e) {
    bail(
      `Download failed: ${e.message}\n\n` +
      `Expected the release artifact at:\n  ${url}\n\n` +
      'If you are offline or behind a proxy, build from source instead:\n' +
      `  git clone https://github.com/${artifact.repo} && cd patchthrough && ./packaging/make-app.sh`
    );
  }

  // 1. Integrity — the exact bytes this package version pins.
  const got = crypto.createHash('sha256').update(buf).digest('hex');
  if (got !== artifact.sha256) {
    bail(
      'CHECKSUM MISMATCH — refusing to install.\n\n' +
      `  expected  ${artifact.sha256}\n` +
      `  got       ${got}\n\n` +
      'The bytes served do not match what this package pins: a corrupted\n' +
      'download, or a tampered release. Nothing was installed.'
    );
  }
  dim(`  ✓ sha256 ${got.slice(0, 16)}…`);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'patchthrough-'));
  const tgz = path.join(tmp, artifact.file);
  fs.writeFileSync(tgz, buf);
  try {
    execFileSync('/usr/bin/tar', ['-xzf', tgz, '-C', tmp]);
  } catch (e) {
    fs.rmSync(tmp, { recursive: true, force: true });
    bail(`Failed to unpack the archive: ${e.message}`);
  }
  const app = path.join(tmp, 'patchthrough.app');
  if (!fs.existsSync(app)) {
    fs.rmSync(tmp, { recursive: true, force: true });
    bail('Archive did not contain patchthrough.app');
  }

  // 2. Provenance — let macOS verify Apple's signing chain.
  const verify = spawnSync('/usr/bin/codesign', ['--verify', '--strict', app]);
  if (verify.status !== 0) {
    fs.rmSync(tmp, { recursive: true, force: true });
    bail(
      'CODE SIGNATURE INVALID — refusing to install.\n\n' +
      `${(verify.stderr || '').toString().trim()}\n\n` +
      'Nothing was installed.'
    );
  }
  const info = spawnSync('/usr/bin/codesign', ['-dvv', app], { encoding: 'utf8' });
  const m = /TeamIdentifier=(\S+)/.exec(info.stderr || '');
  const team = m && m[1];
  if (team !== artifact.teamId) {
    fs.rmSync(tmp, { recursive: true, force: true });
    bail(
      'UNEXPECTED SIGNER — refusing to install.\n\n' +
      `  expected Team ID  ${artifact.teamId}\n` +
      `  got               ${team || '(unsigned)'}\n\n` +
      'Nothing was installed.'
    );
  }
  dim(`  ✓ signed by Team ${team}`);

  // --- install ---------------------------------------------------------------

  // ~/Applications, not /Applications: user-owned, so no sudo and no password
  // prompt on every update.
  const dest = path.join(os.homedir(), 'Applications');
  fs.mkdirSync(dest, { recursive: true });
  const installed = path.join(dest, 'patchthrough.app');

  // Stop a running daemon rather than overwrite a live binary.
  spawnSync('/bin/launchctl',
            ['bootout', `gui/${process.getuid()}/com.nicoherrera.patchthrough`],
            { stdio: 'ignore' });

  fs.rmSync(installed, { recursive: true, force: true });
  execFileSync('/bin/cp', ['-R', app, dest]);
  fs.rmSync(tmp, { recursive: true, force: true });

  // Signed but not notarized, so Gatekeeper would block first launch. The
  // signature was verified above, which is the check that actually matters.
  spawnSync('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', installed], { stdio: 'ignore' });

  say(`  ✓ installed → ${installed}`);
  console.log('');
  say('Next:');
  console.log('  patchthrough install --launch-at-login   # run in the menu bar from login');
  console.log('  patchthrough doctor                      # check permissions and models');
  console.log('');
  dim('  First recording prompts for Microphone and Screen & System Audio Recording.');
  dim('  Models (~600 MB) download on first transcription — record a short test');
  dim('  session while online before a real meeting.');
}

main().catch((e) => bail(`Unexpected failure: ${e.stack || e.message}`));
