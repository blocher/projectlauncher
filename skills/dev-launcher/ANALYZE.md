# Analyze a repo for a dev launcher

You are drafting a **launcher spec** (format: SPEC.md) for the repository in the current directory, so a standalone
iTerm launcher can start its whole local dev environment: one stacked pane per service, plus a Working shell last.

Work read-only: inspect files, never modify anything.

## Find

1. **Services to run locally:** backend API servers, frontend dev servers, queues and workers (Celery, RQ, Sidekiq,
   BullMQ…), schedulers (Celery beat), and local infrastructure the app expects (Redis, a tunnel). Use the
   project's own scripts, README, Procfile/Procfile.dev, docker-compose services, package.json scripts, Makefile
   targets and settings files. Prefer how the README says to run it locally over guesses.
2. **Environment setup each pane needs:** virtualenv activation (`.venv`, `venv`, `env`) or `uv run`, nvm/Node
   version, dotenv files to load, required environment variables for local dev.
3. **Dependencies between panes:** which panes must wait for another's port (e.g. a worker waits for Redis).
4. **Ports.** Give every server its own port from the **ports offered** below (backend, frontend, redis), never a
   common default (8000, 5173, 3000, 6379…). Pass ports through on the command line (`runserver 127.0.0.1:{port}`,
   `vite --port {port} --strictPort`, `next dev -p {port}`, `redis-server --port {port}`) so per-machine overrides work.
5. **What has to change in the project for those ports**, as `configChanges`: exact single-occurrence find/replace
   edits to local-dev config only, e.g.:
   - Vite `server.port` and proxy targets,
   - Django `CORS_ALLOWED_ORIGINS` / `CSRF_TRUSTED_ORIGINS` dev defaults,
   - `.env.example` URLs,
   - broker URLs pointing at the project's own Redis port.

   Never touch production or deployment config (nginx, systemd, Dockerfiles, deploy scripts, production env files)
   or secrets in `.env`. Leave `configChanges` empty when nothing needs to change.

## Rules for the spec

- Use `{port}`, `{port:Role}` and `{root}` placeholders rather than literal ports or absolute paths.
- Roles are short and unique: Backend, Frontend, Queue, Beat, Redis, Working…
- One-off commands that must finish first (installing dependencies, generating certificates) go in `preLaunch`.
- Helpful tips for the Working shell go in its `message` (a list of lines).
- `requires` lists the command-line tools the panes need on PATH.
- Set `url` to the page a developer opens, and `focus` to that pane.
- Put anything uncertain, and anything the developer must do by hand, in `notes`.

## Output

Return JSON with exactly these keys:

```json
{
  "spec": { "spec": 1, "id": "…", "name": "…", "panes": [ … ] },
  "notes": ["…"],
  "configChanges": [ { "path": "frontend/vite.config.ts", "find": "port: 5173,", "replace": "port: 5181,", "why": "…" } ]
}
```

`path` is relative to the repo root. `find` must appear exactly once in that file and be copied character for
character, including whitespace.
