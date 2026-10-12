# Launcher spec

A launcher spec describes a project's local dev environment: one iTerm window with one stacked pane per service.
`launcher.py` turns it into a standalone `Start<Name>Dev.applescript` plus a compiled `.app` that live in the project's
repo. The spec is embedded at the top of the generated script, so a launcher can always be regenerated, and
Project Launcher can read it, without the original file.

```bash
python3 launcher.py render spec.json --repo ~/projects/myapp   # write + compile
python3 launcher.py regenerate ~/projects/myapp/StartMyAppDev.applescript
python3 launcher.py extract ~/projects/myapp/StartMyAppDev.app  # print the embedded spec
python3 launcher.py validate spec.json
```

## Example

```json
{
  "spec": 1,
  "id": "myapp",
  "name": "My App",
  "url": "http://localhost:{port:Frontend}/",
  "focus": "Frontend",
  "requires": ["uv", "npm", "redis-server"],
  "setup": ["source .venv/bin/activate"],
  "panes": [
    { "role": "Redis", "port": 6390, "command": "redis-server --port {port} --save '' --appendonly no" },
    {
      "role": "Backend",
      "dir": "backend",
      "port": 8010,
      "env": [".env"],
      "waitFor": ["Redis"],
      "command": "python manage.py migrate && python manage.py runserver 127.0.0.1:{port}"
    },
    { "role": "Frontend", "dir": "frontend", "port": 5180, "command": "npm run dev -- --port {port}" },
    { "role": "Queue", "dir": "backend", "waitFor": ["Redis"], "command": "celery -A config worker --loglevel=INFO" },
    { "role": "Working", "command": "git status", "message": "Seed data: python backend/manage.py loaddata demo" }
  ]
}
```

## Fields

| Field | |
| --- | --- |
| `spec` | Always `1` |
| `id` | Letters, numbers, `-`, `_`. Tags the iTerm panes (`user.launcherProject`) and prefixes port variables |
| `name` | Shown in pane titles and messages |
| `description` | Optional; a comment at the top of the script |
| `launcher` | Optional file name without extension. Default: `Start` + name without spaces + `Dev` |
| `url` | Optional. Opened in the default browser once the pane it points at answers on its port |
| `openWhenReady` | Optional pane role whose port gates the browser. Default: the pane the URL's port belongs to |
| `focus` | Optional pane role to leave selected |
| `requires` | Tools that must be on the login shell's PATH; the launcher stops with a clear message if any are missing |
| `env` | Dotenv files (relative to the repo) loaded into every pane, when present. They're sourced by the shell, so they must be valid shell (`KEY=value`, values with spaces or symbols quoted); leave out files only the app itself reads |
| `setup` | Shell lines run in every pane after `cd`, before the pane's own setup |
| `preLaunch` | Steps run once before iTerm opens, in a login shell at the repo root: `"cmd"` or `{"run": "cmd", "label": "…", "background": true}`. A failing step asks whether to continue |
| `panes` | In order, top to bottom. The last one is usually the Working shell |

### Panes

| Field | |
| --- | --- |
| `role` | Unique; tags the pane (`user.launcherPane`) and names it |
| `dir` | Folder relative to the repo; default the repo root |
| `port` | The port this pane serves. Listeners on it are stopped before it starts (`freePort: false` to skip) |
| `env`, `setup` | As above, for this pane only |
| `waitFor` | Roles of panes whose ports must answer before this pane's command runs |
| `message` | A line, or a list of lines, printed before the command (e.g. tips for the Working shell). To print it after a quick command such as `git status`, put that command in `setup` |
| `command` | What the pane runs |
| `color` | Tab color, `#RRGGBB` |
| `enabledBy` | Environment variable that turns the pane on (`1`, `true`, `yes` or `on`, any case). The login shell's value wins; otherwise it's read from the env files (`KEY=value` lines). Use `{"variable": "NAME", "files": ["path/.env"]}` to read other files without loading them into the pane. Not allowed on the first pane |
| `note` | A comment above the pane in the generated script |

## Placeholders

Usable in `setup`, `command`, `message`, `url` and `preLaunch`:

- `{root}`: the repo folder, shell-quoted.
- `{port}`: this pane's port.
- `{port:Role}`: another pane's port.

Inside panes, ports become shell variables such as `$MYAPP_BACKEND_PORT`, defaulting to the spec's value, so one
machine can override a port in its shell profile (`export MYAPP_BACKEND_PORT=8020`) without touching the repo. Pass
the port through to tools that accept it (`vite --port {port}`, `runserver 127.0.0.1:{port}`) so overrides take
effect. The browser URL always uses the spec's default ports.

## What every generated launcher does

- Finds the repo from its own location, so it works in any clone, fork or folder name.
- Checks for iTerm2 and the `requires` tools before doing anything.
- Replaces the window it opened last time (found by `user.launcherProject`), sending each pane Ctrl-C first so
  servers shut down cleanly, and leaves other iTerm windows alone.
- Stops only processes **listening** on the project's own ports.
- Waits for real readiness (`nc -z`) instead of sleeping.
- Tags every pane so Project Launcher can show live status without per-project settings.
