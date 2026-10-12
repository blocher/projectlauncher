# Project Launcher

One Dock icon for all your local dev environments. Click it to pick a project: each one shows its logo and live
status, and you can launch, switch to, restart or stop its iTerm window, or open it in the browser, Cursor or Finder.

Built for projects that start with an iTerm launcher app (an AppleScript `Start…Dev.app` that opens stacked panes
for the backend, frontend, queue and a working shell). Project Launcher reads the iTerm variables those launchers set
on their panes to tell what's running.

- **Left-click** the Dock icon: a picker pops up just above the Dock, with logos, status and per-project actions.
- **Right-click** it: the same menu in the Dock's own style. The Dock can't show images, so status shows as
  🟢 / 🟠 / ⚪️.
- **Dock badge**: how many projects have a window open.

Requires macOS 15 or later and [iTerm2](https://iterm2.com).

## Status

| Dot | Meaning |
| --- | --- |
| 🟢 green | Window open, every monitored pane running something |
| 🟠 orange | Window open, but some pane has dropped back to a shell (e.g. "Frontend stopped · 2/3 up") |
| 🔵 blue | Just launched and still starting, or being installed |
| none / ⚪️ | Not running |
| ⬇️ | Not on this Mac yet: offers **Install from GitHub** |

A project's window is found through an iTerm variable its launcher sets on each pane (e.g. `user.MyAppSession`). Each
pane's TTY is then checked for a foreground process other than an idle shell. Every pane counts toward health unless
you uncheck it in the editor.

**Restart** re-runs the project's launcher, which is expected to replace its old window. **Stop** closes the window.

## Your config

The project list lives in `~/.config/projectlauncher/` (or another folder you choose in the editor):
`projects.json` plus any logos it references. The app re-reads it every time the menu opens, so you never need to
rebuild.

**Keep it in its own git repo** to share it between Macs. When the config folder is a git repository, Project Launcher:

- pulls on launch and every five minutes, so edits from your other Macs show up,
- commits and pushes whenever you save in the editor.

Only the config syncs; your project code is never pushed.

**On a new Mac**, the first-run screen offers to:

- **Clone Config Repo** (`owner/name`, via the GitHub CLI), or
- **Create New Config** from the bundled example.

Projects your config lists that aren't on the Mac yet show as *Not on this Mac*, with **Install from GitHub**, which
runs `gh repo clone owner/name <path>`.

**Turning projects off:** uncheck a project in the editor to hide it from the picker without deleting it (it's saved
as `"enabled": false`). Check it again when you pick the project back up.

## Creating a launcher for a repo

Project Launcher can generate a standalone launcher for any repo: a `Start<Name>Dev.applescript` plus compiled `.app`
that live in the repo and need nothing but macOS and iTerm2. Anyone who clones the repo can double-click it.

1. **Edit Projects… → + → New Project from Folder…**, then pick the repo.
2. A draft appears straight away, from the repo's files: Django or Rails or FastAPI backends, Vite or Next
   frontends, Celery queues, Redis, virtualenvs or `uv`, `.env` files. It's given a free block of ports that no other
   project (and nothing listening now) uses.
3. Optionally click **Improve with Claude**. Claude Code reads the repo (read-only tools), refines the panes, and
   proposes the **config changes** the new ports need (Vite port and proxy, Django CORS/CSRF dev defaults,
   `.env.example`…). Only the changes you leave checked are applied. Needs the `claude` command, signed in once
   with `claude` → `/login`.
4. Adjust panes, commands and ports (or the raw spec under **Edit the spec as JSON**), then click
   **Write Launcher**. It's written to the repo, committed and pushed if you leave those boxes checked, and added
   to your projects.

Each generated launcher's form in the editor has **Edit Launcher…** (change its panes, commands and ports) and
**Regenerate Launcher** (rebuild it from its embedded spec after Project Launcher's template improves).

**Without Project Launcher:** the generator is also the `dev-launcher` Claude Code skill. Install it with
`npx skills add blocher/projectlauncher --skill dev-launcher`, then ask Claude Code to "create a dev launcher for this
repo" (or to change or regenerate one).

The generator also works from the command line; see [skills/dev-launcher/SPEC.md](skills/dev-launcher/SPEC.md):

```bash
python3 skills/dev-launcher/launcher.py detect ~/projects/myapp > draft.json
python3 skills/dev-launcher/launcher.py render spec.json --repo ~/projects/myapp
python3 skills/dev-launcher/launcher.py regenerate ~/projects/myapp/StartMyAppDev.applescript
```

## Editing projects

Choose **Edit Projects…** from the picker (or press ⌘, while the app is frontmost).

- **+ → Add from Launcher App…**: pick a `Start…Dev.app`. The editor reads its script and fills in the iTerm
  variable, the panes, the local URL, the project folder and the GitHub repo. It also picks the best logo it can find
  in the project.
- **Logo**: drop an image on the tile, click **Choose Image…**, or click **Find in Project…** to browse logo-like images
  in the project. Square images become rounded tiles; they're saved to `icons/<id>.png` on **Save**.
- **Monitored Panes**: one checkbox per pane the launcher creates. Uncheck panes that are meant to sit idle.
- **Show in Picker**: the on/off switch, also available as the checkbox beside each project in the sidebar.
- Drag rows in the sidebar to reorder the picker.

### `projects.json`

```json
{
  "id": "myapp",
  "name": "My App",
  "description": "Shown as a tooltip",
  "enabled": false,
  "path": "~/projects/myapp",
  "repo": "your-github-user/myapp",
  "launcher": "~/projects/myapp/StartMyAppDev.app",
  "icon": "icons/myapp.png",
  "url": "http://localhost:5180/",
  "match": { "variable": "user.MyAppSession" },
  "idlePanes": ["Working"]
}
```

| Field | |
| --- | --- |
| `id` | Unique key, also the logo's file name |
| `name`, `description` | Shown in the picker; the description is a tooltip |
| `enabled` | Omit (or `true`) to show the project; `false` hides it |
| `path` | The project folder, `~`-relative |
| `repo` | GitHub `owner/name`, used to install the project on a Mac that doesn't have it |
| `launcher` | The app that opens the project's iTerm window |
| `icon` | Relative to the config folder, or absolute |
| `url` | Opened by **Open in Browser** |
| `match.variable` | The iTerm variable the launcher sets on its panes, read at session scope. For a launcher that tags its *window* instead, use `tab.window.<name>` together with `match.equals`. |
| `idlePanes` | Pane roles (or names) that don't count toward health |

See [examples/projects.example.json](examples/projects.example.json) for a complete file.

## Build

```bash
./build.sh
```

Compiles with `swiftc` (no Xcode project needed) and installs to `~/Applications/Project Launcher.app`, relaunching it
if it was running. Needs the Xcode command-line tools and `rsvg-convert` (`brew install librsvg`). It signs with
your Apple Development identity when there is one, so macOS's "control iTerm" permission survives rebuilds.
Installing projects and cloning a config need the [GitHub CLI](https://cli.github.com) (`gh auth login`).

```bash
"$HOME/Applications/Project Launcher.app/Contents/MacOS/ProjectLauncher" --status
```

That prints the status the picker would show, which helps when debugging.

## License

[MIT](LICENSE)
