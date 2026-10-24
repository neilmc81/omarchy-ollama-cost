# Changelog

## 0.1.1

- The bar now shows the Ollama mark (glyph U+E907 from the `omarchy` font
  that ships with Omarchy 4) instead of the `OL` text label. When the
  included usage for the period is used up, the icon turns the warning
  (urgent) colour instead of showing `OL!`. `⚠` (no key) and `!` (error)
  are unchanged.

## 0.1.0

- First release: bar status label (`OL`, `OL!`, `⚠`, `!`) and a dropdown with
  plan usage, dollars used and remaining, the billing-period reset date, the
  keys feeding it and the period request count.
- Data from Ollama's `/api/balance`, `/api/usage` and `/api/me`; legacy
  weekly-percentage plans are supported. Keys on the same account are counted
  once.
- One-line installer (`install.sh`): clones or updates the plugin, prompts
  for an API key with hidden input, registers the widget in `shell.json`
  (with a backup), checks the key and restarts the shell.
- Uninstaller (`uninstall.sh`): removes the bar entry, the plugin clone and
  cached data; keeps your API keys unless you say yes or pass `--purge`.
- Omarchy 4.5 compatible: the bar label renders at normal text size on 4.5
  (uses `WidgetButton` rather than `BarIconButton`, which 4.5 scales to icon
  size) and the manifest declares `defaultSection: right`.
