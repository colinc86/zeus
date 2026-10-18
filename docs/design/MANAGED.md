# Managed assistant session: design spec (M3)

Zeus runs the user's assistant itself (CONTRACT §11). This spec covers Settings → Assistant, the menu bar, the session-name affordance, the blocked-prompt card and the default launch prompt. Appdev builds it (M4) on `ManagedSessionControlling` and `ManagedSessionConfig`.

Everything here uses ZeusDesign. The new pieces are in `ZeusManagedSession.swift`:

| Piece | Use |
|---|---|
| `ZeusManagedState` | Mirrors `ManagedSessionStatus` one to one; map it, don't reinterpret it. |
| `ZeusManagedPresentation.make(_:agent:folder:session:now:)` | Every string for a state: title, detail, menu status, buttons, VoiceOver label. |
| `ZeusManagedCopy` | The default launch prompt, Zeus's first message, the blocked card, captions. |
| `ZeusManagedStatusPanel` | The status box: indicator, title, detail, attach command with Copy, buttons. |
| `ZeusStatusIndicator` | Hollow square (off) · three dots (busy) · green square (ok) · red "!" (attention). |
| `ZeusCommandRow` | A copyable command in a field, with Copy → "Copied". |
| `ZeusChoiceList` / `ZeusChoice` | Radio rows with a tag and a detail line: agent and permission mode. |
| `ZeusCheckboxStyle` | Pixel checkbox for "Start when Zeus opens". |
| `ZeusPalette.positive` | New green for the running indicator (≥ 3:1 on the panel in all four palettes). |

Mockups: `docs/design/managed-m3-settings.png`, `managed-m3-states.png`, `managed-m3-blocked.png`. Regenerate every look with `scripts/design-harness/render.sh "managedSessionMockups()"` (→ `build/q2-renders/managed-*`). The gallery, `ZeusManagedSessionGallery`, is the reference layout.

## 1. Settings → Assistant

Rename the **Agent** tab to **Assistant**. At the top, a two-button switch (`ZeusButtonStyle` small, the selected one primary):

- **Zeus runs it**: the managed session (this spec). The default on first run.
- **Connect your own**: today's Agent tab content (backend, delivery, sessions, setup commands, test message), unchanged.

Quiet hours stays at the bottom of the tab in both modes, with the **Morning brief** section (PA1, AGENT_LEARNING.md §8.4) directly above it in both modes. The switch is `ManagedSessionConfig.enabled`. Switching to **Connect your own** while the session runs asks inline, under the switch: "Stop Claude Code and use your own session instead?" with **Stop and Switch** (destructive) and **Cancel**. Switching back never auto-starts; the user presses Start.

The managed pane, top to bottom (`managed-m3-settings.png`). Section titles use `.zeusFont(.title)` in `palette.title`; captions use `.caption` in `secondaryText`.

1. **Status panel**: `ZeusManagedStatusPanel(.make(state, …), attachCommand: managedAttachCommand, note:, onAction:, onCopy:)`.
   - Buttons per state come from the presentation (§2); the first is primary.
   - `note`:
     - `ZeusManagedCopy.restartToApply` when agent, folder or permission mode changed while it runs. Then also put **Restart** first.
     - Otherwise, `managedRequirementsProblem(for:)` when tmux is missing. Start is disabled until it's fixed.
   - Start is also disabled until a folder is chosen; the detail then reads "Choose a folder to start." in place of the Off detail.
2. **Agent**: `ZeusChoiceList` of Claude Code, Codex and OpenCode.
   - The detail is the installed version, or the install hint from `managedRequirementsProblem(for:)`, with the row disabled.
3. **Folder**: the path abbreviated with `~` in field chrome, plus **Choose…** (NSOpenPanel, directories only).
   - Caption: "It works here, and reads this folder's CLAUDE.md or AGENTS.md." Say AGENTS.md alone for Codex and OpenCode.
4. **Permissions**: `ZeusChoiceList` from `permissionModes(for: agent)`, in that order.
   - Each row's detail is the mode's `detail`. `isDefault` gets tag "Default".
   - `isUnrestricted` gets tag "Unrestricted" plus the warning marker.
   - Choosing the unrestricted mode confirms inline under the list: "<Mode> lets <Agent> run any command and change any file you can, without asking." **Use Unrestricted** (destructive), **Cancel**.
   - Caption: "<Agent>'s own modes. When it asks, Zeus shows a card that opens Terminal."
5. **Instructions**: the launch prompt in a `TextEditor` with `ZeusFieldChromeModifier`, about 8 lines tall, scrolling. Under it:
   - the caption `ZeusManagedCopy.launchPromptNote`;
   - **Start a New Conversation**, which confirms inline: "Start a new conversation? <Agent> starts fresh with these instructions." with **Start New** and **Cancel**, then calls `startNewManagedConversation()`;
   - **Reset to Default**, disabled when the text equals `ZeusManagedCopy.defaultLaunchPrompt`.
   - Editing never restarts anything.
6. **Start when Zeus opens**: `Toggle(…).toggleStyle(ZeusCheckboxStyle())`. On by default once a folder is chosen.

Settings keeps its `.system` font choice; every piece works in both fonts and all four palettes (see the renders).

### 1.1 Permission mode copy (M3b)

Each row keys on `ManagedPermissionMode.id` from `ManagedAgentLaunch.policies(for:)`. Platform replaces its `title` and `detail` with this copy; the IDs, arguments, `isDefault` and `isUnrestricted` stay as they are.

Copy rules:
- Titles are plain words. No flags, and no "(unrestricted)" in the title: `ZeusChoiceList` adds the tag "Default" for `isDefault` and "Unrestricted" with the warning marker for `isUnrestricted`.
- The detail is one sentence: what it does on its own, and what it still asks about or refuses.
- The CLI flags move to the row's tooltip (`.help`) for people who want them.
- List order is the order below: default first, then from most cautious to most free, with unrestricted modes last.

**Claude Code**

The managed launch injects Zeus for this launch only and sends messages through its owned Terminal pane. Claude Code 2.1.296's development-channel name check does not include `--mcp-config` servers, so the managed launch does not request that unusable channel or show its consent warning. Existing sessions or Connect your own may still show **WARNING: Loading development channels**: Zeus treats it as blocked and opens Terminal; the user chooses **I am using this for local development** (option 1). That warning is per launch, not a saved permission. Zeus never selects it automatically.

| Mode ID | Title | Detail |
|---|---|---|
| `manual` | Ask first | Asks before editing files or running commands. |
| `plan` | Plan only | Looks around and proposes a plan; asks before acting on it. |
| `dontAsk` | Never ask | Does only what you've already allowed; refuses the rest without asking. |
| `acceptEdits` | Accept edits | Edits files without asking; asks before other commands. |
| `auto` | Auto | A safety check approves routine actions; asks about the rest. Some models fall back to Ask first. |
| `bypassPermissions` | Bypass permissions | Never asks. It can run any command and change any file you can. Confirm once in Terminal the first time. |

**Codex** (exactly these five, PM decision 2026-10-13)

| Mode ID | Title | Detail |
|---|---|---|
| `workspace-write/on-request` | Ask when needed | Works in this folder; asks before going outside it. |
| `read-only/on-request` | Read only | Reads files but doesn't change them; asks before anything more. |
| `approve-for-me` | Approve for me | Works in this folder; a safety check answers its requests for you. |
| `danger-full-access/on-request` | Full access | No sandbox: it can change any file you can. Still asks before risky commands. |
| `yolo` | YOLO | No sandbox and no approvals at all. It can run any command and change any file you can. |

**OpenCode**

| Mode ID | Title | Detail |
|---|---|---|
| `ask` | Ask | Asks before using a tool you haven't allowed. Your own permission rules still apply. |
| `deny` | Deny | Refuses any tool you haven't allowed, without asking. |
| `allow` | Allow all | Uses any tool you haven't denied, without asking. |
| `auto` | Auto | Approves every request by itself; only tools you've denied are refused. |

All three agents add the same footnote under the list: "Logins and folder-trust prompts always wait for you in Terminal." It covers what every mode leaves to the user, so the details don't repeat it.

## 2. States

From `ZeusManagedPresentation.make`. Buttons are listed primary first.

| State | Indicator | Title | Detail | Buttons | Menu status |
|---|---|---|---|---|---|
| off | hollow | Off | Zeus isn't running your assistant. | Start | Your assistant is off |
| starting | dots | Starting… | Opening <Agent> in tmux session “zeus”. | Open in Terminal, Stop | Starting <Agent>… |
| running idle | green | Running | <Agent> is ready in <folder>. | Open in Terminal, Restart, Stop | (usual) |
| running working | green | Working | <Agent> is working in <folder>. | same | (usual) |
| running unknown | green | Running | <Agent> is running in <folder>. | same | (usual) |
| blocked(reason) | red ! | Waiting for you in Terminal | the dialog's first line | Open in Terminal, Stop | <Agent> is waiting for you in Terminal |
| stopped | hollow | Stopped | <Agent> exited. Zeus won't restart it until you start it. | Start | <Agent> is stopped |
| restarting(at) | dots | Restarting in N s | <Agent> quit unexpectedly. Zeus will resume the same conversation. | Restart Now, Stop | Restarting <Agent>… |
| failed(reason) | red ! | Couldn't keep it running | the reason | Try Again, Open in Terminal | Zeus couldn't keep <Agent> running |

- **Unavailable buttons stay visible, disabled, in place** (M4-QA, answering appdev). Pass them in `ZeusManagedStatusPanel(disabledActions:)`, e.g. `[.start]` before a folder is chosen or while tmux is missing, and put the reason in `note`. Never hide the primary button or draw a substitute outside the panel. A stable layout shows what the next step is, and VoiceOver still reaches the button as dimmed.
- **Restart goes first for a pending settings change only in running and starting.** In blocked and failed, Open in Terminal and Try Again stay primary: the prompt or the failure needs the user first.
- Restart Now maps to `restartManagedSession()` and Try Again to `startManagedSession()`.
- Refresh the countdown once a second while Settings is visible (`TimelineView(.periodic(…, by: 1))` around the panel).
- The indicator's dots hold still under Reduce Motion and when `zeusAnimationsActive` is false.
- VoiceOver reads the panel's status as one element: `presentation.accessibilityLabel`.

## 3. Session name affordance

The tmux session is shown inside its attach command, never as a bare name: `ZeusManagedCopy.attachCaption` ("Watch or type to it in Terminal:") then `ZeusManagedCopy.attachCommand(session:socket:)` with **Copy**. That command is `tmux attach -t zeus` with the actual session name, so it's right after a name collision (`zeus-2`) too; tmux prefers the exact name. No `=` prefix: zsh expands a word that starts with `=`, so the copied command would fail (M9). `-S <socket>` appears only when the server isn't tmux's default, and never `env -u` (L10). **Open in Terminal** keeps the runtime's robust form (socket, pane, cleared TMUX variables) internally. Docs point to this command rather than a fixed name (A4N-1). Copy turns into "Copied" until the command changes. **Open in Terminal** sits in the panel's buttons. The row is hidden while off, or before a session exists.

## 4. Menu bar

While `ManagedSessionConfig.enabled`:

- **Status line** (first item): always `presentation.menuStatus`, which describes the managed assistant in every state (L13). Running reads "Claude Code is ready", "Claude Code is working…" or "Claude Code is running" (`ZeusManagedCopy.runningMenuStatus`). Another session's activity never replaces it (L11). An agent's own `zeus_set_status` detail may replace the working line.
- **Unread:** its own line under the status line ("3 new messages"). It never replaces the status line.
- **Icon:** blocked and failed use `MenuBarIconAlert`.
- **Items**, after the status line and before "Hide for 1 Hour", followed by a divider:
  - **Open in Terminal**: when a tmux session exists.
  - **Start Assistant**: when off or stopped. **Try Again**: when failed, as in the status panel (D3-11).
  - **Restart Assistant** and **Stop Assistant**: when starting, running, blocked or restarting.

  Titles come from `Action.menuTitle`. Copying the attach command stays in Settings; the menu stays short.

```
Claude Code is waiting for you in Terminal
Open in Terminal
Restart Assistant
Stop Assistant
───────────────
Hide for 1 Hour
…
```

## 5. Blocked-prompt card

From `ZeusManagedCopy.blockedCard(agent:dialog:)`, posted by the managed session at `high` priority (gold frame; the avatar shows `alert`).

- **Title:** "<Agent> is waiting for you in Terminal".
- **Body:** point first: "When Zeus can read the question, the card shows it with the agent's own choices as buttons; you pick, Zeus presses exactly that choice. Otherwise: "Answer it in Terminal." Zeus never answers these on its own, and holds your messages until it's done." Then the dialog's first 5 non-empty lines as a fenced code block, exactly as the agent printed them.
- **One option:** "Open in Terminal", primary, id `open-terminal`. It calls `openManagedSessionInTerminal()` and does **not** answer or close the card. It isn't a reply, so nothing is delivered to the agent.
- **When the block clears**, the card closes itself: muted, options hidden, body replaced by "Answered in Terminal" (`blockedCardResolved`). A later block posts a new card; one block never posts twice.
- **As a peek,** the first lines show the instruction and the start of the dialog (`managed-m3-blocked.png`).

## 6. Launch prompt and first message

`ZeusManagedCopy.defaultLaunchPrompt` is the default for `ManagedSessionConfig.launchPrompt` (about 1,800 characters; a test keeps it under 2,400). It tells the agent:

- it's the user's personal assistant, shown as a desktop avatar;
- how to use `zeus_say`, `zeus_ask`, `zeus_present` and `zeus_set_status` (and to reset status to `auto`);
- to keep messages short, point first;
- when to reach out;
- how deliveries and `zeus_ack` work;
- (PA1) to call `zeus_get_rules` and read its folder (`Zeus/preferences.md`, `Notes/`) when a session starts;
- (PA1) the proactive stance: on a Zeus learning, brief request or rule trigger, decide whether something needs preparing or flagging now, do it and send one short labelled message, otherwise ack and stay quiet; never comment on habits (AGENT_LEARNING.md §8);
- to check in briefly when started, then wait for the user or for a Zeus delivery.

It doesn't repeat the user's own AGENTS.md: that still applies (CONTRACT §11.2).

`ZeusManagedCopy.firstMessage` is the fixed first message for a fresh conversation (omitted on resume): "Zeus here: you're running as my assistant. Check in with one short zeus_say, then wait for me."

## 7. First run (for M4)

With nothing configured, the empty thread's **Open Settings** opens Assistant with **Zeus runs it** selected. The status panel says to choose a folder, Claude Code is preselected if installed (otherwise the first installed agent), and the permission mode is its default. After **Start**, the thread shows the agent's check-in as its first message.

## Checklist

- [ ] Assistant tab, two-mode switch, existing UI under "Connect your own"
- [ ] Status panel driven by `ZeusManagedPresentation`, countdown ticking, note for restart / missing tmux
- [ ] Agent and permission `ZeusChoiceList`s, unrestricted confirmation
- [ ] Instructions editor, Reset to Default, Start a New Conversation confirmation
- [ ] Menu status line, items and alert icon per §4
- [ ] Blocked card per §5, closes itself with "Answered in Terminal"
- [ ] Default prompt and first message from `ZeusManagedCopy`
