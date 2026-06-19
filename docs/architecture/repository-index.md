# Repository Manifest Contract (v1)

ZenPM repositories are static-hostable and expose a package manifest.

## Required files

- `manifest.json` - canonical metadata and tooling source.

## manifest.json

`manifest.json` must include:

- `schema_version` (string)
- `repo` (object): repository metadata.
- `packages` (array[object]): package summary entries.

Example:

```json
{
  "schema_version": "1",
  "repo": {
    "id": "zenpm-default",
    "name": "ZenPM Repository",
    "url": "https://example.invalid/zenpm/default",
    "icon_url": "assets/repo-icon.svg"
  },
  "packages": [
    {
      "id": "koreader-kindle",
      "name": "KOReader (Kindle)",
      "version": "2026.03.0",
      "category": "utility",
      "platforms": ["kindle", "koreader"],
      "featured": true,
      "featured_image": "packages/koreader-kindle/featured.png",
      "source": "https://github.com/koreader/koreader",
      "dependencies": ["kual"],
      "install_url": "packages/koreader-kindle/scripts/install.sh",
      "uninstall_url": "packages/koreader-kindle/scripts/uninstall.sh",
      "size": ""
    }
  ]
}
```

`platforms` are required compatibility capabilities, not alternatives. For
example, `["kindle", "koreader"]` is shown only when both Kindle and KOReader
compatibility are present.

## Merge and precedence behavior

Package `icon_url` is package-specific. When it is omitted, clients should fall
back to `repo.icon_url`; if that is omitted too, clients may fall back to the
repository favicon.

When multiple repositories define the same package id:

- Lower numeric repository priority wins.
- If priority is equal, first repository in sorted order wins.

## Trust policy notes

v1 allows unsigned repositories with warnings.

Future modes:

- warn: allow unsigned with warnings.
- strict: require valid signatures.
- off: skip verification (development only).
