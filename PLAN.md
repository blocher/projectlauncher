# Launcher generator plan

Goal: point Project Launcher at any repo and generate a standalone iTerm dev launcher that ships with that repo
(`StartXDev.applescript` + compiled `StartXDev.app`, both committed). Every launcher follows one pattern. Claude may
help at generation time; the finished launcher never needs Claude or Project Launcher.

## Decisions

| Question | Decision |
|---|---|
| Output | Fully standalone script in the repo; `.applescript` source and compiled `.app` are both committed |
| Audience | Mostly me; teammates on shared repos and people who fork must be able to use the launchers |
| Claude | Allowed while generating; the generated launcher must not depend on it |
| Checkouts | One checkout of a repo at a time; no per-worktree ports |
| Team repos with their own launcher | Brought in line through a PR |
| One-off extras | Permitted (custom commands, start-up messages, pre-launch steps) |
| Existing launchers | Regenerated from the new template |
| Config | Public tool repo; each user's project list lives in its own (private) repo at `~/.config/projectlauncher` |
| Config sync | Pull on launch and every 5 minutes; commit and push on every editor save. Config only, never project code |
| Projects on a new Mac | Each project records its GitHub `owner/name`; missing ones offer **Install from GitHub** (`gh repo clone`) |
| Inactive projects | `"enabled": false` hides a project from the picker; one checkbox turns it back on |

## How generation works

1. **Analyze**: Claude (`claude -p`, fixed prompt) or rule-based detection reads the repo. It returns a **pane
   description** in a fixed format, never a script.
2. **Review**: the Projects editor shows the panes, the assigned ports and any proposed config changes.
3. **Render**: a deterministic template turns the description into the AppleScript. It's the same code every time, so
   all launchers behave identically and template fixes reach every repo through Regenerate.

## Pane description (embedded at the top of every generated script)

- **Project:** name, ID, browser URL, which pane's port gates opening the browser.
- **Pre-launch steps:** run once before panes open, e.g. installing frontend dependencies or trusting a dev
  certificate.
- **Panes (in order),** each with:
  - role
  - folder relative to the repo root
  - setup steps (venv, `uv`, `nvm use`, `.env` loading)
  - port it owns (optional)
  - what it waits for (other panes' ports)
  - command
  - monitored (yes or no)
  - optional start-up message (e.g. BIY's import tips)
  - optional tab color
  - optional enable condition (an environment variable that turns the pane on)
- **Working pane:** always last; a shell with `git status` plus any message.

The block is plain text inside an AppleScript comment, so Project Launcher can read it exactly, and **Regenerate**
can rebuild the script with no Claude call.

## What the template guarantees

- The project root comes from the script's own location, so it works in any clone, fork or folder name.
- Every pane gets standard iTerm tags: `user.launcherProject` (ID) and `user.launcherPane` (role). Project
  Launcher's status needs no per-project settings. Rerunning replaces the window carrying the same project tag.
- Stacked horizontal rows, 75% screen width, Working pane last.
- Port cleanup stops **listeners only**, on the project's own ports.
- Panes wait for real readiness (`nc -z` on a port) instead of `sleep`. The browser opens, in the default browser,
  once the gating port answers.
- Ports can be overridden per machine with environment variables (e.g. `BACKEND_PORT`). The pane shells evaluate
  these, since a Finder-launched `.app` doesn't see your shell environment.
- Prerequisite checks (iTerm, `uv`/`.venv`, Node version, `redis-server`, etc.) fail with a clear message saying what
  to install.

## Ports

Project Launcher keeps a registry built from every project's description block. It avoids those ports and the common
defaults (8000, 5173, 3000, 6379), and assigns each new project the next free block. At generation time, Claude also
proposes the **config changes** the new ports need, shown as a reviewable diff applied only on approval:

- Vite port and proxy
- Django CORS/CSRF and public URLs
- `.env.example`
- Capacitor dev URLs
- tests

## Sharing: a Claude Code skill

The analysis prompt, pane-description format, template and renderer are packaged as a Claude Code skill.

- **Me:** Project Launcher → **+ → New Project from Folder…** runs the same skill headlessly and shows the result in
  the editor.
- **Teammates:** run the skill in Claude Code inside the repo, or add it to the team's shared skills.
- **Everyone else:** double-click the committed `.app`.

The skill is pulled from this public repo.

## Team repos

Some repos are shared with a team and already have their own launcher (for example, an iTerm2 Python API script that
tags its window rather than its panes). Those are brought in line through a pull request:

- Add the generated `Start…Dev.applescript`/`.app` alongside the existing launcher. Retire the old one only once the
  team agrees.
- Carry over what the old launcher does (dependency preparation as pre-launch steps, env loading, tab colors,
  optional panes behind an environment variable).
- Keep the team's established ports.
- Update any tooling that finds the old launcher's windows (e.g. by a window variable) to also recognize the
  standard `user.launcherProject` tag.

## Build order

1. **Format + template + renderer.** Regenerate Zoomy's launcher and confirm it behaves identically: panes, `.env`
   loading, ports, status in the picker.
2. **Migrate the other personal projects** (BIY, Elizabeth's Sermons, Pewcorder, Daily Office, Locher Songs).
   Preserve one-offs: BIY's tools message, Locher Songs' migrate-before-runserver, Daily Office's cert trust,
   Pewcorder's Redis. Switch Project Launcher to the standard tags and the embedded description blocks. Commit each
   repo.
3. **Generator UI:** New Project from Folder (Claude + rule-based fallback), port registry, config-change diff, and
   Write to Repo (optionally branch + commit).
4. **Skill + team repos:** package the skill and open PRs for team repos that have their own launchers.
