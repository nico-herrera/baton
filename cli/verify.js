#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const packageJson = require('./package.json');

function expect(condition, message) {
  if (!condition) {
    console.error(`patchthrough CLI check failed: ${message}`);
    process.exit(1);
  }
}

expect(packageJson.name === 'patchthrough', 'package name changed');
expect(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(packageJson.version), 'invalid semver');
expect(Number(packageJson.version.split('.')[0]) >= 2, 'the standalone CLI begins at major version 2');
expect(!packageJson.scripts.postinstall, 'the standalone CLI must not use postinstall');
expect(!packageJson.os && !packageJson.cpu, 'the transcript CLI must remain cross-platform');
expect(packageJson.bin.patchthrough === 'bin/patchthrough.js', 'missing patchthrough executable');
expect(packageJson.repository.directory === 'cli', 'repository directory must point at cli');

const executable = path.join(__dirname, packageJson.bin.patchthrough);
expect(fs.existsSync(executable), `missing ${packageJson.bin.patchthrough}`);
expect((fs.statSync(executable).mode & 0o111) !== 0, `${packageJson.bin.patchthrough} is not executable`);
expect(fs.existsSync(path.join(__dirname, 'README.md')), 'missing CLI README');
expect(fs.existsSync(path.join(__dirname, 'LICENSE')), 'missing CLI license');

console.log(`verified standalone patchthrough CLI ${packageJson.version}`);
