#!/usr/bin/env python3
"""MCP server exposing request_access(path, mode, duration, reason, source_user).

Asks Jacek with a kdialog window (5 minute timeout), then calls claude-share on approval.
Paths to external tools come from environment variables so this file stays plain Python,
with no Nix-specific syntax - the Nix module (mcp-server.nix) sets SHARE_BIN, NOTIFY_SEND,
KDIALOG, TIMEOUT and SUDO when it starts this script.
"""

import argparse
import os
import subprocess

from mcp.server.fastmcp import FastMCP

SUDO = os.environ.get("SUDO", "sudo")
SHARE_BIN = os.environ["SHARE_BIN"]
RUN_COMMAND_BIN = os.environ.get("RUN_COMMAND_BIN", "")
SH = os.environ.get("SH", "/bin/sh")  # absolute path - sudo resets PATH, "sh" alone won't resolve
ALLOWED_COMMAND_TARGETS = [t for t in os.environ.get("ALLOWED_COMMAND_TARGETS", "").split(",") if t]
ALLOWED_SOURCE_ACCOUNTS = [t for t in os.environ.get("ALLOWED_SOURCE_ACCOUNTS", "").split(",") if t]
NOTIFY_SEND = os.environ.get("NOTIFY_SEND", "notify-send")
KDIALOG = os.environ.get("KDIALOG", "kdialog")
TIMEOUT = os.environ.get("TIMEOUT", "timeout")

parser = argparse.ArgumentParser()
parser.add_argument("--target-user", required=True)
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--allow-commands", action="store_true")
args = parser.parse_args()

mcp = FastMCP(f"access-{args.target_user}", host="127.0.0.1", port=args.port)


@mcp.tool()
def request_access(
    path: str, mode: str, duration: str = "1h", reason: str = "", source_user: str = "Jacek"
) -> str:
    """Ask Jacek for temporary access to a file or directory from one of his accounts.

    path: path to the file/directory, under that account's own allowed roots.
    mode: "view" (read-only on the original), "edit" (read+write on the original)
          or "copy" (permanent copy, never expires).
    duration: how long, e.g. "30min", "2h", "1d" - ignored for mode "copy".
    reason: short justification, shown to Jacek in the approval dialog.
    source_user: whose files - "Jacek" (default) or one of Jacek's other accounts
                 (game_user, zeroroot, dev_user, secure_user, browse_user). Always shown
                 explicitly in the approval dialog - Jacek sees exactly whose files are being
                 asked for, never just an unlabeled path.
    """
    if mode not in ("view", "edit", "copy"):
        return f"error: bad mode '{mode}' (view|edit|copy)"
    if source_user not in ALLOWED_SOURCE_ACCOUNTS:
        return f"error: source_user must be one of {ALLOWED_SOURCE_ACCOUNTS}"

    description = f"Claude is requesting {mode} access to {source_user}'s files:\n{path}"
    if mode != "copy":
        description += f"\nFor: {duration}"
    if reason:
        description += f"\nReason: {reason}"

    subprocess.run(
        [NOTIFY_SEND, "-u", "critical", "-a", "Claude", "Access request", description],
        check=False,
    )

    try:
        result = subprocess.run([TIMEOUT, "300", KDIALOG, "--yesno", description], check=False)
    except FileNotFoundError:
        return "error: kdialog is not available for Jacek"

    if result.returncode == 124:
        return "denied: no response within 5 minutes (timeout)"
    if result.returncode != 0:
        return "denied: Jacek rejected the request"

    command = [SUDO, "-n", SHARE_BIN, "add", mode, source_user, args.target_user, path]
    if mode != "copy":
        command.append(duration)
    result2 = subprocess.run(command, capture_output=True, text=True, check=False)
    if result2.returncode != 0:
        return f"error after approval: {result2.stderr.strip()}"
    return f"approved: {result2.stdout.strip()}"


if args.allow_commands:

    @mcp.tool()
    def request_command(command: str, as_user: str, reason: str = "") -> str:
        """Ask Jacek to run a shell command as another, already-sandboxed account on his behalf.

        command: the exact shell command to run - shown verbatim to Jacek before he decides.
        as_user: which account runs it. Must be one of the already-isolated, low-privilege
                 accounts (never root, never Jacek - this path is a single approval click, not
                 a general escalation channel).
        reason: short justification, shown to Jacek in the approval dialog.
        """
        if as_user not in ALLOWED_COMMAND_TARGETS:
            return f"error: as_user must be one of {ALLOWED_COMMAND_TARGETS}"

        description = f"Claude wants to run AS {as_user}:\n{command}"
        if reason:
            description += f"\nReason: {reason}"

        subprocess.run(
            [NOTIFY_SEND, "-u", "critical", "-a", "Claude", "Command request", description],
            check=False,
        )

        try:
            result = subprocess.run([TIMEOUT, "300", KDIALOG, "--yesno", description], check=False)
        except FileNotFoundError:
            return "error: kdialog is not available for Jacek"

        if result.returncode == 124:
            return "denied: no response within 5 minutes (timeout)"
        if result.returncode != 0:
            return "denied: Jacek rejected the request"

        result2 = subprocess.run(
            [SUDO, "-n", "-u", as_user, RUN_COMMAND_BIN, "--", SH, "-c", command],
            capture_output=True,
            text=True,
            check=False,
        )
        output = (result2.stdout + result2.stderr).strip()
        return f"ran as {as_user} (exit {result2.returncode}): {output}"


mcp.run(transport="streamable-http")
