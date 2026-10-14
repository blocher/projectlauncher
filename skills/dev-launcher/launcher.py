#!/usr/bin/env python3
"""Generate standalone iTerm dev launchers from a launcher spec.

    launcher.py render SPEC.json --repo DIR   write DIR/<launcher>.applescript and compile DIR/<launcher>.app
    launcher.py regenerate LAUNCHER           rebuild a launcher from the spec embedded at its top
    launcher.py extract LAUNCHER              print the embedded spec (works on .applescript and .app)
    launcher.py validate SPEC.json            check a spec without writing anything
    launcher.py detect DIR [--taken PORTS]    draft a spec for a repo from its files (no network, no Claude)
    launcher.py analyze DIR [--taken PORTS]   draft a spec with Claude Code (`claude -p`, read-only tools)

The generated launcher needs nothing but macOS and iTerm2: no Python, no Project Launcher, no Claude.
See SPEC.md next to this file for the spec format. Standard library only, so it runs on any Mac with Python 3.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SPEC_VERSION = 1
BEGIN_MARK = "PROJECT-LAUNCHER-SPEC"
END_MARK = "END-PROJECT-LAUNCHER-SPEC"
PROJECT_TAG = "user.launcherProject"
PANE_TAG = "user.launcherPane"
PLACEHOLDER = re.compile(r"\{(root|port)(?::([^{}]+))?\}")


class SpecError(Exception):
    pass


# MARK: - Spec


def load_spec(path: Path) -> dict:
    try:
        spec = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SpecError(f"Couldn't read {path}: {error}") from error
    validate(spec)
    return spec


def validate(spec: dict) -> None:
    def fail(message: str) -> None:
        raise SpecError(message)

    if spec.get("spec") != SPEC_VERSION:
        fail(f'"spec" must be {SPEC_VERSION}')
    for key in ("id", "name"):
        if not isinstance(spec.get(key), str) or not spec[key].strip():
            fail(f'"{key}" is required')
    if not re.fullmatch(r"[A-Za-z0-9_-]+", spec["id"]):
        fail('"id" can only contain letters, numbers, - and _')
    panes = spec.get("panes")
    if not isinstance(panes, list) or not panes:
        fail('"panes" must list at least one pane')
    roles = [pane.get("role") for pane in panes]
    if any(not isinstance(role, str) or not role.strip() for role in roles):
        fail("every pane needs a role")
    if len(set(roles)) != len(roles):
        fail("pane roles must be unique")
    if panes[0].get("enabledBy"):
        fail("the first pane can't be conditional (enabledBy)")
    ports = [pane["port"] for pane in panes if "port" in pane]
    if any(not isinstance(port, int) or not 1 <= port <= 65535 for port in ports):
        fail("ports must be numbers between 1 and 65535")
    if len(set(ports)) != len(ports):
        fail("each pane needs its own port")
    for name in ("focus", "openWhenReady"):
        if spec.get(name) and spec[name] not in roles:
            fail(f'"{name}" names a pane that doesn\'t exist: {spec[name]}')
    gate = spec.get("openWhenReady")
    if gate and "port" not in panes[roles.index(gate)]:
        fail(f'"openWhenReady" pane {gate} has no port')

    def check_text(where: str, text: object, pane: dict | None = None) -> None:
        if not isinstance(text, str):
            fail(f"{where} must be text")
        if "\n" in text or "\r" in text:
            fail(f"{where} must be a single line")
        for match in PLACEHOLDER.finditer(text):
            if match.group(1) != "port":
                continue
            target = match.group(2)
            if target is None and (pane is None or "port" not in pane):
                fail(f"{where} uses {{port}} outside a pane that has a port; name one with {{port:Role}}")
            if target is not None and (target not in roles or "port" not in panes[roles.index(target)]):
                fail(f"{where} refers to {{port:{target}}}, which isn't a pane with a port")

    for index, step in enumerate(spec.get("preLaunch", [])):
        check_text(f"preLaunch step {index + 1}", step.get("run") if isinstance(step, dict) else step)
    for line in spec.get("setup", []):
        check_text("setup", line)
    if spec.get("url"):
        check_text("url", spec["url"])
    for pane in panes:
        where = f'pane "{pane["role"]}"'
        for line in pane.get("setup", []):
            check_text(where, line, pane)
        if "command" in pane:
            check_text(where, pane["command"], pane)
        message = pane.get("message", [])
        for line in message if isinstance(message, list) else [message]:
            check_text(f"{where} message", line, pane)
        for target in pane.get("waitFor", []):
            if target not in roles or "port" not in panes[roles.index(target)]:
                fail(f"{where} waits for {target}, which isn't a pane with a port")
        if pane.get("color") and not re.fullmatch(r"#[0-9A-Fa-f]{6}", pane["color"]):
            fail(f"{where} color must look like #RRGGBB")
        enabled_by = pane.get("enabledBy")
        if enabled_by is not None:
            variable = enabled_by.get("variable") if isinstance(enabled_by, dict) else enabled_by
            if not isinstance(variable, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", variable):
                fail(f"{where} enabledBy must name an environment variable")
            if isinstance(enabled_by, dict) and not all(isinstance(f, str) for f in enabled_by.get("files", [])):
                fail(f"{where} enabledBy files must be paths")


def launcher_name(spec: dict) -> str:
    if spec.get("launcher"):
        return spec["launcher"]
    words = re.findall(r"[A-Za-z0-9]+", spec["name"])
    return "Start" + "".join(word[:1].upper() + word[1:] for word in words) + "Dev"


def port_variable(spec: dict, role: str) -> str:
    """Per-machine override, e.g. ZOOMYNOTES_BACKEND_PORT=8019 in your shell profile."""
    return re.sub(r"[^A-Z0-9]+", "_", f"{spec['id']}_{role}_PORT".upper())


# MARK: - AppleScript rendering


def applescript_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def shell_quote(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


def expression(spec: dict, text: str, pane: dict | None, *, for_shell: bool = True) -> str:
    """An AppleScript expression for one line of text: placeholders become the repo root (quoted for the shell)
    or the port's shell variable, so per-machine overrides apply inside panes."""
    parts: list[str] = []
    position = 0
    for match in PLACEHOLDER.finditer(text):
        literal = text[position:match.start()]
        if match.group(1) == "root":
            if literal:
                parts.append(applescript_string(literal))
            parts.append("quoted form of projectRoot" if for_shell else "projectRoot")
        else:
            role = match.group(2) or pane["role"]
            target = next(p for p in spec["panes"] if p["role"] == role)
            value = f"${port_variable(spec, role)}" if for_shell else str(target["port"])
            parts.append(applescript_string(literal + value))
        position = match.end()
    tail = text[position:]
    if tail or not parts:
        parts.append(applescript_string(tail))
    return " & ".join(parts)


def pane_lines(spec: dict, pane: dict) -> list[str]:
    """The shell lines typed into a pane, as AppleScript expressions."""
    lines: list[str] = []
    folder = pane.get("dir", ".").strip("/") or "."
    target = "projectRoot" if folder == "." else f"(projectRoot & {applescript_string('/' + folder)})"
    lines.append(f'"cd " & quoted form of {target}')

    ports = [p for p in spec["panes"] if "port" in p]
    if ports:
        exports = " ".join(f"{port_variable(spec, p['role'])}=${{{port_variable(spec, p['role'])}:-{p['port']}}}" for p in ports)
        lines.append(applescript_string(f"export {exports}"))

    for env_file in spec.get("env", []) + pane.get("env", []):
        path = f"(projectRoot & {applescript_string('/' + env_file.lstrip('/'))})"
        lines.append(f'"set -a; [ -f " & quoted form of {path} & " ] && . " & quoted form of {path} & "; set +a"')
    for line in spec.get("setup", []) + pane.get("setup", []):
        lines.append(expression(spec, line, pane))

    if pane.get("color"):
        red, green, blue = (int(pane["color"][i:i + 2], 16) for i in (1, 3, 5))
        escape = "".join(f"\\033]6;1;bg;{name};brightness;{value}\\a" for name, value in (("red", red), ("green", green), ("blue", blue)))
        lines.append(applescript_string(f"printf '{escape}'"))

    if "port" in pane and pane.get("freePort", True):
        variable = f"${port_variable(spec, pane['role'])}"
        # Listeners only: clients connected to the port (browsers, other projects) are left alone.
        lines.append(applescript_string(
            f'pids=$(lsof -t -iTCP:{variable} -sTCP:LISTEN 2>/dev/null); [ -z "$pids" ] || '
            f'{{ kill $pids 2>/dev/null; sleep 0.5; pids=$(lsof -t -iTCP:{variable} -sTCP:LISTEN 2>/dev/null); '
            f'[ -z "$pids" ] || kill -9 $pids 2>/dev/null; }}; true'
        ))
    for role in pane.get("waitFor", []):
        variable = f"${port_variable(spec, role)}"
        lines.append(applescript_string(
            f"printf 'Waiting for {role} on port %s…\\n' {variable}; "
            f"until nc -z 127.0.0.1 {variable} 2>/dev/null; do sleep 0.3; done"
        ))
    if pane.get("message"):
        # printf reuses its format for every argument, so each line of the message is printed on its own line.
        message = pane["message"] if isinstance(pane["message"], list) else [pane["message"]]
        arguments = " & \" \" & ".join(f"quoted form of ({expression(spec, line, pane, for_shell=False)})" for line in message)
        lines.append(f'"printf \'%s\\\\n\' " & {arguments}')
    if pane.get("command"):
        lines.append(expression(spec, pane["command"], pane))
    return lines


SPEC_KEYS = ["spec", "id", "name", "description", "launcher", "url", "openWhenReady", "focus", "requires", "env", "setup", "preLaunch", "panes"]
PANE_KEYS = ["role", "note", "dir", "port", "freePort", "env", "setup", "waitFor", "enabledBy", "color", "message", "command"]


def canonical(spec: dict) -> dict:
    """Key order for the embedded spec, so it reads the same whoever wrote it (a person, the app, Claude)."""
    def ordered(item: dict, keys: list[str]) -> dict:
        return {key: item[key] for key in keys if key in item} | {key: value for key, value in item.items() if key not in keys}
    result = ordered(spec, SPEC_KEYS)
    result["panes"] = [ordered(pane, PANE_KEYS) for pane in spec["panes"]]
    return result


def embedded_block(spec: dict) -> str:
    # AppleScript block comments nest, so "(*" and "*)" inside the JSON must not appear literally.
    body = json.dumps(canonical(spec), indent=2, ensure_ascii=False).replace("(*", "(\\u002a").replace("*)", "\\u002a)")
    return (
        f"(*\n{BEGIN_MARK} v{SPEC_VERSION}: generated by Project Launcher (https://github.com/blocher/projectlauncher).\n"
        "Edit this spec and regenerate (`launcher.py regenerate` on this file, or Regenerate in Project Launcher);\n"
        "hand edits to the script below are overwritten when it's regenerated.\n"
        f"{body}\n{END_MARK}\n*)"
    )


def render(spec: dict) -> str:
    validate(spec)
    name = spec["name"]
    out: list[str] = [embedded_block(spec), ""]
    add = out.append

    description = spec.get("description") or f"{name} development environment"
    add(f"-- {description}: one iTerm window, one stacked pane per service.")
    add(f"property projectID : {applescript_string(spec['id'])}")
    add("")
    add("on run")
    add("\t-- The repo is the folder holding this launcher, so it works in any clone or fork.")
    add('\tset projectRoot to do shell script "dirname " & quoted form of (POSIX path of (path to me))')
    add("")

    add("\tif not iTermInstalled() then")
    add('\t\tdisplay alert "iTerm2 is required" message "Install it from https://iterm2.com, then run this launcher again."')
    add("\t\treturn")
    add("\tend if")
    requires = spec.get("requires", [])
    if requires:
        tools = " ".join(shell_quote(tool) for tool in requires)
        check = 'for t in ' + tools + '; do command -v "$t" >/dev/null || printf "%s " "$t"; done'
        add(f"\tset missingTools to loginShell(projectRoot, {applescript_string(check)})")
        add('\tif missingTools is not "" then')
        add(f'\t\tdisplay alert ({applescript_string(name + " needs ")} & missingTools) message "Install the missing tools (they must be on your login shell\'s PATH), then run this launcher again."')
        add("\t\treturn")
        add("\tend if")

    for index, step in enumerate(spec.get("preLaunch", [])):
        step = step if isinstance(step, dict) else {"run": step}
        command = expression(spec, step["run"], None)
        add("")
        add(f"\t-- Pre-launch step {index + 1}{': ' + step['label'] if step.get('label') else ''}")
        if step.get("background"):
            add(f"\tdo shell script \"/bin/zsh -lc \" & quoted form of (\"cd \" & quoted form of projectRoot & \"; (\" & {command} & \") >/dev/null 2>&1 &\")")
        else:
            add("\ttry")
            add(f"\t\tloginShell(projectRoot, {command})")
            add("\ton error errorText")
            label = step.get("label") or f"Pre-launch step {index + 1}"
            add(f'\t\tdisplay alert {applescript_string(label + " failed")} message errorText buttons {{"Cancel", "Continue Anyway"}} cancel button "Cancel"')
            add("\tend try")

    conditional = [pane for pane in spec["panes"] if pane.get("enabledBy")]
    if conditional:
        add("")
        add("\t-- Optional panes turn on with an environment variable: from your shell first, else from env files.")
        for pane in conditional:
            add(f"\tset {pane_variable(pane)}Enabled to (loginShell(projectRoot, {applescript_string(enabled_check(spec, pane))}) is \"on\")")

    add("")
    add("\ttell application \"Finder\" to set screenBounds to bounds of window of desktop")
    add("")
    add('\ttell application "iTerm"')
    add("\t\tactivate")
    add("\t\t-- Rerunning replaces this project's window; other iTerm windows are untouched. Each pane gets Ctrl-C")
    add("\t\t-- first: closing alone leaves servers that ignore hang-ups (redis-server) running. Loop over a snapshot:")
    add("\t\t-- closing a window while looping over the live list shifts it, so the next window would be skipped.")
    add("\t\tset allWindows to windows")
    add("\t\trepeat with existingWindow in allWindows")
    add("\t\t\ttry")
    add(f"\t\t\t\ttell current session of current tab of existingWindow to set existingTag to variable named {applescript_string(PROJECT_TAG)}")
    add("\t\t\t\tif existingTag is my projectID then")
    add("\t\t\t\t\trepeat with existingSession in sessions of current tab of existingWindow")
    add("\t\t\t\t\t\ttell existingSession to write text (character id 3) newline no")
    add("\t\t\t\t\tend repeat")
    add("\t\t\t\t\tdelay 1.5")
    add("\t\t\t\t\tclose existingWindow")
    add("\t\t\t\tend if")
    add("\t\t\tend try")
    add("\t\tend repeat")
    add("")
    add("\t\tset devWindow to (create window with default profile)")
    add("\t\tset bounds of devWindow to {0, 0, (item 3 of screenBounds) * 0.75, item 4 of screenBounds}")

    for index, pane in enumerate(spec["panes"]):
        variable = pane_variable(pane)
        add("")
        add(f"\t\t-- {pane['role']}{': ' + pane['note'] if pane.get('note') else ''}")
        indent = "\t\t"
        if pane.get("enabledBy"):
            add(f"\t\tif {variable}Enabled then")
            indent = "\t\t\t"
        if index == 0:
            add(f"{indent}set {variable} to current session of devWindow")
        else:
            add(f"{indent}tell lastPane to set {variable} to (split horizontally with default profile)")
        add(f"{indent}tell {variable}")
        add(f"{indent}\tset variable named {applescript_string(PROJECT_TAG)} to my projectID")
        add(f"{indent}\tset variable named {applescript_string(PANE_TAG)} to {applescript_string(pane['role'])}")
        add(f"{indent}\tset name to {applescript_string(name + ' · ' + pane['role'])}")
        for line in pane_lines(spec, pane):
            add(f"{indent}\twrite text {line}")
        add(f"{indent}end tell")
        add(f"{indent}set lastPane to {variable}")
        if pane.get("enabledBy"):
            add("\t\tend if")

    if spec.get("focus"):
        focus = next(pane for pane in spec["panes"] if pane["role"] == spec["focus"])
        add("")
        add(f"\t\t-- Leave {focus['role']} selected.")
        add(f"\t\tselect {pane_variable(focus)}")
    add("\tend tell")

    if spec.get("url"):
        url = expression(spec, spec["url"], None, for_shell=False)
        gate_role = spec.get("openWhenReady") or browser_gate(spec)
        add("")
        add("\t-- Open the app in the default browser once its server answers.")
        if gate_role:
            gate_port = next(p["port"] for p in spec["panes"] if p["role"] == gate_role)
            wait = f"for i in $(seq 1 240); do nc -z 127.0.0.1 {gate_port} 2>/dev/null && break; sleep 0.5; done; "
        else:
            wait = "sleep 2; "
        add(f'\tdo shell script "(" & {applescript_string(wait)} & "open " & quoted form of ({url}) & ") >/dev/null 2>&1 &"')
    add("end run")

    add("")
    add("on iTermInstalled()")
    add("\ttry")
    add('\t\tdo shell script "open -Ra iTerm"')
    add("\t\treturn true")
    add("\ton error")
    add("\t\treturn false")
    add("\tend try")
    add("end iTermInstalled")
    add("")
    add("-- Runs a command in a login shell at the repo root, so tools on the user's PATH (Homebrew, nvm, uv) are found.")
    add("on loginShell(projectRoot, command)")
    add('\treturn do shell script "/bin/zsh -lc " & quoted form of ("cd " & quoted form of projectRoot & " && " & command)')
    add("end loginShell")
    return "\n".join(out) + "\n"


def enabled_check(spec: dict, pane: dict) -> str:
    """Shell that prints "on" when the pane's variable is 1/true/yes/on (any case). The shell's own environment wins;
    otherwise KEY=value lines are read from the env files. They're parsed rather than sourced, since real .env files
    aren't always valid shell."""
    enabled_by = pane["enabledBy"]
    if isinstance(enabled_by, dict):
        variable, files = enabled_by["variable"], enabled_by.get("files", [])
    else:
        variable, files = enabled_by, spec.get("env", []) + pane.get("env", [])
    pattern = f"^[[:space:]]*(export[[:space:]]+)?{variable}[[:space:]]*="
    reads = "".join(
        f'[ -z "$v" ] && [ -f {shell_quote(f)} ] && v=$(grep -E {shell_quote(pattern)} {shell_quote(f)} | tail -n 1 | cut -d= -f2-); '
        for f in files
    )
    return (
        f'v="${{{variable}:-}}"; {reads}'
        f"""v=$(printf '%s' "$v" | tr -d "\\"' " | tr '[:upper:]' '[:lower:]'); """
        'case "$v" in 1|true|yes|on) echo on;; esac; true'
    )


def browser_gate(spec: dict) -> str | None:
    """The pane whose port the URL points at, e.g. "Frontend" for http://localhost:{port:Frontend}/."""
    for pane in spec["panes"]:
        if "port" in pane and (f"{{port:{pane['role']}}}" in spec["url"] or f":{pane['port']}" in spec["url"]):
            return pane["role"]
    return None


# MARK: - Ports


# Ports that common tools (Django, Vite, Create React App, Redis, RabbitMQ, ElasticMQ/SQS…) and long-established
# projects grab by default; generated launchers never use them. Project Launcher also reserves every
# project's own ports (its config `ports` and generated launchers).
COMMON_PORTS = {3000, 3001, 4200, 5000, 5173, 5174, 5672, 6379, 8000, 8001, 8080, 8443, 8888, 9000, 9324, 9325}
PORT_RANGES = {"backend": range(8010, 8100), "frontend": range(5180, 5300), "redis": range(6390, 6500), "other": range(8100, 8200)}


class PortAllocator:
    """Hands out the lowest free port of each kind, skipping ports other projects and common tools use."""

    def __init__(self, taken: set[int]):
        self.taken = set(taken) | COMMON_PORTS

    def next(self, kind: str) -> int:
        for port in PORT_RANGES[kind]:
            if port not in self.taken:
                self.taken.add(port)
                return port
        raise SpecError(f"no free {kind} port left in {PORT_RANGES[kind]}")


# MARK: - Detection

SKIP_DIRS = {"node_modules", ".git", ".venv", "venv", "env", "dist", "build", "__pycache__", ".next", "coverage", "ios", "android", "vendor"}


def _find(root: Path, name: str, depth: int = 2) -> list[Path]:
    found = []
    for path in sorted(root.rglob(name)):
        relative = path.relative_to(root)
        if len(relative.parts) - 1 <= depth and not SKIP_DIRS.intersection(relative.parts):
            found.append(path)
    return found


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="ignore")
    except OSError:
        return ""


def _python_deps(root: Path) -> str:
    text = ""
    for pattern in ("requirements*.txt", "pyproject.toml", "Pipfile", "setup.py", "setup.cfg"):
        for path in _find(root, pattern, depth=2):
            text += _read(path).lower() + "\n"
    return text


def _relative(root: Path, path: Path) -> str:
    relative = path.relative_to(root).as_posix()
    return "." if relative in ("", ".") else relative


def detect(root: Path, taken: set[int]) -> dict:
    """Drafts a spec from a repo's files. Covers common stacks; anything it can't place goes into `notes`."""
    root = root.resolve()
    ports = PortAllocator(taken)
    notes: list[str] = []
    words = re.findall(r"[A-Za-z0-9]+", root.name)
    name = " ".join(word[:1].upper() + word[1:] for word in words) or root.name
    spec: dict = {"spec": SPEC_VERSION, "id": re.sub(r"[^a-z0-9]+", "", root.name.lower()) or "project", "name": name}
    panes: list[dict] = []
    requires: list[str] = []
    python_deps = _python_deps(root)

    # Python environment.
    venv = next((d for d in (".venv", "venv", "env", "backend/.venv") if (root / d / "bin/activate").exists()), None)
    uses_uv = (root / "uv.lock").exists() or any(_find(root, "uv.lock", depth=1))
    python_setup = [f"source {{root}}/{venv}/bin/activate"] if venv else []
    run_python = "python" if venv or not uses_uv else "uv run python"
    if uses_uv and not venv:
        requires.append("uv")
    env_files = [".env"] if (root / ".env").exists() or (root / ".env.example").exists() else []

    # Redis, wanted by Celery or the app.
    wants_redis = "redis" in python_deps or any("redis" in _read(p).lower() for p in _find(root, "package.json", depth=2))
    redis_pane = None
    if wants_redis:
        redis_pane = {"role": "Redis", "note": "Local broker on a project-specific port", "port": ports.next("redis"),
                      "command": "redis-server --port {port} --save '' --appendonly no"}
        panes.append(redis_pane)
        requires.append("redis-server")
        notes.append(f"Added a project-only Redis on port {redis_pane['port']}. Point the app's broker/cache URL "
                     f"(e.g. CELERY_BROKER_URL or REDIS_URL) at redis://127.0.0.1:{redis_pane['port']} for local dev.")

    # Django backend.
    managers = [m for m in _find(root, "manage.py", depth=2) if "django" in _read(m).lower()]
    backend = None
    if managers:
        manage = managers[0]
        backend = {"role": "Backend", "note": "Django API", "dir": _relative(root, manage.parent), "port": ports.next("backend"),
                   "setup": list(python_setup), "env": env_files,
                   "command": f"{run_python} manage.py migrate && {run_python} manage.py runserver 127.0.0.1:{{port}}"}
        if redis_pane:
            backend["waitFor"] = ["Redis"]
        panes.append(backend)
    elif (root / "bin/rails").exists():
        backend = {"role": "Backend", "note": "Rails server", "port": ports.next("backend"), "env": env_files,
                   "command": "bin/rails db:prepare && bin/rails server -p {port}"}
        panes.append(backend)
    elif "fastapi" in python_deps or "uvicorn" in python_deps:
        module = next((p for p in _find(root, "main.py", depth=2) if "FastAPI(" in _read(p)), None)
        if module:
            folder = module.parent
            backend = {"role": "Backend", "note": "FastAPI app", "dir": _relative(root, folder), "port": ports.next("backend"),
                       "setup": list(python_setup), "env": env_files,
                       "command": f"{run_python} -m uvicorn main:app --reload --host 127.0.0.1 --port {{port}}"}
            panes.append(backend)
        else:
            notes.append("Found FastAPI/uvicorn but not the app module; add the Backend pane's command by hand.")

    # Celery worker next to a Django project.
    if "celery" in python_deps and backend and managers:
        celery_app = next((p.parent.name for p in _find(root, "celery.py", depth=3)), None)
        if celery_app:
            beat = "--beat " if ("celery_beat" in python_deps or "beat_schedule" in python_deps) else ""
            queue = {"role": "Queue", "note": "Celery worker", "dir": backend["dir"], "setup": list(python_setup), "env": env_files,
                     "command": f"{'uv run ' if run_python.startswith('uv') else ''}celery -A {celery_app} worker {beat}--loglevel=INFO"}
            if redis_pane:
                queue["waitFor"] = ["Redis"]
            panes.append(queue)
        else:
            notes.append("Celery is a dependency but no celery.py was found; add a Queue pane by hand if needed.")

    # JavaScript frontend (or a Node backend when there's no other backend).
    package_files = [p for p in _find(root, "package.json", depth=1) if '"dev"' in _read(p)]
    frontend_dirs = ("frontend", "app", "client", "web", "ui", ".")
    package_files.sort(key=lambda p: frontend_dirs.index(_relative(root, p.parent)) if _relative(root, p.parent) in frontend_dirs else 99)
    if package_files:
        package = package_files[0]
        text = _read(package)
        folder = package.parent
        manager = "pnpm" if (folder / "pnpm-lock.yaml").exists() or (root / "pnpm-lock.yaml").exists() else \
                  "yarn" if (folder / "yarn.lock").exists() and not (folder / "package-lock.json").exists() else "npm"
        requires.append(manager)
        run = f"{manager} run dev" if manager != "yarn" else "yarn dev"
        separator = " --" if manager == "npm" else ""
        if '"next"' in text:
            command, note = f"{run}{separator} -p {{port}}", "Next.js dev server"
        elif '"vite"' in text:
            command, note = f"{run}{separator} --port {{port}} --strictPort", "Vite dev server"
        else:
            command, note = f"PORT={{port}} {run}", "Dev server (reads PORT)"
            notes.append(f"{_relative(root, folder)}/package.json's dev script isn't Vite or Next; check it honours PORT.")
        kind = "frontend" if backend or '"vite"' in text or '"next"' in text else "backend"
        panes.append({"role": "Frontend" if kind == "frontend" else "Backend", "note": note, "dir": _relative(root, folder),
                      "port": ports.next(kind), "command": command})

    if not any("port" in pane and pane["role"] != "Redis" for pane in panes):
        notes.append("No backend or frontend server was recognized; add panes by hand or try Improve with Claude.")

    panes.append({"role": "Working", "command": "git status"})
    for pane in panes:
        for key in ("setup", "env"):
            if key in pane and not pane[key]:
                del pane[key]
        if pane.get("dir") == ".":
            del pane["dir"]
    spec["panes"] = panes
    web = next((p for p in panes if p["role"] == "Frontend"), None) or next((p for p in panes if p["role"] == "Backend" and "port" in p), None)
    if web:
        spec["url"] = f"http://localhost:{{port:{web['role']}}}/"
        spec["focus"] = web["role"]
    if requires:
        spec["requires"] = sorted(set(requires))
    validate(spec)
    return {"spec": spec, "notes": notes, "configChanges": []}



# MARK: - Analysis with Claude Code

ANALYSIS_SCHEMA = {
    "type": "object",
    "properties": {
        "spec": {"type": "object"},
        "notes": {"type": "array", "items": {"type": "string"}},
        "configChanges": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"path": {"type": "string"}, "find": {"type": "string"}, "replace": {"type": "string"}, "why": {"type": "string"}},
                "required": ["path", "find", "replace", "why"],
            },
        },
    },
    "required": ["spec", "notes", "configChanges"],
}


def claude_path() -> str | None:
    search = os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local/bin"), str(Path.home() / ".claude/local")])
    return shutil.which("claude", path=search)


def analyze(root: Path, taken: set[int]) -> dict:
    """Asks Claude Code (read-only tools) to draft the spec, starting from the rule-based draft."""
    root = root.resolve()
    claude = claude_path()
    if not claude:
        raise SpecError("Claude Code isn't installed (no `claude` command). Install it, or use detect.")
    here = Path(__file__).resolve().parent
    starting_point = detect(root, taken)
    ports = PortAllocator(taken)
    offered = {kind: [ports.next(kind) for _ in range(3)] for kind in ("backend", "frontend", "redis")}
    prompt = "\n\n".join([
        (here / "ANALYZE.md").read_text(),
        "## Spec format (SPEC.md)\n\n" + (here / "SPEC.md").read_text(),
        f"## Ports offered\n\n{json.dumps(offered)}\n\nPorts already used by other projects (don't use): {sorted(taken)}",
        "## Rule-based draft to start from (verify and improve it)\n\n" + json.dumps(starting_point, indent=2),
    ])
    command = [claude, "-p", "--output-format", "json", "--no-session-persistence", "--tools", "Read,Glob,Grep",
               "--json-schema", json.dumps(ANALYSIS_SCHEMA)]
    # Run as a fresh, standalone session. Inside another Claude Code session (e.g. the skill), its private
    # variables would make this child attach to the parent and refuse to start.
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("CLAUDE", "CLAUDECODE"))}
    if "CLAUDECODE" in os.environ:
        environment.pop("ANTHROPIC_BASE_URL", None)
    try:
        result = subprocess.run(command, input=prompt, cwd=root, env=environment, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired as error:
        raise SpecError("Claude didn't finish within 10 minutes") from error
    try:
        envelope = json.loads(result.stdout)
    except json.JSONDecodeError:
        envelope = None
    if result.returncode != 0 or not isinstance(envelope, dict) or envelope.get("is_error"):
        reason = (envelope or {}).get("result") if isinstance(envelope, dict) else None
        reason = str(reason or result.stderr or result.stdout).strip()
        if "not logged in" in reason.lower() or "/login" in reason:
            raise SpecError("Claude Code isn't signed in on this Mac. Run `claude` in a terminal, sign in with /login, then try again.")
        raise SpecError(f"Claude couldn't analyze the repo: {reason[:400]}")
    try:
        draft = envelope.get("structured_output") or envelope.get("result")
        if isinstance(draft, str):
            draft = json.loads(draft[draft.index("{"):draft.rindex("}") + 1])
    except (json.JSONDecodeError, ValueError, AttributeError) as error:
        raise SpecError(f"Couldn't read Claude's answer: {result.stdout.strip()[:300]}") from error
    try:
        validate(draft["spec"])
    except (SpecError, KeyError, TypeError) as error:
        raise SpecError(f"Claude's draft isn't a valid spec ({error}); the rule-based draft still works") from error
    draft.setdefault("notes", [])
    draft.setdefault("configChanges", [])
    return draft


def apply_config_changes(root: Path, changes: list[dict]) -> list[str]:
    """Applies exact find/replace edits. Each must match exactly once; nothing is written unless all of them do."""
    root = root.resolve()
    pending: dict[Path, str] = {}
    for change in changes:
        path = (root / change["path"]).resolve()
        if root not in path.parents:
            raise SpecError(f"{change['path']} is outside the repo")
        text = pending.get(path) if path in pending else _read(path)
        count = text.count(change["find"])
        if count != 1:
            raise SpecError(f"{change['path']}: expected the text to change once, found it {count} times")
        pending[path] = text.replace(change["find"], change["replace"])
    for path, text in pending.items():
        path.write_text(text)
    return [_relative(root, path) for path in pending]


def pane_variable(pane: dict) -> str:
    words = re.findall(r"[A-Za-z0-9]+", pane["role"])
    return "pane" + "".join(word[:1].upper() + word[1:] for word in words)


# MARK: - Files


def extract(path: Path) -> dict:
    """Reads the spec embedded in a launcher's .applescript, or its compiled .app."""
    if path.suffix == ".app" or path.is_dir():
        sibling = path.with_suffix(".applescript")
        if sibling.exists():
            text = sibling.read_text()
        else:
            script = path / "Contents/Resources/Scripts/main.scpt"
            text = subprocess.run(["/usr/bin/osadecompile", str(script)], capture_output=True, text=True, check=True).stdout
    else:
        text = path.read_text()
    match = re.search(rf"{BEGIN_MARK} v(\d+)[^\n]*\n(?:[^\n]*\n){{2}}(.*?)\n{END_MARK}", text, re.S)
    if not match:
        raise SpecError(f"{path} has no embedded launcher spec (it wasn't generated by Project Launcher)")
    spec = json.loads(match.group(2))
    validate(spec)
    return spec


def write_launcher(spec: dict, repo: Path, *, compile_app: bool = True) -> tuple[Path, Path | None]:
    name = launcher_name(spec)
    source = repo / f"{name}.applescript"
    source.write_text(render(spec))
    if not compile_app:
        return source, None
    app = repo / f"{name}.app"
    with tempfile.TemporaryDirectory() as scratch:
        built = Path(scratch) / f"{name}.app"
        result = subprocess.run(["/usr/bin/osacompile", "-o", str(built), str(source)], capture_output=True, text=True)
        if result.returncode != 0:
            raise SpecError(f"osacompile failed:\n{result.stderr.strip()}")
        # End PkgInfo with a newline before signing: end-of-file pre-commit hooks would otherwise add one and break
        # the signature.
        pkginfo = built / "Contents/PkgInfo"
        if pkginfo.exists() and not pkginfo.read_bytes().endswith(b"\n"):
            pkginfo.write_bytes(pkginfo.read_bytes() + b"\n")
        # Keep a custom icon from the previous launcher, if it had one.
        old_icon = app / "Contents/Resources/applet.icns"
        if old_icon.exists():
            shutil.copy2(old_icon, built / "Contents/Resources/applet.icns")
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(built)], capture_output=True, check=True)
        if app.exists():
            shutil.rmtree(app)
        shutil.move(str(built), app)
    return source, app


# MARK: - CLI


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    render_cmd = commands.add_parser("render", help="write and compile a launcher from a spec")
    render_cmd.add_argument("spec", type=Path)
    render_cmd.add_argument("--repo", type=Path, required=True, help="the project's root folder")
    render_cmd.add_argument("--no-compile", action="store_true", help="only write the .applescript")
    render_cmd.add_argument("--json", action="store_true", help="print the written paths as JSON")
    regenerate_cmd = commands.add_parser("regenerate", help="rebuild a launcher from its embedded spec")
    regenerate_cmd.add_argument("launcher", type=Path)
    regenerate_cmd.add_argument("--no-compile", action="store_true")
    extract_cmd = commands.add_parser("extract", help="print a launcher's embedded spec")
    extract_cmd.add_argument("launcher", type=Path)
    validate_cmd = commands.add_parser("validate", help="check a spec")
    validate_cmd.add_argument("spec", type=Path)
    apply_cmd = commands.add_parser("apply", help="apply reviewed configChanges (JSON list) to a repo")
    apply_cmd.add_argument("changes", type=Path)
    apply_cmd.add_argument("--repo", type=Path, required=True)
    for command in ("detect", "analyze"):
        sub = commands.add_parser(command, help="draft a spec for a repo" + (" with Claude Code" if command == "analyze" else ""))
        sub.add_argument("repo", type=Path)
        sub.add_argument("--taken", default="", help="comma-separated ports other projects already use")
    args = parser.parse_args(argv)

    try:
        if args.command == "render":
            source, app = write_launcher(load_spec(args.spec), args.repo.resolve(), compile_app=not args.no_compile)
            if args.json:
                print(json.dumps({"source": str(source), "app": str(app) if app else None}))
            else:
                print(source)
                if app:
                    print(app)
        elif args.command == "regenerate":
            launcher = args.launcher.resolve()
            spec = extract(launcher)
            source, app = write_launcher(spec, launcher.parent, compile_app=not args.no_compile)
            print(source)
            if app:
                print(app)
        elif args.command == "extract":
            print(json.dumps(extract(args.launcher.resolve()), indent=2, ensure_ascii=False))
        elif args.command == "validate":
            load_spec(args.spec)
            print("ok")
        elif args.command == "apply":
            for path in apply_config_changes(args.repo, json.loads(args.changes.read_text())):
                print(path)
        elif args.command in ("detect", "analyze"):
            taken = {int(port) for port in args.taken.split(",") if port.strip().isdigit()}
            draft = detect(args.repo, taken) if args.command == "detect" else analyze(args.repo, taken)
            print(json.dumps(draft, indent=2, ensure_ascii=False))
    except (SpecError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
