# PL1 — Claude channel plugin feasibility

Checked 2026-10-14, on `platform/pl1-channel-plugin` from main `66ff325`. Installed Claude Code: **2.1.300**. Research completed within the 30-minute limit.

**Result: a local plugin can declare Zeus's MCP server, but cannot remove the development-channel confirmation while retaining channel delivery under the default approval policy.** The blocker is channel allowlisting, not manifest packaging or the CLI version. Follow PL1-A's research-only stop condition; do not ship a plugin or change launch commands yet.

## Channel approval is separate from loading a plugin

Current [Channels documentation](https://code.claude.com/docs/en/channels#research-preview) restricts `--channels` to approved plugin/marketplace identities. The default set comes from Anthropic; Team/Enterprise administrators can supply their own `allowedChannelPlugins` managed policy. Channel availability/authentication and organization enablement are separate requirements. Neither channel flag appears in normal `--help` during preview, so absence there does not establish that an installed version lacks channels.

The [Channels reference, Package as a plugin](https://code.claude.com/docs/en/channels-reference#package-as-a-plugin) explicitly says publication to one's own marketplace still requires the development flag. The community marketplace also does not qualify. It recommends coordinating an official-marketplace listing through an Anthropic partner contact. Custom plugins and bare servers both use `--dangerously-load-development-channels`; in an interactive launch it presents the confirmation. Print/SDK mode ignores that development flag, so a `-p` probe cannot demonstrate a working bypass. A normal MCP connection or successful notification write also does not establish that Claude consumed a channel message.

**Inference:** packaging under Zeus's own app-support directory and passing `--plugin-dir` solves session-only plugin loading, but does not confer channel approval. Publishing a Zeus marketplace alone is insufficient. I found no documented signing step or launch-only self-approval flag that replaces the required allowlist. Zeus must not impersonate an approved plugin or manufacture managed policy. No such changes were attempted.

## Minimal manifest: verified locally

[Plugin manifest reference](https://code.claude.com/docs/en/plugins-reference#channels) defines `channels` entries bound to a plugin MCP server. `server` is required; `displayName` and configuration options are optional. The native server still supplies the channel capability and notifications. The manifest is under `.claude-plugin/plugin.json`; its executable is at the plugin root's `bin/zeus-mcp`:

```json
{
  "name": "zeus",
  "version": "0.1.0",
  "description": "Private Zeus channel manifest validation",
  "author": { "name": "Zeus Team" },
  "mcpServers": {
    "zeus": {
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/zeus-mcp",
      "args": ["--agent", "claude"]
    }
  },
  "channels": [{ "server": "zeus", "displayName": "Zeus" }]
}
```

I created this package **only in a disposable `/tmp` directory**, copied the worktree's already-built embedded bridge into it, and ran:

```sh
HOME="$FIXTURE/home" CLAUDE_CONFIG_DIR="$FIXTURE/home/.claude" claude --version
HOME="$FIXTURE/home" CLAUDE_CONFIG_DIR="$FIXTURE/home/.claude" claude --help
HOME="$FIXTURE/home" CLAUDE_CONFIG_DIR="$FIXTURE/home/.claude" \
  claude plugin validate "$FIXTURE/zeus" --strict --json
```

`FIXTURE` denotes the temporary directory created by the probe, not the user's home. The installed executable was resolved before constructing the isolated environment. Validation exited **0** with `success: true`, `strict: true`, and empty `errors`, `warnings`, `notes` and `advice`. The initial author-less manifest produced only an attribution warning; adding `author` removed it. Validation proves package syntax, **not runtime channel registration**. All scratch directories were removed; no tmux/model/agent session was started and no credentials or human configuration were read.

Native help confirms session-only loading:

```sh
claude --plugin-dir "$PLUGIN_DIRECTORY"
```

The [plugin overview](https://code.claude.com/docs/en/plugins) also supports local development without a marketplace. This loads plugin components for that process; it is not channel authorization.

## Channel command forms and their limits

These are documented command forms, **not successful Zeus channel launch proofs**:

```sh
# Already installed, approved plugin: no development-channel warning.
claude --channels plugin:telegram@claude-plugins-official

# Custom plugin from its actual marketplace: still the development warning.
claude --dangerously-load-development-channels plugin:zeus@zeus-marketplace

# Zeus's existing bare-server development channel: same warning.
claude --dangerously-load-development-channels server:zeus
```

`zeus-marketplace` above is an illustrative future identity, not a published or approved marketplace. No warning-free local Zeus `--channels` command was verified. No marketplace was installed into the human's saved configuration. CLI version detection alone cannot change an unapproved plugin into an approved one.

## Recommendation and scope

1. **Keep the current managed Claude tmux delivery.** It already omits the development-channel flag, preserves launch-only MCP injection and SA3 hooks, and therefore avoids this confirmation without falsely claiming channel delivery.
2. For Connect-your-own users who want no recurring development warning, recommend **Its Terminal pane**, run Claude in tmux, and omit the development-channel flag while retaining the copied SA3 hook settings. This is a different delivery method; do not simply replace the flag with an unapproved `--channels` entry and continue claiming direct delivery.
3. If direct channels become a product requirement, pursue an Anthropic official-marketplace listing/approval first. An organization-specific approved marketplace is an alternative for managed enterprise deployments, requiring the administrator's policy outside Zeus; it does not solve general consumer setup.
4. After external approval, assign implementation and an entitled live channel round-trip: a fresh profile, no development confirmation, native receipt/ack and `zeus_say`. Verify plugin tool names, compatibility, and coexistence with an already-configured Zeus server before adopting it.

PL1-B/C are not reached: the local **channel** path does not meet the requirement. No app/plugin/runtime/classifier/version-gating or SETUP.md edits, build changes, or regression tests were made. The old-dialog classifier remains intact (`ManagedPaneClassifier.swift`), and the launch/setup paths are unchanged. Build/test/live-channel gates are not claimed; this is the explicitly requested PL1-A write-up-and-stop outcome. No CONTRACT/Shared changes requested.
