# CLAUDE.md for the `claude` account

Generated from `modules/users/claude/`. Do not edit the deployed copy by hand - changes are
lost on the next `nixos-rebuild switch`. Edit this file in the repo instead. Loads in EVERY
`claude-session`, regardless of working directory.

## Isolation model

This account (`claude`, UID 1001) has NO access to `/home/Jacek` - Jacek's home is mode 700,
no exceptions. In particular these are unreachable (even on request): `.ssh`, `.gnupg`,
KWallet/keyrings, Firefox/Thunderbird, Bitwarden, Discord, `gh` (GitHub CLI), Docker,
Remmina, `.config/sops`, SMB credentials, Jacek's Chromium, VSCode globalStorage.

You have FULL network access (OpenSnitch rule `010-claude`) and can see ALL system processes
and the full systemd journal (`journalctl`) - this is intentional ("auditor" role), don't
treat it as a loophole into files.

## Getting access to one of Jacek's files

Don't try to work around the isolation - it won't work anyway (see the source in
`modules/users/claude/sharing.nix`). Two paths:

1. **Jacek does it by hand**: `claude-view`/`claude-edit`/`claude-copy PATH`. The result
   lands under `/home/shared/Views/claude/...` (view/edit - temporary, expires on its
   own) or `/home/shared/Copies/claude/...` (copy - permanent, until Jacek deletes it).
2. **Ask yourself**: the MCP tool `request_access(path, mode, duration, reason, source_user)`
   on the server at `http://127.0.0.1:@ACCESS_MCP_PORT@/mcp` (registered in this account's
   `~/.claude.json` as "access"). Jacek gets a `kdialog` window (5 minute limit) - approves
   or rejects. `mode`: `view` (read-only on the original), `edit` (WRITES to the original,
   visible to Jacek immediately), `copy` (permanent copy, your edits never reach the original).
   `source_user`: whose files - defaults to `Jacek`, or one of his other accounts (`game_user`,
   `zeroroot`, `dev_user`, `secure_user`, `browse_user`) if you need something from one of
   those instead. The dialog Jacek sees always names the source account explicitly - he's
   deciding "give claude access to THIS account's file", not just "give claude a file".

## Running a command as another sandboxed account

The same server also exposes `request_command(command, as_user, reason)`. `as_user` must be
one of `game_user`, `zeroroot`, `dev_user` - never `root`, never `Jacek` (that would be a
one-click full escalation, not help from one sandbox to another). Jacek sees the exact command
text in the `kdialog` prompt before deciding - there's no second check after he approves, so
don't expect this to be useful for anything you wouldn't want him reading verbatim.

## SSH

This account has its OWN SSH identity under `~/.ssh` - never Jacek's keys (you won't get
them even on request - `claude-view`/`claude-edit`/`claude-copy`/`claude-share` keep `.ssh`
on Jacek's permanent blocklist). If `~/.ssh/id_ed25519` doesn't exist, ask Jacek to run
`sudo -u claude ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519` and add the public key on the
target server.

## MCP servers and skills for this account

- Shared with the repo: `.mcp.json` in the working directory (visible to both accounts,
  because the repo lives under `/home/shared`).
- For this account only: `~/.claude.json` (personal MCP servers) and `~/.claude/skills/`
  (skills). Managed by Jacek through `claude-home` (an interactive shell as this account) or
  `sudo -u claude <command>`.
