---
name: mark
description: Bookmark the current Claude Code session with xmarks, auto-generating a short summary as the note. Use when the user says /mark or asks to bookmark, mark, or save this session for later.
---

# Mark this session

Save an xmarks bookmark for the current session by running the `xs`
command, so the user can later run `xg <name>` in a terminal to cd back to
this directory and resume this exact conversation.

## Steps

1. **Determine the mark name.** If arguments were given, the first word is
   the name. Otherwise invent one: 1–3 kebab-case words naming the
   session's main topic (e.g. `pact-schema`, `raps-dataloader-bug`).
   Prefer something the user would recognize weeks from now.

2. **Determine the note.** If arguments beyond the name were given, they
   are the note — use them verbatim. Otherwise write a summary of the
   session in at most 10 words, stating what was actually worked on or
   decided, not the topic alone ("designed pact schema v2, settled on
   TSV storage", not "discussion about pact").

3. **Save the mark** with Bash:

   ```bash
   xs <name> <note>
   ```

   `xs` is on PATH (installed by xmarks' `make install`). Inside a
   Claude Code session it reads `CLAUDE_CODE_SESSION_ID` and
   `CLAUDE_CONFIG_DIR` from the environment, so it marks this exact
   session on the right account with no guessing. Do not quote the note
   as a single argument — `xs` joins all arguments after the name.

4. **Confirm to the user**: echo back the mark name, the note you wrote,
   and remind them the mark is used as `xg <name>` from any terminal.

## Failure modes

- `xs: command not found` — xmarks isn't installed; tell the user to
  run `make install` in the xmarks repo.
- If the user asks to overwrite or rename an existing mark, `xs` with an
  existing name replaces it, and `xd <name>` un-stars one (the session
  stays in `xj`, it just drops out of `xl`).
