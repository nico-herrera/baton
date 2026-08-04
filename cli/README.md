# Patchthrough CLI

Hand a meeting transcript to the coding agent you use.

This is the standalone command-line half of
[Patchthrough](https://github.com/nico-herrera/patchthrough). It does not
record audio, transcribe meetings, download a native binary, or install the
macOS app. You get the open-source macOS app separately from GitHub Releases.

## Install

```sh
npm i -g patchthrough
```

There are no install scripts and no native dependencies.

### Upgrading from 1.x

Patchthrough 1.x used npm as a native-app installer. CLI 2.x replaces the old
npm command, and your installed app and your recordings stay in place. Future
app updates come from GitHub Releases. Future CLI updates come from npm.

## Use

When the macOS app has already recorded and transcribed a meeting:

```sh
cd ~/Code/my-project
patchthrough hand claude
```

The CLI finds the newest transcribed session. It copies the self-contained
`handoff.md` of that session into `.meeting/` in the current repository. It
adds `.meeting/` to the repository's local Git excludes. It then starts the
agent with the handoff in context.

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

## Chat websites

`--web` opens a chat site instead of a terminal agent. It needs no repository and
no installed app:

```sh
patchthrough hand --web claude
patchthrough hand --web chatgpt
patchthrough hand --web m365
```

Patchthrough puts `handoff.md` on the clipboard as a file and opens the site. One
paste (⌘V) attaches the transcript. macOS only, because this uses the macOS
clipboard.

The CLI cannot paste for you as reliably as the app can. macOS grants
Accessibility to the terminal that runs the command rather than to Patchthrough,
so without that grant the CLI tells you to paste instead of claiming a paste that
never happened.

Microsoft copies an attached file into your work OneDrive, so `--web m365` warns
you that the transcript leaves your machine.

## Your own sites

Anything listed in `custom_destinations` in
`~/.config/patchthrough/config.json` works as a `--web` target too:

```json
{
  "custom_destinations": [
    { "id": "internal", "label": "Internal tool",
      "url": "https://tool.example.com/chat" }
  ]
}
```

```sh
patchthrough hand --web internal
```

The app writes this file from its Settings sheet, so a destination you add there
is available here with no extra step. `url` must start with `http://` or
`https://`.

Known terminal agents: Claude Code, Copilot, Codex, Kimi, opencode, and
cursor-agent.

## Shared files

By default the CLI reads `~/Recordings`, or the `recordings_dir` value in
`~/.config/patchthrough/config.json`. The app and the CLI communicate only
through the documented session files. Neither process needs the other process
to run.

See the
[session v1 contract](https://github.com/nico-herrera/patchthrough/blob/main/schemas/session-v1.md)
for the exact format.

## Requirements

Node.js 18 or newer. The `hand`, `transcripts`, and `doctor` commands also run
on Windows and Linux. Web handoffs run on macOS and Windows, because they use
the system clipboard. Recording and on-device transcription still require the
separate macOS 15+ Apple Silicon app.

On Windows, npm installs most agents as a `.cmd` shim. A shim cannot take a
prompt with newlines as an argument, so the CLI puts the prompt on the
clipboard and tells you to paste it after the agent starts.

## License

MIT
