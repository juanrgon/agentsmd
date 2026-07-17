# agentsmd

Build one `~/AGENTS.md` from shared and machine-specific source files, then
connect it to GitHub Copilot CLI, Claude Code, Codex, and Pi.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/juanrgon/agentsmd/main/install.sh | bash
```

This installs `agentsmd` to `~/.local/bin`. An existing command is backed up
with a UTC timestamp before it is replaced.

## Use

```bash
agentsmd status
agentsmd build
agentsmd install
agentsmd self-update
agentsmd service install
```

- `status` shows the source files, whether `~/AGENTS.md` is current, and the
  harness symlinks.
- `build` previews the generated diff and requires approval before changing
  `~/AGENTS.md`.
- `install` previews and creates the harness symlinks after approval.
- `self-update` downloads and installs the latest `agentsmd` command.
- `service install` installs a per-user macOS LaunchAgent. It rebuilds the
  generated file at login and whenever either source file changes.

The default source files are:

- `~/AGENTS.shared.md` for instructions shared across computers
- `~/AGENTS.local.md` for machine-specific or sensitive instructions

## Update agentsmd

```bash
agentsmd self-update
```

`self-update` downloads the command from the `main` branch, checks that it is
valid Bash and looks like `agentsmd`, then replaces the invoked executable
atomically. If the downloaded file is unchanged, it does nothing.

Before replacing the command, it creates a backup beside the executable named
`agentsmd.<UTC timestamp>.bak`. The executable must be a writable regular file,
not a symlink. Set `AGENTSMD_UPDATE_URL` to use a different download URL.

If a loaded agentsmd LaunchAgent uses the same executable, `self-update` also
applies any service template changes while preserving the paths saved in its
plist.

## Automatic builds on macOS

The background service uses LaunchD and only supports macOS. On Linux or
Windows, every `agentsmd service` command exits with an unsupported-platform
error.

```bash
agentsmd service install
agentsmd service status
agentsmd service history
agentsmd service doctor
agentsmd service start
agentsmd service stop
agentsmd service restart
agentsmd service uninstall
```

`service stop` disables the LaunchAgent, so it stays stopped after login.
`service start` enables it again.

`service install` writes `~/Library/LaunchAgents/com.juanrgon.agentsmd.plist`,
loads it for the current user, and starts the first build. The LaunchAgent
watches the configured shared and local source paths. Rapid edits are
coalesced with a five-second throttle. If a source is a symlink when the
service is installed, its resolved target is watched too.

The service only reacts to filesystem changes. If a source path points into a
network or cloud-synced filesystem, event delivery still depends on macOS and
that filesystem.

Unattended builds do not show a diff or ask for approval. They use the same
generated format, backups, atomic replacement, and private file permissions as
the interactive `build` command.

Build results are stored in
`~/Library/Application Support/agentsmd/history.tsv`. Standard output and
errors are stored under `~/Library/Logs/agentsmd/`. `service uninstall` keeps
the history and logs so they remain available for troubleshooting.

The LaunchAgent plist, history, and log files use owner-only permissions. Keep
in mind that build errors can still include configured file paths.

If you manually move the `agentsmd` executable or change a configured source or
output path, run `agentsmd service install` again to update the LaunchAgent.
