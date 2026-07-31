# agentsmd

Build one `~/AGENTS.md` from shared and machine-specific source files, then
connect it to GitHub Copilot CLI, Claude Code, Codex, and Pi.

## Install

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  "https://api.github.com/repos/juanrgon/agentsmd/contents/install.sh?ref=main&cache=$(date +%s)-$$" | bash
```

This installs `agentsmd` to `~/.local/bin`. An existing command is backed up
with a UTC timestamp before it is replaced. The installer uses GitHub's API so
a just-pushed version is downloaded instead of an older raw branch response.

## Use

```bash
agentsmd status
agentsmd build
agentsmd commit
agentsmd install
agentsmd self-update
agentsmd service install
```

- `status` shows the configured shared repository, uncommitted shared changes,
  source files, whether `~/AGENTS.md` is current, the harness symlinks, and
  whether the background service is running.
- `build` previews the generated diff and requires approval before changing
  `~/AGENTS.md`. The generated file includes a do-not-edit warning, the rebuild
  command, and labeled boundaries around each source.
- `commit` previews the configured shared source diff and requires approval
  before committing and pushing it.
- `install` previews and creates the configured shared-source and harness
  symlinks after approval.
- `self-update` downloads and installs the latest `agentsmd` command.
- `service install` installs a per-user macOS LaunchAgent. It rebuilds the
  generated file at login and whenever either source file changes.

The default source files are:

- `~/AGENTS.shared.md` for instructions shared across computers
- `~/AGENTS.local.md` for machine-specific or private instructions

`agentsmd` preserves the source order and content: shared first, then local.
Edit the source files rather than `~/AGENTS.md`, then run `agentsmd build`.

## Configure the shared repository

Create `~/agentsmd/config.toml`:

```toml
[shared]
repository = "https://github.com/<owner>/<repository>.git"
path = "AGENTS.shared.md"
checkout = "~/github.com/<owner>/<repository>"
```

`repository` is the Git remote that receives shared-source commits. `path` is
the source file inside that repository. `checkout` is optional. When it is
omitted, `agentsmd` first reuses the checkout behind an existing
`~/AGENTS.shared.md` symlink when it matches the configured repository and path.
Otherwise it expects a managed checkout under
`~/agentsmd/repos/<owner>/<repository>`.

When this config exists, the repository file becomes the shared source used by
`build`, `status`, and the background service. `agentsmd install` creates or
repairs `~/AGENTS.shared.md` as a stable edit-path symlink to that file.

## Commit shared instructions

```bash
agentsmd commit
```

`commit` fetches the current branch from the configured remote, refuses to
continue when the checkout is ahead, behind, or diverged, and shows the complete
uncommitted diff for only the configured shared source. After the full word
`yes`, it commits only that file with an `Update <filename>` message and pushes
the current branch. Other staged or unstaged files are left alone.

If the push fails, the local commit is kept and the command reports that it was
not pushed. Run this silent check from prompt integrations:

```bash
agentsmd commit --check
```

It exits 0 when the configured source has uncommitted changes, 1 when it is
clean, and 2 when configuration or the source checkout is unavailable. It
writes nothing in every state and does not fetch or change files. Use
`agentsmd status` for human-readable diagnostics.

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

If you manually move the `agentsmd` executable or change the config, source, or
output path, run `agentsmd service install` again to update the LaunchAgent.
