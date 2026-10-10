# Making a SpectiX theme

A theme is one JSON file. Drop it into `~/.claude/spectix/themes/`, open **Settings → Theme**, and it appears next to the built-in themes. No rebuild, no restart.

```bash
mkdir -p ~/.claude/spectix/themes
cp docs/themes/example-pastel.json ~/.claude/spectix/themes/
```

## The smallest theme

```json
{
  "id": "pastel-glass",
  "name": "Pastel Glass",
  "base": "default",
  "status": { "working": "#7DB8F0", "done": "#8FD6A8" }
}
```

A theme starts from a built-in theme (`base`) and overrides only what you list. Everything you leave out stays as it is in the base theme.

## Keys

| Key | Required | What it is |
|---|---|---|
| `id` | yes | Lowercase letters, digits and dashes. Saved in your preferences, so don't rename it once in use. Must not be `default` or `clay`. |
| `name` | yes | Shown on the theme card. |
| `nameZH` | no | Name shown when the app runs in Chinese. Defaults to `name`. |
| `description` / `descriptionZH` | no | One line under the name. |
| `base` | no | `default` (frosted glass, hairline edges) or `clay` (opaque, soft shadows). Defaults to `default`. The base decides the material, edges and shadows; a file cannot change those. |
| `palette` | no | Surface, line and accent colors. |
| `status` | no | Session status colors: `needs`, `working`, `checking`, `paused`, `await`, `done`, `idle`, and the filled-pill versions `needsFill` … `idleFill`. |
| `metrics` | no | Corner radii in points, 0–40: `card`, `group`, `chip`, `windowRadius`, `popoverRadius`. |

Every key the base themes use, with its current value, is in [`themes/default.json`](themes/default.json) and [`themes/clay.json`](themes/clay.json). Copy one and change what you want.

Spacing, row heights and font sizes are not themeable on purpose. A theme changes how SpectiX looks, never how much fits.

## Colors

- `"#RRGGBB"` (opaque) or `"#RRGGBBAA"` (with alpha).
- A different color in light and dark mode: `{ "light": "#FFFFFF80", "dark": "#FFFFFF0F" }`.

Pills with white text sit on the `*Fill` colors. Keep those dark enough for white text to read (a contrast ratio of 4.5:1 or more).

## Editing a theme you are using

Save the file, then click the theme's card in Settings again. SpectiX re-reads the folder and redraws.

## When a file doesn't show up

The file is skipped if it isn't valid JSON, uses an unknown key (typos are rejected, not ignored), has a bad color, or reuses an `id`. The reason goes to the system log:

```bash
log show --last 10m --predicate 'eventMessage CONTAINS "SpectiX theme file"'
```

## Sharing

Post your file in a [GitHub issue](https://github.com/spectix-app/SpectiX/issues/new/choose), ideally with light and dark screenshots. The theme files you make are yours.
