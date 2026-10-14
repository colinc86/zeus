# Zeus Theme Format (v1)

A theme recolors Zeus's chrome: the conversation panel, the speech bubble (peek), the typing indicator, Zeus's popovers and Settings. It **never** recolors the character sprites: a theme has no sprite or avatar keys, and the loader rejects unknown keys with a message saying so.

One theme per JSON file:
- **Bundled themes:** `Packages/ZeusKit/Sources/ZeusDesign/Themes/`.
- **User themes:** `~/Library/Application Support/Zeus/Themes/`, or Settings → Appearance → **Import Theme…**.

A user file with the same `id` as a bundled theme replaces it. Zeus reloads the folder whenever a file in it changes.

## 1. Two shapes

**One look, whatever the system uses:**

```jsonc
{
  "format": 1,                 // optional; newer formats are rejected
  "id": "harbor",              // letters, digits, - and _; ids starting with _ are skipped (examples, notes)
  "name": "Harbor",            // shown in Settings
  "author": "Alex",            // optional, shown under the name
  "appearance": "dark",        // "dark" or "light"
  "colors": { "panel": "#13232F", "text": "#EAF4F8" }
}
```

**Follow the system**: a `dark` and a `light` block, both required, and no `appearance` or `colors`:

```jsonc
{ "id": "olympus", "name": "Olympus", "dark": { … }, "light": { … } }
```

**Increase Contrast.** The optional `darkHighContrast` and `lightHighContrast` blocks are used when macOS Increase Contrast is on, and only for a look the theme has. Without them, Zeus uses its own high-contrast palettes: accessibility beats the theme.

**Notes.** Any key starting with `_` is ignored, at the top level and inside color blocks. The example file uses `"_help"` and `"_help_<section>"` strings because JSON has no comments.

## 2. Colors

Every color is `"#RRGGBB"`, or `"#RRGGBBAA"` for translucency. A field you leave out keeps the value from Zeus's own palette for that appearance: Midnight for dark, Parchment for light, or the matching high-contrast palette.

| Field | Used for |
|---|---|
| `outline` | outermost 1-px outline of panels, buttons and fields |
| `frame` | the light frame just inside the outline |
| `panel` | panel background |
| `text`, `secondaryText`, `title` | primary text; metadata, placeholders and paths; titles and bold runs |
| `accent`, `onAccent` | primary button fill and label; chosen options |
| `secondaryFill`, `onSecondary` | secondary button fill and label |
| `destructive`, `onDestructive` | destructive button fill and label; error captions |
| `field`, `fieldBorder` | text field background and inner border; muted bubble outline |
| `track`, `fill` | progress bar track and fill |
| `badge`, `onBadge` | count badge (the badge on the desktop always uses the dark palette) |
| `shadow` | hard drop shadow under panels (use alpha) |
| `agentBubble`, `userBubble`, `onUserBubble` | the assistant's bubble; the user's bubble and its text |
| `focusRing` | keyboard focus ring |
| `positive` | "Running" and other healthy states |
| `sessionColors` | a list of exactly **4** colors for the session dots |

## 3. Contrast

`ZeusContrast` (ZeusDesign) lists every text and background pair the views draw:
- **Text:** at least 4.5:1, and 7:1 in high-contrast blocks.
- **Controls and indicators:** at least 3:1.

Every bundled theme passes; `ZeusThemeLibraryTests` checks it. A user theme that misses still loads, and Settings tags it **Low contrast** with a one-line caption naming the first pair that fails, e.g. *Some text may be hard to read: body text on agent bubble is 1.6:1; it needs 4.5:1.*

## 4. Errors

Every problem names the field and says what's wrong, in plain words. Examples:
- *"panel" in "colors" isn't a color (got navy). Use #RRGGBB, or #RRGGBBAA for see-through.*
- *"avatar" isn't a theme setting. … Themes only recolor Zeus's panels and Settings; characters keep their own colors.*
- *This file isn't valid JSON: Unexpected character '"' in object around line 3, column 3. Check for a missing comma or quote just before it.*

A file with errors doesn't load. Settings lists it with every reason.

## 5. Code

| | |
|---|---|
| Model | `ZeusThemeDefinition` (`load(data:source:)`, `palette(for:contrast:)`, `isLowContrast`), `ZeusThemeLibrary`, `ZeusThemeImport`, `ZeusThemeExample` (ZeusDesign) |
| Environment | `\.zeusTheme` is set once at each root: conversation panel, peek, delivery warning, avatar and Settings. `\.zeusPalette` resolves the theme with the color scheme and Increase Contrast, so views keep reading `@Environment(\.zeusPalette)`. A root reads its own palette from `settings.currentTheme`. |
| App | `AppSettings.availableThemes` / `currentTheme` / `setTheme(id:)` (`appearance.theme`), `reloadThemes()`. The `ThemeControlling` seam is for a later MCP tool. |
| Default | **Classic**: Midnight in dark mode, Parchment in light mode. Built in code. |
