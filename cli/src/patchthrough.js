'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const KNOWN_AGENTS = Object.freeze({
  claude: { style: 'prompt' },
  copilot: { style: 'prompt' },
  codex: { style: 'prompt' },
  'cursor-agent': { style: 'prompt' },
  opencode: { style: 'run' },
  kimi: { style: 'clipboard' },
});

function expandHome(value, home = os.homedir()) {
  if (value === '~') return home;
  if (value.startsWith('~/') || value.startsWith('~\\')) {
    return path.join(home, value.slice(2));
  }
  return path.resolve(value);
}

function readConfig(configPath = path.join(os.homedir(), '.config', 'patchthrough', 'config.json')) {
  if (!fs.existsSync(configPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot parse ${configPath}: ${error.message}`);
  }
}

function resolveRecordingsRoot(override, options = {}) {
  const home = options.home || os.homedir();
  if (override) return expandHome(override, home);
  const configPath = options.configPath || path.join(home, '.config', 'patchthrough', 'config.json');
  const configured = readConfig(configPath).recordings_dir;
  return configured ? expandHome(configured, home) : path.join(home, 'Recordings');
}

function segmentLines(transcript) {
  return transcript.split(/\r?\n/).filter((line) => /^\*\*\[[^\]]+\]\s+[^:]+:\*\*/.test(line));
}

function spokenText(line) {
  const match = line.match(/^\*\*\[[^\]]+\]\s+[^:]+:\*\*\s*(.*)$/);
  return match ? match[1] : line;
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds)) return 'unknown';
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
    : `${minutes}m${String(secs).padStart(2, '0')}s`;
}

function taskInstructions() {
  return `Read the transcript below and work out what this meeting asks of me. Before changing anything, give me:

1. Concrete work items it implies, ordered by what should happen first.
2. Anything stated as a decision or constraint I shouldn't relitigate.
3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.
4. Anything discussed that the current project may already do or contradict.

It's speech-to-text, so it's messy: unreliable punctuation, garbled technical terms, and possibly incorrect speaker labels. Read for intent, not literal wording. Don't edit anything until we've agreed the list.`;
}

function buildHandoffDocument(session) {
  const lines = session.transcript.split(/\r?\n/);
  const firstSegment = lines.findIndex((line) => /^\*\*\[/.test(line));
  const body = (firstSegment >= 0 ? lines.slice(firstSegment) : lines).join('\n').trim();
  const truncation = session.cleanStop === false
    ? ' (recording ended uncleanly, so the transcript may be truncated)'
    : '';
  return `# Meeting handoff: ${session.name}

## Instructions

${taskInstructions()}

## Recording

- Duration: ${session.duration}${truncation}
- Speakers: \`me\` normally means this machine's microphone; \`them\` normally means the audio the machine played. Treat these as channels, not verified identities.
- Transcribed on-device. **Expect transcription errors**, especially in proper nouns, identifiers, and technical terms.
- Source: \`${session.sourcePath}\`

## Transcript

${body}
`;
}

function readMeta(sessionDir) {
  const metaPath = path.join(sessionDir, 'meta.json');
  if (!fs.existsSync(metaPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(metaPath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot parse ${metaPath}: ${error.message}`);
  }
}

function readSession(sessionDir) {
  const transcriptPath = path.join(sessionDir, 'transcript.md');
  if (!fs.existsSync(transcriptPath)) {
    throw new Error(`session '${path.basename(sessionDir)}' has no transcript yet`);
  }
  const transcript = fs.readFileSync(transcriptPath, 'utf8');
  const segments = segmentLines(transcript);
  if (segments.length === 0) {
    throw new Error(`session '${path.basename(sessionDir)}' has an empty transcript`);
  }
  const meta = readMeta(sessionDir);
  const session = {
    dir: sessionDir,
    name: path.basename(sessionDir),
    sourcePath: sessionDir,
    transcript,
    segments: segments.length,
    words: segments.flatMap((line) => spokenText(line).split(/\s+/).filter(Boolean)).length,
    duration: formatDuration(Number(meta.duration_seconds)),
    cleanStop: meta.clean_stop !== false,
  };
  const handoffPath = path.join(sessionDir, 'handoff.md');
  session.document = fs.existsSync(handoffPath)
    ? fs.readFileSync(handoffPath, 'utf8')
    : buildHandoffDocument(session);
  return session;
}

function safeSessionName(name) {
  if (!name || name === '.' || name === '..' || name.includes('/') || name.includes('\\')) {
    throw new Error(`invalid session name '${name}'`);
  }
  return name;
}

function resolveSession(root, requested) {
  if (requested) {
    const name = safeSessionName(requested);
    const sessionDir = path.join(root, name);
    if (!fs.existsSync(sessionDir)) throw new Error(`no session '${name}' in ${root}`);
    return readSession(sessionDir);
  }

  if (!fs.existsSync(root)) throw new Error(`no recordings directory at ${root}`);
  const candidates = fs.readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && fs.existsSync(path.join(root, entry.name, 'transcript.md')))
    .map((entry) => entry.name)
    .sort((a, b) => b.localeCompare(a));
  if (candidates.length === 0) throw new Error(`no transcribed sessions in ${root}`);
  return readSession(path.join(root, candidates[0]));
}

function readExternalTranscript(file) {
  const transcript = file === '-'
    ? fs.readFileSync(0, 'utf8')
    : fs.readFileSync(path.resolve(file), 'utf8');
  if (!transcript.trim()) throw new Error('the supplied transcript is empty');
  const sourcePath = file === '-' ? 'stdin' : path.resolve(file);
  const base = file === '-' ? 'stdin' : path.basename(file, path.extname(file));
  const session = {
    name: base.replace(/[^A-Za-z0-9._-]/g, '-') || 'transcript',
    sourcePath,
    transcript,
    segments: segmentLines(transcript).length,
    words: transcript.split(/\s+/).filter(Boolean).length,
    duration: 'unknown',
    cleanStop: true,
  };
  session.document = /^# Meeting handoff\b/m.test(transcript)
    ? transcript
    : buildHandoffDocument(session);
  return session;
}

function listSessions(root) {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => {
      const dir = path.join(root, entry.name);
      const transcriptPath = path.join(dir, 'transcript.md');
      const metaPath = path.join(dir, 'meta.json');
      if (!fs.existsSync(transcriptPath) && !fs.existsSync(metaPath)) return null;
      if (!fs.existsSync(transcriptPath)) {
        return { name: entry.name, status: 'pending', duration: '-', opensWith: 'not transcribed yet' };
      }
      try {
        const session = readSession(dir);
        const first = segmentLines(session.transcript)[0] || '(empty)';
        return {
          name: session.name,
          status: 'ready',
          duration: session.duration,
          opensWith: spokenText(first).slice(0, 60) || '(empty)',
        };
      } catch (error) {
        return { name: entry.name, status: 'error', duration: '-', opensWith: error.message };
      }
    })
    .filter(Boolean)
    .sort((a, b) => b.name.localeCompare(a.name));
}

function updateGitExclude(repo) {
  const result = spawnSync('git', ['-C', repo, 'rev-parse', '--absolute-git-dir'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.status !== 0 || !result.stdout.trim()) return;
  const exclude = path.join(result.stdout.trim(), 'info', 'exclude');
  const existing = fs.existsSync(exclude) ? fs.readFileSync(exclude, 'utf8') : '';
  if (existing.split(/\r?\n/).includes('.meeting/')) return;
  fs.mkdirSync(path.dirname(exclude), { recursive: true });
  fs.writeFileSync(
    exclude,
    `${existing}${existing.endsWith('\n') || existing.length === 0 ? '' : '\n'}\n# patchthrough meeting transcripts: local only, never commit\n.meeting/\n`,
  );
}

function stageSession(session, repo) {
  const resolvedRepo = path.resolve(repo);
  if (!fs.existsSync(resolvedRepo) || !fs.statSync(resolvedRepo).isDirectory()) {
    throw new Error(`repository directory does not exist: ${resolvedRepo}`);
  }
  const meetingDir = path.join(resolvedRepo, '.meeting');
  fs.mkdirSync(meetingDir, { recursive: true });
  const filename = `${session.name.replace(/[^A-Za-z0-9._-]/g, '-')}.md`;
  const output = path.join(meetingDir, filename);
  fs.writeFileSync(output, session.document, 'utf8');
  updateGitExclude(resolvedRepo);
  return output;
}

function promptFor(session, stagedPath) {
  const relative = path.join('.meeting', path.basename(stagedPath));
  return `Read ${relative}. That file is the transcript of a meeting relevant to this repository.

Work out what it asks of this codebase, then tell me before changing anything:

1. Concrete work items it implies, ordered by what should happen first, with the files or areas involved.
2. Anything stated as a decision or constraint I shouldn't relitigate.
3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.
4. Anything discussed that the code already does, or already contradicts.

It's speech-to-text, so read for intent rather than literal wording. Don't edit anything until we've agreed the list.`;
}

function executableCandidates(name, env = process.env) {
  const pathDirs = (env.PATH || '').split(path.delimiter).filter(Boolean);
  const home = os.homedir();
  const extras = process.platform === 'darwin'
    ? ['/opt/homebrew/bin', '/usr/local/bin', path.join(home, '.local', 'bin'), path.join(home, '.kimi-code', 'bin')]
    : [path.join(home, '.local', 'bin'), path.join(home, 'bin')];
  const dirs = [...new Set([...pathDirs, ...extras])];
  const extensions = process.platform === 'win32'
    ? (env.PATHEXT || '.EXE;.CMD;.BAT').split(';')
    : [''];
  return dirs.flatMap((dir) => extensions.map((extension) => path.join(dir, `${name}${extension}`)));
}

function findExecutable(name, env = process.env) {
  return executableCandidates(name, env).find((candidate) => {
    try {
      fs.accessSync(candidate, process.platform === 'win32' ? fs.constants.F_OK : fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function installedAgents(env = process.env) {
  return Object.keys(KNOWN_AGENTS)
    .map((name) => ({ name, path: findExecutable(name, env) }))
    .filter((agent) => agent.path);
}

function copyToClipboard(text) {
  if (process.platform !== 'darwin') return false;
  const result = spawnSync('/usr/bin/pbcopy', [], { input: text, encoding: 'utf8' });
  return result.status === 0;
}

function launchAgent(name, prompt, cwd, env = process.env) {
  const definition = KNOWN_AGENTS[name];
  if (!definition) throw new Error(`unknown agent '${name}'`);
  const executable = findExecutable(name, env);
  if (!executable) throw new Error(`agent '${name}' is not installed or not on PATH`);

  let args;
  if (definition.style === 'run') args = ['run', prompt];
  else if (definition.style === 'clipboard') {
    if (copyToClipboard(prompt)) {
      process.stderr.write(`prompt copied. Paste it once ${name} starts\n`);
    } else {
      process.stderr.write(`this agent takes no initial prompt; copy this after it starts:\n\n${prompt}\n\n`);
    }
    args = [];
  } else args = [prompt];

  const result = spawnSync(executable, args, { cwd, stdio: 'inherit', env });
  if (result.error) throw result.error;
  return result.status === null ? 1 : result.status;
}

module.exports = {
  KNOWN_AGENTS,
  buildHandoffDocument,
  expandHome,
  findExecutable,
  formatDuration,
  installedAgents,
  launchAgent,
  listSessions,
  promptFor,
  readExternalTranscript,
  readSession,
  resolveRecordingsRoot,
  resolveSession,
  segmentLines,
  stageSession,
  taskInstructions,
};
