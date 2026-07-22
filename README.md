# agentmarks

Bashmarks-style bookmarks for coding-agent sessions (Claude Code and Codex
CLI): save a mark, later jump back with one command that cd's into the
directory *and* resumes the exact session. See `DESIGN.md` for the
design notes.

## Install

```bash
make install
echo 'source ~/.local/bin/agentmarks.sh' >> ~/.bashrc
```

`make install` puts `agentmarks.sh` plus the `xs/xg/xl/xd` command wrappers
into `~/.local/bin` (override with `PREFIX=...`); `make uninstall` removes
them. The wrappers exist because shells inside a Claude Code session
(`! xs ...`) never read `.bashrc`; in interactive shells the sourced
functions shadow them. Only `xg` truly needs to be a function — the wrapper
version resumes fine but can't leave your shell in the mark's directory,
which is why the `source` line is still worth adding (put it above your
bashrc's "not interactive" guard).

Requires `jq` (for first-message previews). `fzf` is optional — if present,
`xg` with no argument opens a fuzzy picker.

## Usage

```bash
xs <name> [note...]   # save a mark for the session in the current dir
xg <name>             # cd there and resume the session
xl                    # list marks (name, tool, account, dir, note, ...)
xd <name>             # remove a mark
```

The best way to save a mark is from *inside* the session you want to keep:

```
! xs pact-schema the one where we designed the pact schema
```

Shells spawned by Claude Code export `CLAUDE_CODE_SESSION_ID`, so this marks
the exact session — no guessing. Run outside a session, `xs` falls back to
the most recent session for the current directory, across all tools and
accounts.

Marks are stored in `~/.agentmarks` (TSV, override with `$AGENTMARKS_FILE`).
Each mark keeps a copy of the session's first user message, so listings stay
meaningful even after the agent expires the session file itself. If a
session is gone, `xg` still cd's to the directory and warns.

## Multiple accounts and tools

Each mark records which tool it belongs to (`claude` or `codex`) and the
home dir its session lives in (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`, e.g.
`~/.claude-personal` vs `~/.claude-work`). `xg` dispatches accordingly —
`CLAUDE_CONFIG_DIR=... claude --resume` or `CODEX_HOME=... codex resume` —
so marks from every account and both tools share one list, and `xl` shows
TOOL and ACCOUNT columns for each.

When saving from inside a Claude Code session, the session's own id and
config dir are used (Codex doesn't export a session id to child shells, so
there's no Codex equivalent). When guessing from a plain shell, `xs`
searches every existing `~/.claude*` and `~/.codex*` home and takes the
newest session for the current dir, whichever tool it came from. Codex has
no per-project session layout, so its side of the search scans recent
rollout files for a matching `cwd`. Restrict or reorder candidates with
`AGENTMARKS_CONFIG_DIRS` / `AGENTMARKS_CODEX_HOMES` (colon-separated).
