---
name: dev-launcher
description: Dev launcher for a repo — a standalone iTerm Start<Name>Dev.app with one stacked pane per service (backend, frontend, queue, Redis) plus a working shell. Use to create one for a repo, or to change, re-port or regenerate an existing launcher.
---

# Dev launcher

A **launcher** is a `Start<Name>Dev.applescript` plus compiled `.app` at the root of a repo. Double-clicking it opens
one iTerm window with a pane per service. It is rendered from a **spec** (JSON) by `launcher.py`, which sits next to
this file and needs only Python 3.9+. The spec is embedded at the top of the generated `.applescript`, so the spec
is the single source of truth: change the spec, then render. [SPEC.md](SPEC.md) defines every field and placeholder;
read it before writing or editing a spec.

`L` below means `python3 <this skill's folder>/launcher.py`.

## Which branch

- The repo has a `Start*Dev.applescript` containing `PROJECT-LAUNCHER-SPEC` → **change** (below).
- Otherwise → **create**. An older hand-written launcher, if present, is evidence of how the project runs; the
  generated one replaces it under the same file name (set `launcher` in the spec).

## Create

1. **Ports in use.** Collect ports the new launcher must avoid: listeners (`lsof -nP -iTCP -sTCP:LISTEN`) and the
   ports of other generated launchers nearby (`L extract <repo>/../*/Start*Dev.applescript`). Done when you have a
   comma-separated list.
2. **Draft.** `L detect <repo> --taken <ports>` prints `{"spec", "notes", "configChanges"}` from the repo's files.
3. **Analyze.** Read [ANALYZE.md](ANALYZE.md) and do that analysis yourself, starting from the draft: verify every
   pane against the repo's README, scripts and settings; add what detection missed; give each server its own port
   from the free ranges in `launcher.py` (`PORT_RANGES`). `L analyze` is the same step for callers that aren't
   Claude; skip it here. Done when every service the README runs locally has a pane, or a note saying why not.
4. **Validate.** Write the spec to a temporary file and run `L validate <file>` until it prints `ok`.
5. **Review.** Show the user the panes (role, folder, port, command) and each proposed config change (file, why,
   before → after). Apply only the changes they approve. Edits stay in local-dev config; production and deploy
   files stay as they are.
6. **Render.** `L render <file> --repo <repo>`. Done when `L extract <repo>/<Launcher>.app` prints the same spec.
7. **Hand off.** Tell the user how to run it (double-click the `.app`) and what changed. Commit only if they ask,
   following the repo's commit conventions.

## Change

1. `L extract <repo>/<Launcher>.applescript > spec.json`.
2. Edit `spec.json` (SPEC.md defines the fields), then `L validate spec.json`.
3. `L render spec.json --repo <repo>`. Changing a port usually means the same config edits as **create** step 5.

To pick up template improvements without changing the spec, run `L regenerate <repo>/<Launcher>.applescript`.

## Running it

The launcher replaces its own previous window and stops only processes listening on its own ports. Opening it
starts the project's servers, so run it to verify only when the user wants the environment running.
[Project Launcher](https://github.com/blocher/projectlauncher) (macOS) shows every generated launcher's live status
from its pane tags and offers the same create and change flows in a window.
