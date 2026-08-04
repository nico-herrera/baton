#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const {
  KNOWN_AGENTS,
  handToWeb,
  installedAgents,
  launchAgent,
  listSessions,
  promptFor,
  readExternalTranscript,
  resolveRecordingsRoot,
  resolveSession,
  stageSession,
  webPrompt,
  webTargets,
  writeHandoffFile,
} = require('../src/patchthrough');
const packageJson = require('../package.json');

const HELP = `Patchthrough CLI ${packageJson.version}

Hand meeting transcripts to coding agents. The native macOS recorder is a
separate download from GitHub; this npm package never installs or launches it.

Usage:
  patchthrough hand [agent] [options]
  patchthrough transcripts [--recordings-dir <path>]
  patchthrough doctor [--recordings-dir <path>]

Hand options:
  -s, --session <name>       recorded session (default: newest)
  -f, --file <path|->        any transcript file, or - for stdin
  -d, --dir <repository>     repository to stage into (default: current)
  -n, --no-launch            stage and print the prompt without launching
  -w, --web <site>           open a chat website instead of a terminal agent
      --recordings-dir <dir> override the app's recordings directory

Agents:
  ${Object.keys(KNOWN_AGENTS).join(', ')}

Web sites (macOS and Windows, with --web):
  ${Object.keys(webTargets()).join(', ')}

A web handoff puts handoff.md on the clipboard as a file and opens the site.
One paste (⌘V on macOS, Ctrl+V on Windows) attaches the transcript.
`;

const PASTE_KEY = process.platform === 'win32' ? 'Ctrl+V' : '⌘V';

function parse(argv) {
  const options = {};
  const positional = [];
  const values = new Map([
    ['-s', 'session'], ['--session', 'session'],
    ['-f', 'file'], ['--file', 'file'],
    ['-d', 'dir'], ['--dir', 'dir'],
    ['-w', 'web'], ['--web', 'web'],
    ['--recordings-dir', 'recordingsDir'],
  ]);
  const booleans = new Map([
    ['-n', 'noLaunch'], ['--no-launch', 'noLaunch'],
    ['-h', 'help'], ['--help', 'help'],
    ['-v', 'version'], ['--version', 'version'],
  ]);

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--') {
      positional.push(...argv.slice(i + 1));
      break;
    }
    if (booleans.has(arg)) {
      options[booleans.get(arg)] = true;
      continue;
    }
    const equal = arg.startsWith('--') ? arg.indexOf('=') : -1;
    const flag = equal > 0 ? arg.slice(0, equal) : arg;
    if (values.has(flag)) {
      const value = equal > 0 ? arg.slice(equal + 1) : argv[++i];
      if (!value) throw new Error(`${flag} requires a value`);
      options[values.get(flag)] = value;
      continue;
    }
    if (arg.startsWith('-')) throw new Error(`unknown option ${arg}`);
    positional.push(arg);
  }
  return { options, positional };
}

function printAgents() {
  const found = installedAgents();
  console.log('terminal agents installed here:');
  if (found.length === 0) console.log('  (none found)');
  for (const agent of found) console.log(`  ${agent.name}  →  ${agent.path}`);
}

function printSessions(root) {
  const sessions = listSessions(root);
  if (sessions.length === 0) {
    console.log(`no sessions in ${root}`);
    return;
  }
  const row = (a, b, c) => `${a.padEnd(22)}${b.padEnd(10)}${c}`;
  console.log(row('SESSION', 'LENGTH', 'OPENS WITH'));
  for (const session of sessions) {
    console.log(row(session.name, session.duration, session.opensWith));
  }
}

// The clipboard tools a Windows web handoff needs. A missing tool means the
// handoff falls back to a drag, so report the tools rather than fail later.
function windowsClipboardLine() {
  const system32 = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32');
  const tools = [
    path.join(system32, 'clip.exe'),
    path.join(system32, 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
  ];
  const missing = tools.filter((tool) => !fs.existsSync(tool)).map((tool) => path.basename(tool));
  return missing.length === 0
    ? '✓ clipboard   clip.exe and powershell.exe found'
    : `○ clipboard   missing ${missing.join(', ')}`;
}

function doctor(root) {
  console.log(`${fs.existsSync(root) ? '✓' : '○'} recordings  ${root}`);
  if (process.platform === 'darwin') {
    const app = [
      path.join(require('os').homedir(), 'Applications', 'patchthrough.app'),
      '/Applications/patchthrough.app',
    ].find((candidate) => fs.existsSync(candidate));
    console.log(`${app ? '✓' : '○'} macOS app   ${app || 'not installed (optional for file/stdin handoffs)'}`);
  } else {
    console.log('○ macOS app   macOS only. Use --file or stdin on this machine');
  }
  const agents = installedAgents();
  console.log(`${agents.length ? '✓' : '○'} agents      ${agents.map((agent) => agent.name).join(', ') || 'none found'}`);
  if (process.platform === 'win32') console.log(windowsClipboardLine());
}

function main() {
  const { options, positional } = parse(process.argv.slice(2));
  if (options.version) {
    console.log(packageJson.version);
    return 0;
  }
  if (options.help || positional.length === 0) {
    console.log(HELP);
    return 0;
  }

  const command = positional[0];
  const root = resolveRecordingsRoot(options.recordingsDir);
  if (command === 'transcripts') {
    if (positional.length > 1) throw new Error('transcripts takes no positional arguments');
    printSessions(root);
    return 0;
  }
  if (command === 'doctor') {
    if (positional.length > 1) throw new Error('doctor takes no positional arguments');
    doctor(root);
    return 0;
  }
  if (command !== 'hand') throw new Error(`unknown command '${command}'`);
  if (options.file && options.session) throw new Error('use either --file or --session, not both');
  if (positional.length > 2) throw new Error('hand accepts at most one agent');

  const agent = positional[1];
  if (options.web && agent) {
    throw new Error('use either --web or an agent, not both');
  }
  if (!agent && !options.web && !options.noLaunch) {
    printAgents();
    console.log('\nusage: patchthrough hand <agent> [options]');
    console.log(`       patchthrough hand --web <${Object.keys(webTargets()).join('|')}>`);
    return 0;
  }
  if (agent && !KNOWN_AGENTS[agent]) {
    throw new Error(`unknown agent '${agent}'; expected ${Object.keys(KNOWN_AGENTS).join(', ')}`);
  }

  const session = options.file
    ? readExternalTranscript(options.file)
    : resolveSession(root, options.session);

  // A web handoff needs no repository: the transcript rides on the clipboard
  // as a file, and handoff.md carries the instructions.
  if (options.web) {
    const targets = webTargets();
    const site = targets[options.web];
    if (!site) {
      throw new Error(`unknown web target '${options.web}'; expected ${Object.keys(targets).join(', ')}`);
    }
    if (site.uploadsToCloud) {
      process.stderr.write(
        `⚠ ${site.label} copies an attached file to your work OneDrive, so this transcript leaves this machine\n`
      );
    }
    if (options.noLaunch) {
      const file = writeHandoffFile(session);
      process.stderr.write(`wrote ${file}\n`);
      console.log(`\n${webPrompt(session)}`);
      return 0;
    }
    const result = handToWeb(site, session, { targets });
    process.stderr.write(`→ ${site.label}\n`);
    if (result.attached) {
      if (!result.pasted) {
        process.stderr.write(`the transcript is on your clipboard as a file. Press ${PASTE_KEY} in the page to attach it\n`);
      }
    } else if (result.copiedText) {
      process.stderr.write(`could not copy the file reference. The full handoff is on your clipboard as text. Press ${PASTE_KEY} in the page to paste it\n`);
    } else {
      process.stderr.write(`could not put ${result.file} on the clipboard. Drag it into the page instead\n`);
    }
    return 0;
  }

  const repo = path.resolve(options.dir || process.cwd());
  const staged = stageSession(session, repo);
  const prompt = promptFor(session, staged);
  process.stderr.write(`staged ${staged} (${session.words} words)\n`);

  if (options.noLaunch) {
    console.log(`\n${prompt}`);
    return 0;
  }
  return launchAgent(agent, prompt, repo);
}

try {
  process.exitCode = main();
} catch (error) {
  process.stderr.write(`patchthrough: ${error.message}\n`);
  process.exitCode = 1;
}
