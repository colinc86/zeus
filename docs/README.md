# Zeus user manual

Zeus is a macOS desktop character and conversation window for Claude Code, Codex or OpenCode. It can run one assistant for you or connect to a session you run yourself.

Start with [Setting up Zeus](SETUP.md), then follow the guides below for everyday use. Learning is optional; all four observation levels start off.

| Guide | Contents |
|---|---|
| [Setting up Zeus](SETUP.md) | Install Zeus, choose your first assistant, connect an existing session and keep the app updated. |
| [Your assistant](ASSISTANT.md) | Run or connect an assistant, choose its permissions, and manage sessions, restarts and instructions. |
| [The conversation](CONVERSATION.md) | Send messages and files, answer questions, read status and use keyboard shortcuts. |
| [Characters and themes](CUSTOMIZATION.md) | Choose characters, themes, fonts and text size, adjust fading, and import or create your own look. |
| [Learn from me](LEARNING.md) | Choose what Zeus learns, explore its folder and journal, manage rules and ask about the window in front. |
| [Privacy and security](PRIVACY.md) | Understand local redaction, stored records, assistant access and permission boundaries. |
| [Settings reference](SETTINGS.md) | Look up every settings pane, control and initial default. |
| [MCP tool reference](MCP.md) | Look up all 26 `zeus_*` tools, their arguments and results, and delivery conventions. |
| [Troubleshooting and FAQ](TROUBLESHOOTING.md) | Resolve common connection, delivery, learning, appearance and update problems. |

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
