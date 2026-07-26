---
---
# Contributing to this project

Thank you for your interest in contributing. This project is a small, focused package manager — contributions that keep it clean, minimal, and well-behaved are most welcome.

## Ways to contribute

| | |
|---|---|
| 🐛 **Bug report** | Open an Issue describing what went wrong |
| 💡 **Feature request** | Open an Issue with your idea |
| 🌍 **Translation** | Add or improve a `.po` file in `locales/` |
| 🔧 **Code** | Fork, branch, change, and open a Pull Request |
| 📝 **Documentation** | Improve the README or add inline comments |

---

## Reporting a bug

Open an Issue and include:

- A clear description of what happened and what you expected
- Steps to reproduce the problem, if you can

If the bug causes a crash, the log is very helpful.

---

## Suggesting a feature

Open an Issue describing the feature and why it would be useful. Keep this project's philosophy in mind — features should reduce clutter or add something genuinely useful. Screenshots or mockups are welcome.

---

## Contributing a translation

Translations live in the `locales/` folder as standard `.po` files. No programming knowledge is needed.

### Adding a new language

1. Copy `locales/en.po` to `locales/<lang>.po` using the standard locale code — for example `de.po`, `ja.po`, `ko.po`.
2. Open the file in any text editor or a dedicated PO editor such as [Poedit](https://poedit.net/).
3. Update the header fields at the top of the file:
   ```
   "Language: de\n"
   ```
4. For each entry, fill in the `msgstr` field with your translation:
   ```
   msgid "Quick settings"
   msgstr "Schnelleinstellungen"
   ```
5. Submit your file as a Pull Request (see below).

### Improving an existing translation

Open the existing `.po` file for your language, correct or complete the `msgstr` values, and submit a Pull Request.

### Translation guidelines

- Never modify the `msgid` — only edit `msgstr`
- Keep placeholders intact: `%d`, `%s`, `%%`, and `\n` must appear in `msgstr` exactly as they do in `msgid`
- Leave `msgstr ""` empty for any string you are unsure about — the English original will be shown as a fallback
- If your language has different plural forms, set `Plural-Forms` in the header accordingly

---

## Contributing code

### Setup

this project is a standard KOReader plugin written in Lua. No build system or compilation step is required. The plugin runs directly from source.

To test changes:

1. Copy the `zenpm.koplugin` folder to the `plugins/` directory on your device or the KOReader emulator.
2. Restart KOReader to reload the plugin.

The [KOReader emulator](https://github.com/koreader/koreader/blob/master/doc/Building.md) is the fastest way to iterate without a physical device.

For the local KOReader development build, set `KOREADER_DIR` in `.env`, then run:

```sh
./build.sh --dev
```

This compiles the macOS backend, deploys `zenpm.koplugin` to the emulator, and
restarts and focuses KOReader. The command stays attached so its log output is
visible; press Ctrl-C to stop it.

### Static linting (LuaCheck)

this project uses [LuaCheck](https://github.com/mpeterv/luacheck) for static analysis.

Install it locally (one-time):

```sh
luarocks install luacheck
```

Run lint checks from the plugin root:

```sh
luacheck -q _meta.lua main.lua common config modules
```

The project config is in `.luacheckrc` and is aligned with KOReader's baseline (for globals like `G_reader_settings` and `G_defaults`).

### Making a change

1. Fork this repository (click the Fork button at the top right of the GitHub page).
2. Create a new branch for your change:
   ```sh
   git checkout -b fix/my-bug-description
   ```
3. Make your changes.
4. If you added any new visible text (strings shown in the UI), wrap them with `_()`:
   ```lua
   -- correct
   text = _("Something went wrong.")

   -- incorrect — not translatable
   text = "Something went wrong."
   ```
5. If your change introduces new strings, add entries to `locales/en.po`:
   ```
   msgid "Your new string"
   msgstr ""
   ```
6. Commit with a clear message that describes what changed and why:
   ```sh
   git commit -m "Fix progress bar not updating after resume"
   ```
7. Push your branch and open a Pull Request against `main`.

### Extracting translatable strings

From `frontend/koreader/zenpm.koplugin`, use the bundled utility to inspect missing strings:

```sh
python3 translation_utils.py --list-missing
```

To add missing strings to a catalog without translating them, run:

```sh
python3 translation_utils.py --update-po --locale en
```

`--sync` removes obsolete strings, adds new ones, translates empty entries with
Google Translate, and alphabetizes the catalog. It only contacts Google when
you explicitly run that command.

### Code style

- Follow the style of the surrounding code — indentation, spacing, and naming conventions are consistent throughout
- Keep logic focused; avoid adding behavior to build/render functions that belongs in helpers
- Prefer `local` variables; avoid polluting the module-level scope
- All strings shown to the user must be wrapped in `_()`
- Add a short comment when the reason for a decision is not obvious from the code

## Pull Request checklist

Before submitting, please check:

- [ ] The change works on a real device or the KOReader emulator
- [ ] Any new UI strings are wrapped in `_()`
- [ ] New strings are added to `locales/en.po`
- [ ] The commit message clearly describes the change
- [ ] No debug logging or commented-out code is left in

Thank you for helping make this project better.
