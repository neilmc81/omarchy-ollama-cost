# Changelog

## 0.1.2

- Easier key setup: the installer explains that one Ollama API key is enough
  (usage is reported for the whole account) and links to where to create it.
  A key from `OLLAMA_API_KEY` is now saved to `~/.config/ollama-cost/conf.json`
  (mode 600) when no key is configured, so the bar can see it.
- New `--no-prompt` (or `OLLAMA_COST_NO_PROMPT=1`) and `--no-verify`
  installer options. An unusual-looking key gets a warning but is still
  saved. Skipping prints one line on how to add a key later.
- The dropdown's no-key message now points to the installer and the key file.
- Test: `tests/test_install.sh` covers the installer's key step with a temp
  HOME and a fake key.

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
