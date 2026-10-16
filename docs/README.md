# Zeus documentation

Zeus is a macOS desktop character and conversation window for Claude Code, Codex or OpenCode. It can run one assistant for you or connect to a session you run yourself.

Start with [Setting up Zeus](SETUP.md). Learning is optional; all four observation levels are off by default.

| Guide | Contents |
|---|---|
| [Setting up Zeus](SETUP.md) | Requirements, installation, first start, connecting your own session and updates |
| [Your assistant](ASSISTANT.md) | Managed sessions, permission modes, tmux, routing, restarts and instruction updates |
| [The conversation](CONVERSATION.md) | Messages, questions, cards, attachments, peeks, status and keyboard shortcuts |
| [Characters and themes](CUSTOMIZATION.md) | Appearance, fading, importing and creating JSON characters and themes |
| [Learn from me](LEARNING.md) | Four levels, assistant folder, permissions, retention, summaries, journal, rules and Ask About This |
| [Privacy and security](PRIVACY.md) | Local processing, redaction, storage, assistant access and safety boundaries |
| [Settings reference](SETTINGS.md) | Every pane, available controls and initial defaults |
| [MCP tool reference](MCP.md) | All 26 `zeus_*` tools, arguments, results and delivery conventions |
| [Troubleshooting and FAQ](TROUBLESHOOTING.md) | Connection, delivery, learning, appearance and update problems |

## For contributors

User guides describe the implemented behavior. The files below cover engineering interfaces, design intent and development workflows; older design reviews also preserve historical proposals.

- [Contributor guide](../AGENTS.md) and [build commands](../README.md#build-and-contribute)
- [Engineering contract](CONTRACT.md)
- [Conversation design](design/CONVERSATION.md), [cards](design/CARDS.md), [managed sessions](design/MANAGED.md), [privacy surfaces](design/PRIVACY.md) and [assistant learning](design/AGENT_LEARNING.md)
- [Sprite JSON format](design/SPRITE_FORMAT.md), [theme JSON format](design/THEME_FORMAT.md) and [rendering](design/RENDERING.md)
- [Release pipeline](RELEASE.md)

README images come from the isolated design harness, using real views and synthetic records. To rebuild them without opening the Zeus app:

```sh
scripts/design-harness/render.sh readme
```

The harness writes frames to `build/readme-renders/`; `scripts/design-harness/readme-assets.py` packages them into `docs/readme/` and checks the GIF frames. Pillow is required for packaging.
