# A permanent view for Jacek into a fixed set of the claude account's config files (read/write
# for most, read-only for CLAUDE.md - see the `items` list below for why).
# Convenience only - Jacek already has full root access via sudo (security.sudo-rs.extraRules
# in default.nix), so this adds no new security boundary, just a nice stable folder instead of
# `claude-home`/`sudo -u claude`.
#
# Mounts are declared through NixOS's native `fileSystems` bind-mount support - the same
# mechanism already used for the NAS share in system/backups.nix - instead of a custom mounting
# script. Re-establishing a mount at every boot is something NixOS already does for every
# ordinary filesystem; writing a bespoke systemd service to do the same thing would just
# duplicate that. ACLs, unlike mounts, are stored on disk and persist across reboots on their
# own, so they only need to be granted once, in the activation script below (safe to leave in
# every rebuild: setfacl just re-asserts the same entries, it isn't additive).
{ lib, pkgs, ... }:
let
  targetDir = "/home/shared/ClaudeFiles";

  # `name` is the subpath under both the real claude location and $targetDir.
  # `kind`: "dir" shares the whole directory (new files inside appear immediately - it's a
  # live view, not a snapshot); "file" shares exactly that one file.
  # `access`: "rw" (default for everything except CLAUDE.md) or "ro".
  #
  # CLAUDE.md is "ro", not left out entirely: instructions.nix's activation script rewrites it
  # from the repo's modules/users/claude/CLAUDE.md on every boot (not just every rebuild -
  # activation scripts re-run on every boot too), by design, so it never drifts from what the
  # repo declares. That only breaks WRITES through this mount (an edit here would silently be
  # lost at the next reboot) - reads are always fine, since you'd just see whatever the current
  # boot's freshly-regenerated content is anyway. To change the content, edit
  # modules/users/claude/CLAUDE.md in the repo and rebuild.
  items = [
    {
      name = "CLAUDE.md";
      source = "/home/claude/.claude/CLAUDE.md";
      kind = "file";
      access = "ro";
    }
    {
      name = "ssh";
      source = "/home/claude/.ssh";
      kind = "dir";
      access = "rw";
    }
    {
      name = "skills";
      source = "/home/claude/.claude/skills";
      kind = "dir";
      access = "rw";
    }
    {
      name = "claude.json";
      source = "/home/claude/.claude.json";
      kind = "file";
      access = "rw";
    }
    {
      # Claude Code's own permission allow/deny lists for this account (Bash command patterns
      # etc.) - not created by any other script here, unlike CLAUDE.md/claude.json, so the
      # activation script below creates it (as empty JSON) the first time it's missing.
      name = "settings.json";
      source = "/home/claude/.claude/settings.json";
      kind = "file";
      access = "rw";
    }
    {
      name = "rules";
      source = "/home/claude/.claude/rules";
      kind = "dir";
      access = "rw";
    }
    {
      name = "agents";
      source = "/home/claude/.claude/agents";
      kind = "dir";
      access = "rw";
    }
    {
      name = "commands";
      source = "/home/claude/.claude/commands";
      kind = "dir";
      access = "rw";
    }
  ];

  adminAccessFileSystems = lib.listToAttrs (
    map (item: {
      name = "${targetDir}/${item.name}";
      value = {
        device = item.source;
        fsType = "none";
        # "x-systemd.mkdir" makes the generated mount unit create the (empty) mountpoint
        # itself, once, immediately before mounting - NOT via a tmpfiles rule. A tmpfiles "d"
        # rule re-applies its mode/owner on every boot even if the path already exists, and
        # since a bind mount shares one inode under two paths, that re-application would land
        # on the REAL, already-mounted source and silently reassign it to Jacek - exactly what
        # happened here (caught by the VM test: new files from claude became unwritable).
        options = [
          "bind"
          "nofail"
          "x-systemd.mkdir"
        ]
        ++ lib.optional (item.access == "ro") "ro";
      };
    }) items
  );
in
{
  # Exposed separately from `fileSystems` itself so the VM test can add these mounts to
  # `virtualisation.fileSystems` without referencing `config.fileSystems` - that option is
  # itself set FROM `virtualisation.fileSystems` via mkVMOverride in NixOS's qemu-vm module, so
  # reading it back here would be a real circular dependency, not just an awkward one.
  options.moje.claude.adminAccessFileSystems = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    default = adminAccessFileSystems;
    description = "The ClaudeFiles bind-mount fileSystems entries, for tests/vm.nix to merge into virtualisation.fileSystems.";
  };

  config = {
    # Make sure every mountpoint placeholder exists before the generated bind-mount units try to
    # use it. This is safe via tmpfiles because systemd-tmpfiles-setup.service runs as a normal
    # unit, ordered well before local-fs mounts - unlike activationScripts below, which run much
    # earlier (as part of switch-root, before systemd starts ANY normal unit including tmpfiles).
    # The SOURCE paths under /home/claude are therefore NOT created here - tmpfiles wouldn't have
    # run yet when the activation script below needs them; they're created inline in that script
    # instead. Getting this backwards once made `setfacl` fail on a missing directory during
    # switch-root, which froze the boot entirely instead of just failing a check - caught by the
    # VM test.
    # Group is "users", not "Jacek" - like claude, Jacek's isNormalUser account has no
    # same-named group either (confirmed: config.users.users.Jacek.group == "users"). Only the
    # top-level targetDir needs a tmpfiles rule - the 7 per-item mountpoints are created by the
    # mount units themselves (via "x-systemd.mkdir" above), not here. A "d" tmpfiles rule for
    # them would re-apply its mode/owner on every boot regardless of the path already being a
    # live mount, silently reassigning the real, shared inode behind it - see the comment above.
    systemd.tmpfiles.rules = [
      "d ${targetDir} 0700 Jacek users -"
      "L+ /home/Jacek/Claude - - - - ${targetDir}"
    ];

    # The actual mounts. NixOS generates one systemd mount unit per entry and re-mounts them at
    # every boot, exactly like any other filesystem - nothing custom to maintain. "nofail" means a
    # missing source degrades to "this one item isn't mounted this boot" instead of blocking boot.
    fileSystems = adminAccessFileSystems;

    # ACLs persist on disk - this only ever needs to run once, but is safe to re-run every
    # rebuild. Granted on the REAL source paths (not the mount targets, which share the same
    # inode/ACL anyway) so it also covers access through the original /home/claude/... path.
    # Directories get BOTH a recursive grant (covers files already there) and a default ACL
    # (`-d`, inherited by anything created or re-saved-via-rename inside later) - answers "will
    # new or edited files keep working": yes, because new entries automatically inherit the
    # default ACL regardless of who created them.
    #
    # Runs after "users" (so /home/claude exists) and after "claudeInstructions" (so
    # CLAUDE.md/.claude.json - created by that script, not by us - already exist too). Directory
    # items have no other script creating them, so this one creates them itself, right before
    # setfacl, rather than depending on `systemd.tmpfiles.rules` (which hasn't run yet at this
    # point in boot - see the comment above).
    system.activationScripts.jacekClaudeAccess = {
      deps = [
        "users"
        "claudeInstructions"
      ];
      text = lib.concatMapStringsSep "\n" (
        item:
        let
          aclMode = if item.access == "ro" then "rX" else "rwX";
        in
        if item.kind == "dir" then
          ''
            install -d -m 0755 -o claude -g users -- "${item.source}" \
              || { echo "jacekClaudeAccess: install -d failed for ${item.source}" >&2; exit 1; }
            ${pkgs.acl}/bin/setfacl -R -m "u:Jacek:${aclMode}" -- "${item.source}" \
              || { echo "jacekClaudeAccess: setfacl failed for ${item.source}" >&2; exit 1; }
            ${pkgs.acl}/bin/setfacl -d -m "u:Jacek:${aclMode}" -- "${item.source}" \
              || { echo "jacekClaudeAccess: default setfacl failed for ${item.source}" >&2; exit 1; }
          ''
        else
          ''
            if [ ! -f "${item.source}" ]; then
              install -d -m 0755 -o claude -g users -- "$(dirname -- "${item.source}")" \
                || { echo "jacekClaudeAccess: install -d (parent) failed for ${item.source}" >&2; exit 1; }
              echo '{}' > "${item.source}" \
                || { echo "jacekClaudeAccess: create failed for ${item.source}" >&2; exit 1; }
              chown claude -- "${item.source}" \
                || { echo "jacekClaudeAccess: chown failed for ${item.source}" >&2; exit 1; }
              chmod 0644 -- "${item.source}" \
                || { echo "jacekClaudeAccess: chmod failed for ${item.source}" >&2; exit 1; }
            fi
            ${pkgs.acl}/bin/setfacl -m "u:Jacek:${aclMode}" -- "${item.source}" \
              || { echo "jacekClaudeAccess: setfacl failed for ${item.source}" >&2; exit 1; }
          ''
      ) items;
    };
  };
}
