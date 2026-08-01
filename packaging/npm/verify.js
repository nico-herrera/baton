#!/usr/bin/env node
'use strict';

// Keep the npm package, release tag, asset name, and pinned checksum as one
// contract. `npm pack` runs the local checks; `npm publish` additionally
// downloads the public release asset and verifies its bytes.

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');

const packageJson = require('./package.json');
const artifact = require('./artifact.json');

function fail(message) {
  console.error(`patchthrough package check failed: ${message}`);
  process.exit(1);
}

function expect(condition, message) {
  if (!condition) fail(message);
}

const versionPattern = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
expect(versionPattern.test(packageJson.version), `invalid package version ${packageJson.version}`);
expect(artifact.version === packageJson.version,
  `artifact version ${artifact.version} does not match package version ${packageJson.version}`);
expect(artifact.tag === `v${packageJson.version}`,
  `artifact tag must be v${packageJson.version}, got ${artifact.tag}`);
expect(artifact.file === `patchthrough-${packageJson.version}-darwin-arm64.tar.gz`,
  `artifact filename does not match package version: ${artifact.file}`);
expect(/^[a-f0-9]{64}$/.test(artifact.sha256), 'artifact sha256 must be 64 lowercase hex characters');
expect(/^[A-Z0-9]{10}$/.test(artifact.teamId), 'artifact Team ID must be 10 uppercase letters or digits');

const repositoryUrl = packageJson.repository && packageJson.repository.url;
expect(typeof repositoryUrl === 'string' && repositoryUrl.includes(`${artifact.repo}.git`),
  `package repository does not match artifact repo ${artifact.repo}`);

// The package README intentionally mirrors the repository README. Catch stale
// install commands before they ship, while still allowing this verifier to run
// from an already-installed npm package where the repository README is absent.
const repositoryReadme = path.resolve(__dirname, '..', '..', 'README.md');
if (fs.existsSync(repositoryReadme)) {
  const packageReadme = path.join(__dirname, 'README.md');
  expect(fs.readFileSync(packageReadme, 'utf8') === fs.readFileSync(repositoryReadme, 'utf8'),
    'packaging/npm/README.md is out of sync with the repository README.md');
}

function download(from, redirects = 0) {
  if (redirects > 5) return Promise.reject(new Error('too many redirects'));
  return new Promise((resolve, reject) => {
    https.get(from, { headers: { 'User-Agent': 'patchthrough-npm-verify' } }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
        res.resume();
        const location = res.headers.location;
        if (!location) return reject(new Error(`HTTP ${res.statusCode} without a redirect location`));
        const next = new URL(location, from);
        if (next.protocol !== 'https:') return reject(new Error(`refusing non-HTTPS redirect to ${next}`));
        return download(next.toString(), redirects + 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} for ${from}`));
      }
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    }).on('error', reject);
  });
}

async function verifyRelease() {
  const url = `https://github.com/${artifact.repo}/releases/download/${artifact.tag}/${artifact.file}`;
  const bytes = await download(url);
  const actual = crypto.createHash('sha256').update(bytes).digest('hex');
  expect(actual === artifact.sha256,
    `release checksum mismatch: expected ${artifact.sha256}, got ${actual}`);
  console.log(`verified ${artifact.tag}/${artifact.file} (${actual})`);
}

console.log(`verified package metadata for patchthrough ${packageJson.version}`);
if (process.argv.includes('--release')) {
  verifyRelease().catch((error) => fail(`could not verify release: ${error.message}`));
}
