#!/usr/bin/env python3
import re
import sys
from pathlib import Path


CHANGELOG = Path("frontend/koreader/zenpm.koplugin/config/changelog.lua")


def find_version_block(content, version):
    key = '["{}"]'.format(version)
    key_pos = content.find(key)
    if key_pos < 0:
        return None

    eq_pos = content.find("=", key_pos + len(key))
    start = content.find("{", eq_pos)
    if eq_pos < 0 or start < 0:
        return None

    depth = 1
    quote = None
    escaped = False
    i = start + 1
    while i < len(content):
        ch = content[i]
        if quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
        else:
            if ch == '"' or ch == "'":
                quote = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return content[start + 1:i]
        i += 1

    return None


def clean_lua_string(text):
    text = re.sub(r"\\u\{[0-9A-Fa-f]+\}\s*", "", text)
    escapes = {
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "\\": "\\",
        '"': '"',
        "'": "'",
    }
    out = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append(escapes.get(nxt, ch + nxt))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out).strip()


def extract_items(block):
    items = []
    quote = None
    escaped = False
    buf = []

    for ch in block:
        if quote:
            if escaped:
                buf.append("\\" + ch)
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                item = clean_lua_string("".join(buf))
                if item:
                    items.append(item)
                quote = None
                buf = []
            else:
                buf.append(ch)
        elif ch == '"' or ch == "'":
            quote = ch

    return items


def main():
    version = sys.argv[1]
    content = CHANGELOG.read_text(encoding="utf-8")
    block = find_version_block(content, version)
    items = extract_items(block) if block is not None else []

    print("## What's Changed\n")
    if items:
        for item in items:
            print("- {}".format(item))
    else:
        print("_No changelog entries for this version._")


if __name__ == "__main__":
    main()
