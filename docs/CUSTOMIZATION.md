# Characters and themes

[Documentation](README.md) · [Settings reference](SETTINGS.md) · [Conversation](CONVERSATION.md)

## Characters

Choose a character in **Settings › Character** or the Zeus menu's **Character** submenu. The twelve built-ins are Zeus, Wisp, Jack, Gizmo, Sprout, Merlo, Midnight, Bones, Gloop, Nyx, Hoot and Spore.

**Size** offers Small, Medium and Large; Medium is the default. Drag the character to place it. **Reset Avatar Position** restores its position if you lose it off screen.

**Fade Zeus when idle** is off initially. When enabled, it fades to the chosen **Idle opacity** after **Fade after** seconds without interaction. Defaults are 30% and 30 seconds; ranges are 10–90% and 5–600 seconds. Faded Zeus still takes clicks. Pointing at it, clicking, new work or a new message brings it back; an open conversation or peek keeps it visible. An existing question or ongoing work does not keep resetting the delay.

## Make your own character

Characters are JSON files, with a palette, pixel layers and animations. No code is needed.

1. In **Settings › Character**, press **Open Example**.
2. Save a copy of `Example Character.json` in the same folder with a new name and a new `id` (letters, digits, `-` or `_`). IDs beginning with `_` are skipped, including the example.
3. Read the `_help` fields, edit the pixel rows or animations, and save. Zeus reloads the folder automatically.

Use **Import Character…** to validate and copy someone else's JSON into the Characters folder. Zeus switches to the imported character and asks before a conflicting replacement. A user character can override a built-in ID. **Open Characters Folder** opens `~/Library/Application Support/Zeus/Characters/`; remove the user file there to remove that version.

Settings reports invalid files and their errors. The [sprite format](design/SPRITE_FORMAT.md) specifies all fields, fallback states and validation rules. From a source checkout, validate your folder with:

```sh
swift run --package-path Packages/ZeusKit zeus-sprites validate "$HOME/Library/Application Support/Zeus/Characters"
```

## Themes

**Settings › Appearance** changes the conversation, speech bubble and Settings colors. It does not tint the character.

| Theme | Appearance |
|---|---|
| Classic (default) | Follows macOS: Midnight in dark mode, Parchment in light mode. |
| Midnight | Dark. |
| Parchment | Light. |
| Olympus | Follows macOS with its own light and dark palettes. |
| Phosphor | Dark. |
| Pocket | Light. |
| Sorbet | Light. |

Increase Contrast uses a theme's high-contrast palette if supplied, otherwise Zeus's high-contrast colors. Reduce Motion limits animation and removes motion-dependent effects.

Use **Open Example** to make a theme, **Import Theme…** to add one, and **Open Themes Folder** to open `~/Library/Application Support/Zeus/Themes/`. Save an example copy with a new ID; changes reload immediately. A theme can use one fixed appearance or separate light and dark palettes. A valid theme with insufficient contrast still loads with **Low contrast** displayed in Settings.

See the [theme format](design/THEME_FORMAT.md) for fields and examples.

## Fonts and text size

Choose **Settings › Appearance › Conversation font** for **Pixel** (Departure Mono, the default) or **SF Mono**. Directly below it, **Text size** offers **Small**, **Default**, **Large** and **Larger**. **Default** is the initial size. Changes apply immediately and survive relaunch; no assistant restart is needed.

Text size applies to the conversation, message field, status line, speech bubbles, attachment/context chips, rating rows and notices. Settings and menus keep the system font and size. The character's size and desktop badges are separate. Zeus uses your chosen preset rather than following macOS accessibility text size.

Pixel text grows in whole steps to stay crisp. **Small** reduces titles while keeping ordinary text at **Default** size. **Large** enlarges titles, message text and buttons; **Larger** also enlarges captions, including attachment summaries and the status line. SF Mono text changes at every preset. Larger text fits fewer words on a line; you can [widen the conversation](CONVERSATION.md#keyboard-shortcuts) for more room.

## Assistant controls

When asked, the assistant can select or create a character or theme, move or resize Zeus, hide it temporarily, and change supported appearance settings. Changes appear in the conversation with **Undo**; a hide offers **Show now**. Undoing a newly created character or theme restores the selection but leaves the file available.

**Settings › General** has **Let my assistant control Zeus** and **Let my assistant install updates**, both initially on. Turning off the master control blocks app-changing tools and update checks. Turning off only update installation still allows checks. Installing an update has an announcement, but no Undo.

App-control tools cannot change the assistant's agent, folder, permissions, instructions, run mode or session; answer its native prompts; erase conversation or learning data; or enable learning, launch at login or automatic update checks. They cannot disable quiet hours while a Zeus question is open. [MCP app controls](MCP.md#app-controls) lists the exact supported fields.

Implementation references: [character settings](../Zeus/Settings/CharacterSettingsView.swift), [appearance settings](../Zeus/Settings/AppearanceSettingsView.swift), [defaults](../Zeus/Settings/AppSettings.swift), [font presets](../Packages/ZeusKit/Sources/ZeusDesign/ZeusFonts.swift), and [app-control schemas](../Packages/ZeusKit/Sources/ZeusProtocol/ZeusAppTools.swift).
