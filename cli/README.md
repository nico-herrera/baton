# Patchthrough CLI

Hand a meeting transcript to the coding agent you use.

This is the standalone command-line half of
[Patchthrough](https://github.com/nico-herrera/patchthrough). It does not
record audio, transcribe meetings, download a native binary, or install the
macOS app. The open-source macOS app is available separately from GitHub
Releases.

## Install

```sh
npm i -g patchthrough
```

There are no install scripts and no native dependencies.

### Upgrading from 1.x

Patchthrough 1.x used npm as a native-app installer. Installing CLI 2.x
replaces the old npm command but leaves the existing app and recordings in
place. Future app updates come from GitHub Releases; future CLI updates come
from npm.

## Use

When the macOS app has already recorded and transcribed a meeting:

```sh
cd ~/Code/my-project
patchthrough hand claude
```

The CLI finds the newest transcribed session, copies its self-contained
`handoff.md` into `.meeting/` in the current repository, adds `.meeting/` to
the repository's local Git excludes, and starts the agent with the handoff in
context.

```sh
patchthrough transcripts
patchthrough hand codex --session 2026.07.30-2145
patchthrough hand claude --dir ~/Code/project
patchthrough hand opencode --no-launch
```

The CLI also works without the macOS app:

```sh
patchthrough hand claude --file meeting.md
cat meeting.md | patchthrough hand codex --file -
```

Known terminal agents: Claude Code, Copilot, Codex, Kimi, opencode, and
cursor-agent.

## Shared files

By default the CLI reads `~/Recordings`, or the `recordings_dir` value in
`~/.config/patchthrough/config.json`. The app and CLI communicate only through
the documented session files; neither needs the other process to be running.

See the
[session v1 contract](https://github.com/nico-herrera/patchthrough/blob/main/schemas/session-v1.md)
for the exact format.

## Requirements

Node.js 18 or newer. Recording and on-device transcription still require the
separate macOS 15+ Apple Silicon app.

## License

MIT
