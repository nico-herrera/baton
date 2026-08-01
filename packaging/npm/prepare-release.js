#!/usr/bin/env node
'use strict';

// Called by make-dist.sh after it has built and hashed the signed app archive.
// Updating both npm metadata files together prevents a release asset and npm
// version from drifting apart.

const fs = require('fs');
const path = require('path');

const [version, sha256] = process.argv.slice(2);
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version || '')) {
  console.error('usage: prepare-release.js <semver> <sha256>');
  process.exit(1);
}
if (!/^[a-f0-9]{64}$/.test(sha256 || '')) {
  console.error('prepare-release.js: sha256 must be 64 lowercase hex characters');
  process.exit(1);
}

const packagePath = path.join(__dirname, 'package.json');
const artifactPath = path.join(__dirname, 'artifact.json');
const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const previousArtifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));

packageJson.version = version;
const artifact = {
  version,
  repo: previousArtifact.repo,
  tag: `v${version}`,
  file: `patchthrough-${version}-darwin-arm64.tar.gz`,
  sha256,
  teamId: previousArtifact.teamId
};

fs.writeFileSync(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);
fs.writeFileSync(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`);
console.log(`wired npm package ${version} to ${artifact.tag}/${artifact.file}`);
