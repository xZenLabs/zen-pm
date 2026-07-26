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
      "incompatible_platforms": ["android", "host"],
      "featured": true,
      "featured_order": 10,
      "featured_image": "packages/koreader-kindle/featured.png",
      "published_at": "2026-03-01T12:00:00Z",
      "source": "https://github.com/koreader/koreader",
      "readme_url": "packages/koreader-kindle/README.md",
      "versions_url": "packages/koreader-kindle/versions.json",
      "dependencies": ["kual"],
      "conflicts": ["zen-ui"],
      "install_url": "packages/koreader-kindle/scripts/install.sh",
      "uninstall_url": "packages/koreader-kindle/scripts/uninstall.sh",
      "size": ""
    }
  ]
}
```

`versions_url` points to a JSON object with a `releases` array. Each release
contains `tag_name`, optional `name` and `prerelease`, plus `assets` with
`name`, `url`, optional `size`, and optional `digest`. Clients must treat a
missing, empty, or not-found versions file as an empty version history and
must not query the upstream source as a fallback.

`platforms` are required compatibility capabilities, not alternatives. For
example, `["kindle", "koreader"]` is shown only when both Kindle and KOReader
compatibility are present.

`incompatible_platforms` excludes a package when any listed capability is
present on the device.

`conflicts` lists package IDs that should not be used together. Clients must
warn before installation but may allow the user to continue.

`published_at` is an optional UTC ISO-8601 timestamp used to sort newly
published packages on the Discover page.

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
