#!/usr/bin/env python3
"""
Extract translatable strings from Lua source files and synchronize .po catalogs.

Usage:
    python3 translation_utils.py --sync [--locale LOCALE]

Flags:
    --sync              Remove dead strings, add and translate missing strings, then alphabetize
    --update-po         Write missing msgids into all (or specified) locale .po files
    --remove-dead       Remove msgids from .po files not found in Lua source
    --alphabetize       Sort all entries in .po files alphabetically by msgid
    --list-missing      Print msgids absent from .po files entirely and exit
    --list-untranslated Print msgids present in .po but with empty msgstr and exit
    --locale LOCALE     Only process one locale (e.g. zh_CN)
    --show-dead         Show msgids in .po files not found in Lua source
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCALES_DIR = os.path.join(SCRIPT_DIR, "locales")
LUA_EXCLUDE_DIRS = {".git", "dist", "node_modules", "tests"}
GOOGLE_TRANSLATE_URL = "https://translate.googleapis.com/translate_a/single"
GOOGLE_LOCALES = {
    "pt_BR": "pt",
    "pt_PT": "pt-PT",
    "zh_CN": "zh-CN",
    "zh_TW": "zh-TW",
}
TRANSLATION_WORKERS = 6
IDENTICAL_TRANSLATION_ALLOWLIST = {"ZenPM v", "ZenPM: Open"}

_RE_GETTEXT_DQ = re.compile(r'(?<![A-Za-z0-9_])_\(\s*"((?:[^"\\]|\\.)*)"\s*\)', re.DOTALL)
_RE_GETTEXT_SQ = re.compile(r"(?<![A-Za-z0-9_])_\(\s*'((?:[^'\\]|\\.)*)'\s*\)", re.DOTALL)
_RE_NGETTEXT_DQ = re.compile(r'N_\(\s*"((?:[^"\\]|\\.)*)"\s*\)', re.DOTALL)
_RE_NGETTEXT_SQ = re.compile(r"N_\(\s*'((?:[^'\\]|\\.)*)'\s*\)", re.DOTALL)
_RE_CGETTEXT_DQ = re.compile(r'C_\(\s*"[^"]*"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)', re.DOTALL)
_RE_CGETTEXT_SQ = re.compile(r"C_\(\s*'[^']*'\s*,\s*'((?:[^'\\]|\\.)*)'\s*\)", re.DOTALL)
_RE_GETTEXT_LS = re.compile(r'_\(\s*\[\[(.*?)\]\]\s*\)', re.DOTALL)
ALL_PATTERNS = [
    _RE_GETTEXT_DQ,
    _RE_GETTEXT_SQ,
    _RE_NGETTEXT_DQ,
    _RE_NGETTEXT_SQ,
    _RE_CGETTEXT_DQ,
    _RE_CGETTEXT_SQ,
    _RE_GETTEXT_LS,
]


def unescape_lua(value: str) -> str:
    return (value.replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace('\\"', '"')
        .replace("\\'", "'")
        .replace("\\\\", "\\"))


def extract_from_file(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            content = source.read()
    except OSError:
        return []
    return [unescape_lua(match.group(1)) for pattern in ALL_PATTERNS for match in pattern.finditer(content)]


def collect_lua_strings() -> dict[str, list[str]]:
    """Return every gettext string with the Lua files that contain it."""
    result: dict[str, list[str]] = {}
    for root, dirs, files in os.walk(SCRIPT_DIR):
        dirs[:] = [directory for directory in dirs if directory not in LUA_EXCLUDE_DIRS]
        for filename in files:
            if not filename.endswith(".lua"):
                continue
            path = os.path.join(root, filename)
            relative_path = os.path.relpath(path, SCRIPT_DIR)
            for string in extract_from_file(path):
                result.setdefault(string, []).append(relative_path)
    return result


def po_header(po_path: str) -> str:
    with open(po_path, encoding="utf-8") as catalog:
        content = catalog.read()
    match = re.search(r'\nmsgid "(?!"\n)', content)
    return content[:match.start() + 1] if match else content


def parse_po(po_path: str) -> dict[str, str]:
    """Return {msgid: msgstr} for all non-header entries in a .po catalog."""
    try:
        with open(po_path, encoding="utf-8") as catalog:
            content = catalog.read()
    except OSError:
        return {}

    entries = {}
    for block in re.split(r"\n\n+", content.strip()):
        msgid_match = re.search(r'^msgid "((?:[^"\\]|\\.)*)"', block, re.MULTILINE)
        msgstr_match = re.search(r'^msgstr "((?:[^"\\]|\\.)*)"', block, re.MULTILINE)
        if msgid_match and msgstr_match:
            msgid = unescape_lua(msgid_match.group(1))
            if msgid:
                entries[msgid] = unescape_lua(msgstr_match.group(1))
    return entries


def msgid_to_po_line(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def format_entry(msgid: str, msgstr: str = "") -> str:
    return f'msgid "{msgid_to_po_line(msgid)}"\nmsgstr "{msgid_to_po_line(msgstr)}"\n'


def rewrite_po(
    po_path: str,
    existing: dict[str, str],
    lua_strings: set[str],
    to_add: list[str],
    remove_dead: bool,
    alphabetize: bool = False,
) -> tuple[int, int]:
    """Rewrite a catalog and return the number of removed and added entries."""
    kept = {}
    removed = 0
    for msgid, msgstr in existing.items():
        if remove_dead and msgid not in lua_strings:
            removed += 1
        else:
            kept[msgid] = msgstr
    for msgid in sorted(to_add):
        kept[msgid] = ""

    entries = sorted(kept.items(), key=lambda entry: entry[0].lower()) if alphabetize else kept.items()
    parts = [po_header(po_path).rstrip("\n")]
    parts.extend(format_entry(msgid, msgstr).rstrip("\n") for msgid, msgstr in entries)
    with open(po_path, "w", encoding="utf-8") as catalog:
        catalog.write("\n\n".join(parts) + "\n")
    return removed, len(to_add)


def locale_files(locale: str | None = None) -> list[str]:
    files = sorted(filename for filename in os.listdir(LOCALES_DIR) if filename.endswith(".po"))
    if not locale:
        return files
    target = f"{locale}.po"
    if target not in files:
        raise ValueError(f"{target} not found in {LOCALES_DIR}")
    return [target]


def get_missing_per_locale(locale: str | None = None) -> dict[str, list[str]]:
    lua_strings = collect_lua_strings()
    return {
        filename[:-3]: sorted(string for string in lua_strings if string not in parse_po(os.path.join(LOCALES_DIR, filename)))
        for filename in locale_files(locale)
    }


def is_untranslated(locale: str, msgid: str, msgstr: str) -> bool:
    if not msgstr:
        return True
    return (locale != "en"
        and msgstr == msgid
        and len(msgid.split()) > 1
        and msgid not in IDENTICAL_TRANSLATION_ALLOWLIST)


def get_untranslated_per_locale(locale: str | None = None) -> dict[str, list[str]]:
    return {
        filename[:-3]: sorted(
            msgid for msgid, msgstr in parse_po(os.path.join(LOCALES_DIR, filename)).items()
            if is_untranslated(filename[:-3], msgid, msgstr)
        )
        for filename in locale_files(locale)
    }


_FORMAT_TOKEN_RE = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[A-Za-z%]|%\d+")


def protect_format_tokens(text: str) -> tuple[str, list[str]]:
    tokens: list[str] = []

    def replace(match: re.Match) -> str:
        tokens.append(match.group(0))
        return f"⟪ZENFMT{len(tokens) - 1}⟫"

    return _FORMAT_TOKEN_RE.sub(replace, text), tokens


def restore_format_tokens(text: str, tokens: list[str]) -> str:
    for index, token in enumerate(tokens):
        marker = f"⟪ZENFMT{index}⟫"
        if text.count(marker) != 1:
            raise ValueError("translation changed a format placeholder marker")
        text = text.replace(marker, token)
    return text


def preserve_boundary_whitespace(source: str, translation: str) -> str:
    if not translation:
        return translation
    leading = re.match(r"^\s*", source).group(0)
    trailing = re.search(r"\s*$", source[len(leading):]).group(0)
    return leading + translation.strip() + trailing


def google_translate(text: str, locale: str, timeout: int = 20) -> str:
    """Translate English text using Google Translate's keyless web endpoint."""
    if locale == "en":
        return text
    protected, tokens = protect_format_tokens(text)
    query = urllib.parse.urlencode({
        "client": "gtx", "sl": "en", "tl": GOOGLE_LOCALES.get(locale, locale), "dt": "t", "q": protected,
    })
    request = urllib.request.Request(f"{GOOGLE_TRANSLATE_URL}?{query}", headers={"User-Agent": "Mozilla/5.0"})
    last_error = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = json.load(response)
            translated = "".join(part[0] for part in data[0] if part and part[0])
            if not translated:
                raise ValueError("Google returned an empty translation")
            return preserve_boundary_whitespace(text, restore_format_tokens(translated, tokens))
        except (OSError, ValueError, KeyError, IndexError, TypeError, urllib.error.URLError) as error:
            last_error = error
            if attempt < 2:
                time.sleep(2 ** attempt)
    raise RuntimeError(f"Google translation failed for {locale}: {text!r}: {last_error}")


def translate_strings(locale: str, msgids: list[str]) -> dict[str, str]:
    if locale == "en":
        return {msgid: msgid for msgid in msgids}
    if not msgids:
        return {}
    with ThreadPoolExecutor(max_workers=min(TRANSLATION_WORKERS, len(msgids))) as pool:
        jobs = {pool.submit(google_translate, msgid, locale): msgid for msgid in msgids}
        return {jobs[job]: job.result() for job in as_completed(jobs)}


def sync_catalogs(po_files: list[str], lua_strings: set[str]) -> None:
    """Synchronize catalogs only after every requested translation succeeds."""
    plans = []
    for filename in po_files:
        locale = filename[:-3]
        po_path = os.path.join(LOCALES_DIR, filename)
        existing = parse_po(po_path)
        missing = sorted(lua_strings - set(existing))
        dead = sorted(set(existing) - lua_strings)
        synced = {
            msgid: preserve_boundary_whitespace(msgid, existing.get(msgid, ""))
            for msgid in lua_strings
        }
        untranslated = sorted(
            msgid for msgid, msgstr in synced.items()
            if is_untranslated(locale, msgid, msgstr)
        )
        print(f"[{locale}]  missing={len(missing)}  dead={len(dead)}  untranslated={len(untranslated)}")
        if untranslated:
            print(f"  -> translating {len(untranslated)} entries")
            synced.update(translate_strings(locale, untranslated))
        plans.append((po_path, synced, len(dead), len(missing), len(untranslated)))

    for po_path, synced, removed, added, translated in plans:
        rewrite_po(po_path, synced, lua_strings, [], remove_dead=True, alphabetize=True)
        print(f"  -> {os.path.basename(po_path)}: removed={removed} added={added} translated={translated} alphabetized=yes")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sync", action="store_true", help="Remove dead entries, add and translate missing entries, and alphabetize")
    parser.add_argument("--update-po", action="store_true", help="Append missing msgids to .po files")
    parser.add_argument("--remove-dead", action="store_true", help="Remove msgids from .po files that no longer exist in Lua source")
    parser.add_argument("--alphabetize", action="store_true", help="Sort all entries in .po files alphabetically by msgid")
    parser.add_argument("--list-missing", action="store_true", help="Print msgids absent from .po files entirely and exit")
    parser.add_argument("--list-untranslated", action="store_true", help="Print msgids present in .po but with empty msgstr and exit")
    parser.add_argument("--locale", metavar="LOCALE", help="Only process one locale (e.g. zh_CN)")
    parser.add_argument("--show-dead", action="store_true", help="Show msgids in .po but not in Lua source")
    args = parser.parse_args()

    if args.sync and any((args.update_po, args.remove_dead, args.alphabetize, args.list_missing, args.list_untranslated, args.show_dead)):
        parser.error("--sync cannot be combined with other action flags")

    try:
        po_files = locale_files(args.locale)
    except ValueError as error:
        parser.error(str(error))

    if args.list_missing:
        for locale, msgids in get_missing_per_locale(args.locale).items():
            print(f"[{locale}]  {len(msgids)} missing")
            for msgid in msgids:
                print(f"  {msgid!r}")
        return
    if args.list_untranslated:
        for locale, msgids in get_untranslated_per_locale(args.locale).items():
            print(f"[{locale}]  {len(msgids)} untranslated")
            for msgid in msgids:
                print(f"  {msgid!r}")
        return

    print("Scanning Lua source files...")
    lua_strings = collect_lua_strings()
    print(f"  Found {len(lua_strings)} unique translatable strings\n")
    if args.sync:
        try:
            sync_catalogs(po_files, set(lua_strings))
        except RuntimeError as error:
            print(f"Error: {error}", file=sys.stderr)
            sys.exit(1)
        return

    for filename in po_files:
        locale = filename[:-3]
        po_path = os.path.join(LOCALES_DIR, filename)
        existing = parse_po(po_path)
        missing = sorted(string for string in lua_strings if string not in existing)
        dead = sorted(string for string in existing if string not in lua_strings) if args.show_dead or args.remove_dead else []
        print(f"[{locale}]  missing={len(missing)}  dead={len(dead) if args.show_dead or args.remove_dead else '?'}")
        if missing:
            print("  MISSING (in Lua, not in .po):")
            for string in missing:
                files = lua_strings[string]
                suffix = "..." if len(files) > 2 else ""
                print(f"    {string!r}  <- {', '.join(files[:2])}{suffix}")
        if dead:
            print("  DEAD (in .po, not in Lua):")
            for string in dead:
                print(f"    {string!r}")
        if (args.update_po and missing) or args.remove_dead or args.alphabetize:
            removed, added = rewrite_po(po_path, existing, set(lua_strings), missing if args.update_po else [], args.remove_dead, args.alphabetize)
            if args.remove_dead and removed:
                print(f"  -> removed {removed} dead entries")
            if args.update_po and added:
                print(f"  -> added {added} new entries")
            if args.alphabetize:
                print("  -> alphabetized entries")
        print()


if __name__ == "__main__":
    main()
