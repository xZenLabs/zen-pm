# Transaction Model (v1)

Zen PM uses lock files and journals to make package operations recoverable.

## Goals

- Prevent concurrent conflicting operations.
- Keep a replayable history of operation steps.
- Allow interruption-safe recovery and diagnostics.

## State files

- `locks/operation.lock/` - active operation lock directory.
- `journal/<timestamp>-<op>-<target>.journal` - transaction journal.
- `state/installed.db` - installed package records.

## Locking

- Lock acquisition is required before install/uninstall/update.
- Lock ownership is tracked via `pid` file.
- Stale lock cleanup is allowed if PID is not running.

## Journal format

Journals are line-based TSV records:

```text
ts	stage	status	message
```

Common stages:

- `begin`
- `resolve`
- `fetch-script`
- `execute`
- `commit`
- `abort`

Status values:

- `ok`
- `skip`
- `fail`

## Installed database format

`installed.db` uses pipe-separated records:

```text
id|version|repo|installed_at
```

## Recovery behavior (v1)

- If an operation fails, journal status is `abort` and lock is released.
- `rollback` command currently reports latest journal context and planned replay target.
- Full action replay rollback is planned for next iteration.
