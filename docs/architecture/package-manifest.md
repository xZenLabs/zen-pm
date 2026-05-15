# Package Manifest Contract (v1)

This document defines the canonical Zen PM package manifest schema.

## File

Each package has a `manifest.json`.

## Required fields

- `schema_version` (string): manifest schema version, currently `"1"`.
- `id` (string): stable unique package id.
- `name` (string): human-readable package name.
- `version` (string): semantic package version.
- `description` (string): short package description.
- `platforms` (array[string]): supported platforms (`kindle`, `kobo`).
- `dependencies` (array[string]): package ids required before install.
- `hooks.install` (string): install script URL or relative path.
- `hooks.uninstall` (string): uninstall script URL or relative path.

## Optional fields

- `author` (string)
- `homepage` (string)
- `license` (string)
- `artifacts` (array[object]): downloadable artifacts with hashes.
- `launcher` (object): platform launch integration metadata.
- `constraints` (object): firmware, ABI, and capability constraints.
- `trust` (object): optional signature metadata.

## Launcher object

Example:

```json
{
  "launcher": {
    "kindle": {
      "type": "kual",
      "entry_name": "KOReader"
    },
    "kobo": {
      "type": "nickelmenu",
      "entry_name": "KOReader",
      "location": "main"
    }
  }
}
```

## Constraints object

Example:

```json
{
  "constraints": {
    "abi": ["hf", "sf"],
    "firmware": {
      "kindle": ">=5.12.2.2",
      "kobo": ">=4.6"
    }
  }
}
```

## Trust object

Example:

```json
{
  "trust": {
    "signature": {
      "type": "ed25519",
      "key_id": "zenpm-main",
      "sig": "base64-signature"
    }
  }
}
```

Signatures are optional in v1. Client policy may run in warning mode.

## Minimal example

```json
{
  "schema_version": "1",
  "id": "koreader-kobo",
  "name": "KOReader (Kobo)",
  "version": "2026.03.0",
  "description": "Install KOReader and a NickelMenu launch entry on Kobo.",
  "platforms": ["kobo"],
  "dependencies": ["zenpm-kobo"],
  "hooks": {
    "install": "scripts/install.sh",
    "uninstall": "scripts/uninstall.sh"
  }
}
```
