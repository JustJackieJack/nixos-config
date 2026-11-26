# CLAUDE.md for the claude account - loads in EVERY claude-session, regardless of working
# directory (it's this account's own ~/.claude/CLAUDE.md, not a project file). Generated
# declaratively so it never drifts out of sync with the rest of this module.
{ config, lib, pkgs, ... }:
let
  # The actual text lives in ./CLAUDE.md as a plain markdown file (readable/editable directly,
  # no Nix syntax). The only value that genuinely depends on Nix config - the access-mcp port -
  # is written there as the placeholder @ACCESS_MCP_PORT@ and substituted here.
  claudeInstructions = lib.replaceStrings [ "@ACCESS_MCP_PORT@" ] [
    (toString config.moje.claude.accessMcpPort)
  ] (builtins.readFile ./CLAUDE.md);
in
{
  # Rewritten on every rebuild (deps=users: /home/claude must already exist). Also merges an
  # "access" MCP server entry into this account's ~/.claude.json - merging (jq), not
  # overwriting, since that file also holds Claude Code's own state (account, trusted projects).
  #
  # Note: there is no group named "claude" - like every isNormalUser account, claude's primary
  # group is "users" (gid 100), not a same-named group. -g claude / chown claude:claude would
  # silently fail every single time (install/chown just error out on the unknown group) - caught
  # by the VM test once this script's error checking was made strict enough to surface it.
  config.system.activationScripts.claudeInstructions = {
    deps = [ "users" ];
    text = ''
      install -d -m 0755 -o claude -g users /home/claude/.claude \
        || { echo "claudeInstructions: install -d .claude failed" >&2; exit 1; }
      install -m 0644 -o claude -g users ${pkgs.writeText "claude-instructions.md" claudeInstructions} /home/claude/.claude/CLAUDE.md \
        || { echo "claudeInstructions: install CLAUDE.md failed" >&2; exit 1; }

      mcpFile="/home/claude/.claude.json"
      if [ ! -f "$mcpFile" ]; then
        echo '{}' > "$mcpFile" || { echo "claudeInstructions: init $mcpFile failed" >&2; exit 1; }
      fi
      mcpTmp="$(mktemp)" || { echo "claudeInstructions: mktemp failed" >&2; exit 1; }
      ${pkgs.jq}/bin/jq \
        '.mcpServers.access = {"type":"http","url":"http://127.0.0.1:${toString config.moje.claude.accessMcpPort}/mcp"}' \
        "$mcpFile" > "$mcpTmp" \
        || { echo "claudeInstructions: jq failed, mcpFile content: $(cat "$mcpFile" 2>&1)" >&2; exit 1; }
      mv -f "$mcpTmp" "$mcpFile" || { echo "claudeInstructions: mv failed" >&2; exit 1; }
      chown claude "$mcpFile" || { echo "claudeInstructions: chown failed" >&2; exit 1; }
      chmod 0600 "$mcpFile" || { echo "claudeInstructions: chmod failed" >&2; exit 1; }
    '';
  };
}
