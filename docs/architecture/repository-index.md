# Repository Index Contract (v1)

Zen PM repositories are static-hostable and contain two index formats.

## Required files

- `index.json` - canonical metadata and tooling source.
- `catalog.tsv` - shell-friendly package index consumed by the client.

## index.json

`index.json` must include:

- `schema_version` (string)
- `repo` (object): repository metadata.
- `packages` (array[object]): package summary entries.

Example:

```json
{
  "schema_version": "1",
  "repo": {
    "id": "zenpm-default",
    "name": "Zen PM Default Repository",
    "url": "https://example.invalid/zenpm/default"
  },
  "packages": [
    {
      "id": "koreader-kindle",
      "name": "KOReader (Kindle)",
      "version": "2026.03.0",
      "platforms": ["kindle"],
      "dependencies": ["kual"],
      "install_url": "packages/koreader-kindle/scripts/install.sh",
      "uninstall_url": "packages/koreader-kindle/scripts/uninstall.sh",
      "manifest_url": "packages/koreader-kindle/manifest.json",
      "sha256": "",
      "size": ""
    }
  ]
}
```

## catalog.tsv

`catalog.tsv` is tab-separated with header:

```text
id	name	version	platforms	dependencies	install_url	uninstall_url	manifest_url	sha256	size
```

Rules:

- `platforms` is comma-separated.
- `dependencies` is comma-separated package ids.
- URLs may be absolute or relative to repository root.
- Comments start with `#`.

## Merge and precedence behavior

When multiple repositories define the same package id:

- Lower numeric repository priority wins.
- If priority is equal, first repository in sorted order wins.

## Trust policy notes

v1 allows unsigned repositories with warnings.

Future modes:

- warn: allow unsigned with warnings.
- strict: require valid signatures.
- off: skip verification (development only).
