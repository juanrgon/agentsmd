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
```

- `status` shows the source files, whether `~/AGENTS.md` is current, and the
  harness symlinks.
- `build` previews the generated diff and requires approval before changing
  `~/AGENTS.md`.
- `install` previews and creates the harness symlinks after approval.

The default source files are:

- `~/AGENTS.shared.md` for instructions shared across computers
- `~/AGENTS.local.md` for machine-specific or sensitive instructions
