#!/usr/bin/env python3
"""MCP server exposing request_access(path, mode, duration, reason).

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
NOTIFY_SEND = os.environ.get("NOTIFY_SEND", "notify-send")
KDIALOG = os.environ.get("KDIALOG", "kdialog")
TIMEOUT = os.environ.get("TIMEOUT", "timeout")

parser = argparse.ArgumentParser()
parser.add_argument("--target-user", required=True)
parser.add_argument("--port", required=True, type=int)
args = parser.parse_args()

mcp = FastMCP(f"access-{args.target_user}", host="127.0.0.1", port=args.port)


@mcp.tool()
def request_access(path: str, mode: str, duration: str = "1h", reason: str = "") -> str:
    """Ask Jacek for temporary access to a file or directory from his account.

    path: path to the file/directory (must be under /home/Jacek).
    mode: "view" (read-only on the original), "edit" (read+write on the original)
          or "copy" (permanent copy, never expires).
    duration: how long, e.g. "30min", "2h", "1d" - ignored for mode "copy".
    reason: short justification, shown to Jacek in the approval dialog.
    """
    if mode not in ("view", "edit", "copy"):
        return f"error: bad mode '{mode}' (view|edit|copy)"

    description = f"Claude is requesting {mode} access to:\n{path}"
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

    command = [SUDO, "-n", SHARE_BIN, "add", mode, "Jacek", args.target_user, path]
    if mode != "copy":
        command.append(duration)
    result2 = subprocess.run(command, capture_output=True, text=True, check=False)
    if result2.returncode != 0:
        return f"error after approval: {result2.stderr.strip()}"
    return f"approved: {result2.stdout.strip()}"


mcp.run(transport="streamable-http")
