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

// One wording of the speech-to-text caveat, shared by every prompt here. The
// app carries the same sentence in Handoff.swift (`asrCaveat`). These two
// strings are the handoff contract in prose: keep them in step.
const ASR_CAVEAT = "It's speech-to-text, so it's messy: unreliable punctuation, garbled technical terms, and 'me'/'them' labels that can be wrong. Read for intent, not literal wording.";

function taskInstructions() {
  return `Read the transcript below and work out what this meeting asks of me. Before changing anything, give me:

1. Concrete work items it implies, ordered by what should happen first.
2. Anything stated as a decision or constraint I shouldn't relitigate.
3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.
4. Anything discussed that the current project may already do or contradict.

${ASR_CAVEAT} Don't edit anything until we've agreed the list.`;
}

// Prompt for the browser doors. It never names the attached file, because
// chatgpt.com renames a pasted file to a UUID and strips the extension. The
// app carries the same text in Handoff.swift (`webPrompt`).
function webPrompt(session) {
  return `The attached file is the transcript of a meeting I just had (${session.duration}, machine-transcribed on-device). Read it, work out what it asks of me, then give me:

1. Concrete work items it implies, ordered by what should happen first.
2. Anything stated as a decision or constraint I shouldn't relitigate.
3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.

${ASR_CAVEAT}`;
}

// The handoff file next to the session, or in a temp directory for a
// transcript that came from --file or stdin and has no session folder. The
// clipboard refers to this path, so it has to outlive this process.
function writeHandoffFile(session) {
  const dir = session.dir
    ? session.dir
    : fs.mkdtempSync(path.join(os.tmpdir(), 'patchthrough-'));
  const target = path.join(dir, session.dir ? 'handoff.md' : `${session.name}.md`);
  if (!fs.existsSync(target)) fs.writeFileSync(target, session.document);
  return target;
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
- Speakers: \`me\` is this machine's microphone. \`them\` is the audio the Mac played, which is the other side of the call. These are channels, not verified identities: echo can put the wrong label on a line.
- Transcribed on-device. **Expect transcription errors**, especially in proper nouns, identifiers and technical terms. If a term looks wrong but is phonetically close to something plausible, it probably is that.
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
  return `Read ${relative}. That file is the transcript of a meeting about this codebase.

Work out what it asks of this codebase, then tell me before changing anything:

1. Concrete work items it implies, ordered by what should happen first, with the files or areas involved.
2. Anything stated as a decision or constraint I shouldn't relitigate.
3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.
4. Anything discussed that the code already does, or already contradicts.

${ASR_CAVEAT} Don't edit anything until we've agreed the list.`;
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

// The chat websites whose composer takes a pasted file. The app carries the
// same table in Handoff.swift (`knownGuiTargets`); keep the two in step.
// `uploadsToCloud` marks a site that copies the attachment off the machine.
const WEB_TARGETS = {
  claude: {
    label: 'Claude (web)',
    newChatURL: 'https://claude.ai/new',
    prefillsPrompt: true,
    uploadsToCloud: false,
  },
  chatgpt: {
    label: 'ChatGPT (web)',
    newChatURL: 'https://chatgpt.com/',
    prefillsPrompt: true,
    uploadsToCloud: false,
  },
  m365: {
    label: 'Microsoft 365 Copilot (web)',
    newChatURL: 'https://m365.cloud.microsoft/chat/',
    prefillsPrompt: false,
    uploadsToCloud: true,
  },
};

// Percent-encode down to alphanumerics. `encodeURIComponent` leaves `'()*~!.-_`
// raw, which is a different byte string than the app sends. These sites read
// the query with URLSearchParams, which also turns `+` into a space.
function pctEncoded(value) {
  return [...value]
    .map((ch) => (/^[A-Za-z0-9]$/.test(ch)
      ? ch
      : [...Buffer.from(ch, 'utf8')]
        .map((b) => `%${b.toString(16).toUpperCase().padStart(2, '0')}`)
        .join('')))
    .join('');
}

// Put a file on the clipboard as a reference, not as text, so a paste into a
// chat composer attaches the file. The path goes through argv rather than a
// script literal, because transcript-derived text must never reach a parser
// as code. AppleScript exits 0 and empties the clipboard for a path that does
// not exist, so check first and verify after.
function copyFileToClipboard(filePath) {
  if (process.platform !== 'darwin') return false;
  if (!fs.existsSync(filePath)) return false;
  const script = 'on run argv\nset the clipboard to POSIX file (item 1 of argv)\nend run';
  if (spawnSync('/usr/bin/osascript', ['-e', script, filePath]).status !== 0) return false;
  const info = spawnSync('/usr/bin/osascript', ['-e', 'clipboard info'], { encoding: 'utf8' });
  return (info.stdout || '').includes('furl');
}

// The browser that receives the paste. A plain https URL opens in whichever
// browser macOS chose, so the keystrokes have to go to that one.
function defaultBrowserName() {
  if (process.platform !== 'darwin') return null;
  const script = 'use framework "AppKit"\n'
    + 'set ws to current application\'s NSWorkspace\'s sharedWorkspace()\n'
    + 'set u to current application\'s NSURL\'s URLWithString:"https://example.com"\n'
    + 'set appURL to ws\'s URLForApplicationToOpenURL:u\n'
    + 'return (appURL\'s lastPathComponent()) as text';
  const result = spawnSync('/usr/bin/osascript', ['-e', script], { encoding: 'utf8' });
  if (result.status !== 0) return null;
  const name = (result.stdout || '').trim().replace(/\.app$/, '');
  return name || null;
}

// Finish the handoff with a synthesized paste. Unlike the app, an npm CLI has
// no signed bundle, so macOS attributes Accessibility to the terminal that ran
// this command. Without that grant the keystroke silently does nothing and
// osascript still exits 0, so this refuses to try rather than claim success.
function autoPasteIntoBrowser(browser, settleSeconds = 5) {
  if (process.platform !== 'darwin') return false;
  const trusted = spawnSync('/usr/bin/osascript', ['-l', 'JavaScript', '-e',
    'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted()'], { encoding: 'utf8' });
  if ((trusted.stdout || '').trim() !== 'true') return false;
  const script = `delay ${settleSeconds}\n`
    + `tell application "${browser}" to activate\n`
    + 'delay 0.4\n'
    + 'tell application "System Events" to keystroke "v" using command down';
  return spawnSync('/usr/bin/osascript', ['-e', script]).status === 0;
}

// Open a chat website with the transcript on the clipboard. Returns what the
// caller must tell the user, because the outcome varies by site and by grant.
function handToWeb(siteName, session, options = {}) {
  const site = WEB_TARGETS[siteName];
  if (!site) {
    throw new Error(`unknown web target '${siteName}'. Try: ${Object.keys(WEB_TARGETS).join(', ')}`);
  }
  if (process.platform !== 'darwin') {
    throw new Error('web handoffs need macOS, because they use the macOS clipboard');
  }
  const file = writeHandoffFile(session);
  const attached = copyFileToClipboard(file);
  let url = site.newChatURL;
  if (site.prefillsPrompt) {
    url += `${url.includes('?') ? '&' : '?'}q=${pctEncoded(webPrompt(session))}`;
  }
  spawnSync('/usr/bin/open', [url]);
  const pasted = attached && options.autoPaste !== false
    ? autoPasteIntoBrowser(defaultBrowserName() || 'Safari')
    : false;
  return { site, file, attached, pasted };
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
  WEB_TARGETS,
  buildHandoffDocument,
  copyFileToClipboard,
  defaultBrowserName,
  handToWeb,
  pctEncoded,
  webPrompt,
  writeHandoffFile,
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
