#!/usr/bin/env python3
"""Generate standalone iTerm dev launchers from a launcher spec.

    launcher.py render SPEC.json --repo DIR   write DIR/<launcher>.applescript and compile DIR/<launcher>.app
    launcher.py regenerate LAUNCHER           rebuild a launcher from the spec embedded at its top
    launcher.py extract LAUNCHER              print the embedded spec (works on .applescript and .app)
    launcher.py validate SPEC.json            check a spec without writing anything

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


def embedded_block(spec: dict) -> str:
    # AppleScript block comments nest, so "(*" and "*)" inside the JSON must not appear literally.
    body = json.dumps(spec, indent=2, ensure_ascii=False).replace("(*", "(\\u002a").replace("*)", "\\u002a)")
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
        add(f"\tset missingTools to loginShell(projectRoot, {applescript_string(f'for t in {tools}; do command -v \"$t\" >/dev/null || printf \"%s \" \"$t\"; done')})")
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
        add("\t-- Optional panes turn on with an environment variable (from your shell or the project's env files).")
        env_files = " ".join(
            f'[ -f {shell_quote(f)} ] && . {shell_quote(f)};' for f in spec.get("env", []) + [e for p in spec["panes"] for e in p.get("env", [])]
        )
        for pane in conditional:
            variable = pane["enabledBy"]
            check = f'set -a; {env_files} set +a; case "${{{variable}:-}}" in 1|true|TRUE|yes|on) echo on;; esac'
            add(f"\tset {pane_variable(pane)}Enabled to (loginShell(projectRoot, {applescript_string(check)}) is \"on\")")

    add("")
    add("\ttell application \"Finder\" to set screenBounds to bounds of window of desktop")
    add("")
    add('\ttell application "iTerm"')
    add("\t\tactivate")
    add("\t\t-- Rerunning replaces this project's window; other iTerm windows are untouched. Each pane gets Ctrl-C")
    add("\t\t-- first: closing alone leaves servers that ignore hang-ups (redis-server) running.")
    add("\t\trepeat with existingWindow in windows")
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


def browser_gate(spec: dict) -> str | None:
    """The pane whose port the URL points at, e.g. "Frontend" for http://localhost:{port:Frontend}/."""
    for pane in spec["panes"]:
        if "port" in pane and (f"{{port:{pane['role']}}}" in spec["url"] or f":{pane['port']}" in spec["url"]):
            return pane["role"]
    return None


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
    regenerate_cmd = commands.add_parser("regenerate", help="rebuild a launcher from its embedded spec")
    regenerate_cmd.add_argument("launcher", type=Path)
    regenerate_cmd.add_argument("--no-compile", action="store_true")
    extract_cmd = commands.add_parser("extract", help="print a launcher's embedded spec")
    extract_cmd.add_argument("launcher", type=Path)
    validate_cmd = commands.add_parser("validate", help="check a spec")
    validate_cmd.add_argument("spec", type=Path)
    args = parser.parse_args(argv)

    try:
        if args.command == "render":
            source, app = write_launcher(load_spec(args.spec), args.repo.resolve(), compile_app=not args.no_compile)
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
    except (SpecError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
