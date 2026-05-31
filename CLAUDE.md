# app_snap — Docker-app backup/restore toolkit

A homelab toolkit that produces clean, consistent local backups of Dockerized
services (configs, appdata, databases) into a single directory, so that an
offsite tool like Duplicati can ship that directory to cloud storage without
ever having to wrestle with active databases itself.

## The problem this solves

The user (Basil) backs up to Google Drive (100 GB paid tier) via Duplicati.
Pointing Duplicati straight at Docker appdata caused corrupt/torn database
backups: file-copying tools read databases block-by-block over time, so a SQLite
or Postgres data file mid-write produces a file representing no single instant.
On restore that file is corrupt or requires recovery.

The accepted fix is a two-layer architecture:

1. **Dump layer (this project):** orchestrates per-service backups locally —
   dumps databases with their own tools (`pg_dump`, `mariadb-dump`, etc.), stops
   containers when needed for cold file copies, mirrors appdata into a backups
   directory on the array.
2. **Offsite layer (Duplicati):** points at that backups directory and ships
   it to Google Drive. Versioning lives offsite; locally we keep one "latest"
   copy per service.

No file-copying backup tool solves the live-DB problem automatically. The
"automation" is in orchestrating dump → cold-copy → restart, and in making
that easy to set up per service.

## Architecture

```
+---------------------- HOST (Docker host / array) ----------------------+
|                                                                        |
|  per-service:                                                          |
|  backup-<app>.sh  ──cron──▶  dumps + appdata mirror   ┐                |
|                              + restore-manifest.env   │                |
|                                                       ▼                |
|                              <BACKUPS_ROOT>/<app>/                     |
|                                                       ▲                |
|  restore.sh (interactive) ────reads manifests────────┘                 |
|     ↳ safety snapshot → restore → verify → keep OR rollback            |
|                                                                        |
+----------------------------------|-------------------------------------+
                                   ▼
                         Duplicati → Google Drive
```

Per service: the **generator** (a Python wizard) produces a tailored Bash
backup script. That script runs on cron, dumps the databases via `docker exec`
into their containers (so no DB clients are needed on the host), optionally
stops the container/stack for a clean appdata copy, rsyncs appdata into the
backups root, and restarts the container. It also drops a `restore-manifest.env`
recording every detail restore.sh needs.

Across all services: a single **restore.sh** sits in the backups root,
discovers every app via its manifest, presents an interactive menu, and runs
the restore with a safety-net rollback (take a temp snapshot of current state →
restore the chosen backup → ask the user if it works → keep, or roll back to
the snapshot).

## Files

| File | Role |
|---|---|
| `backup-script-generator.py` | Interactive Python wizard. Asks per-service questions and writes `backup-<app>.sh`. The generated script is self-contained — config baked in. |
| `restore.sh` | Generic, lives in the backups root. Reads any app's `restore-manifest.env` and performs a safety-net restore. Supports `DRY_RUN=1`. |
| `crashtest-stack/docker-compose.yml` | A 3-container test stack: a lightweight Alpine sleeper (`crashtest-app`) bind-mounting `./appdata`, plus `postgres:16-alpine` and `mariadb:11`, both with seed SQL that loads on first boot. |
| `crashtest-stack/seed/` | `postgres-init.sql` and `mariadb-init.sql` create a `widgets` table with 3 rows, used as the verifiable baseline. |
| `crashtest-stack/appdata/` | Mock app data. `config.yml` and `data/notes.txt` are tracked sources; `app.db` (SQLite seeded with a `settings` table including a `marker` row) is also tracked. `cache/tempfile.bin` (1 MB random) is gitignored; the harness regenerates it. `logs/app.log` exists to test the `*.log` exclude. |
| `crashtest.sh` | End-to-end harness. Self-resets the stack (`down -v && up -d`), drives the wizard non-interactively, runs a backup, then runs disaster/recover, rollback, and resilience (missing-dump) scenarios, printing PASS/FAIL with a tally. **Currently 33/33.** |

## Conventions and design decisions (with rationale)

**Local "overwrite latest" only.** Each backup overwrites the previous one in
the array. Versioning is Duplicati's job offsite. Keeps array footprint small.

**Database dumps via `docker exec`.** Avoids needing Postgres/MySQL/Mongo
clients on the host. Implies the DB container must be running when the dump
runs — handled by the backup script doing dumps BEFORE stopping the app
container, and by restore.sh explicitly `docker start`ing each DB container
before any dump/import call.

**SQLite uses cold file copy.** If `STOP=1`, the SQLite dump is a simple
`cp` after the container is stopped, which is guaranteed consistent. If
`STOP=0`, it uses `sqlite3 .backup` on the host (only path that needs
`sqlite3` installed on the host).

**Excludes use directory-name patterns.** Patterns like `cache/` (no leading
slash, trailing slash) match a directory of that name at any depth, including
top level. The earlier `*/cache/*` pattern missed top-level dirs — bug we hit.

**Postgres dumps use `--clean --if-exists`.** Plain `pg_dump` recreates schema
and `COPY`s data but doesn't drop existing objects first, so restoring onto a
populated database APPENDS instead of replaces. `--clean --if-exists` makes
restores idempotent. (MariaDB's `mysqldump --databases` already includes
`DROP TABLE` so it never had this issue.)

**MySQL/MariaDB commands are auto-detected.** Generated commands run inside
the DB container as `sh -c 'if command -v mariadb-dump …; then …; else …'`.
This works on MariaDB 11+ (which dropped `mysqldump`/`mysql` for
`mariadb-dump`/`mariadb`) and on real MySQL alike.

**Restore = safety-net rollback.** `restore.sh`'s sequence is: stop app →
snapshot CURRENT state to `.safety-<app>-<ts>/` → restore the chosen backup →
start app → ask "does it work?" → on yes, delete safety; on no, roll back from
safety. The snapshot uses the same logic as a backup, so it captures live DB
state cleanly.

**Restore appdata uses rsync `--delete`.** A full restore returns appdata
exactly to the backed-up state. Side effect: any locally-present excluded
dirs (caches, logs) get removed — usually fine because they're regenerable.
The harness surfaces this as an `[INFO]` line.

**Backup mirror uses `rsync --delete --delete-excluded`.** `--delete-excluded`
removes destination files matching exclude patterns, so the mirror self-cleans
files that an earlier (broken) run let through. Without this, an orphan file
sticks forever — bug we hit.

**Lock file uses atomic `mkdir`, not `flock`.** macOS has no `flock` (it's
Linux util-linux). `mkdir "$LOCKDIR"` is atomic everywhere. The `EXIT` trap
runs a `cleanup` function that both restarts containers (if stopped) and
removes the lock dir.

**Bash 3.2 compatibility.** macOS ships bash 3.2, which lacks `mapfile`. The
restore.sh uses a portable `while IFS= read … done < <(find …)` instead.
Generated backup scripts also avoid bash 4+ features.

## The restore-manifest.env contract

The backup script writes this on every run; `restore.sh` sources it as bash.
Format:

```sh
APP='<name>'
APPDATA='<absolute host path to live appdata>'
CONTAINER_MODE='compose'      # or 'standalone'
COMPOSE_DIR='<abs path to compose project>'   # if compose
COMPOSE_SERVICE='<service>'   # if compose; empty = whole project
CONTAINERS='<space-separated names>'           # if standalone
STOP='1'                       # or '0'
DB_ENTRIES='<one DB per line, 8 pipe-separated fields>'
# fields: type|container|user|password|name|all|file|authdb
# type ∈ {sqlite, postgres, mysql, mongo}
# sqlite uses only: type, file
# postgres/mysql use: type, container, user, password, name (or empty if all=1), all (1/0)
# mongo uses: type, container, user, password, name (optional), authdb (optional)
```

Any change to this format must be made in BOTH the generator (`manifest_text`
in `backup-script-generator.py`) and the parser (`while IFS='|' read -r ...`
loops in `restore.sh`'s `dump_current_dbs` and `import_dbs`).

## Wizard prompt order (for non-interactive driving)

In order, as `input()` reads them. Empty string = default. Used by the harness:

1. app name
2. appdata absolute path
3. backups dest root absolute path
4. container mgmt: `1` compose | `2` standalone
5. (compose) compose project dir
6. (compose) service name (blank = whole project)
   (standalone instead) container names, comma-separated
7. stop containers during copy? Y/n
8. add database? y/N — loops:
   9. db type: `1` sqlite | `2` postgres | `3` mysql | `4` mongo
   10. (sqlite) db file path
       (server DBs) container, user, password, ALL dbs? y/N, db name (if not all)
       (mongo) container, user, password, authdb, db name (blank = all)
11. (loop back to "add database?")
12. exclude common junk? Y/n
13. additional exclude patterns (comma-separated)
14. cron schedule (default `0 3 * * *`)
15. output script path

## Testing — the crash-test stack

`./crashtest.sh` is the canonical end-to-end test. Run it on the Docker host
(it brings the stack up itself with `down -v && up -d` so it's idempotent).
It exercises every code path in one run:

- generates `backup-crashtest.sh` non-interactively
- runs a backup; validates dumps by **content** (SQLite header, `COPY`/`INSERT`
  in Postgres, `INSERT INTO` in MariaDB) — not mere file existence
- asserts excludes worked (no `cache/tempfile.bin`, no `logs/app.log`)
- wrecks data, restores "everything", asserts original data returned
- wrecks data into a different known state, restores but answers "no" at the
  verify prompt, asserts rollback returned the pre-restore state
- hides a Postgres dump, runs a databases-only restore, asserts WARN is
  emitted and MariaDB still restores
- final cleanup restore back to baseline

Adds two `[INFO]` lines for known-but-expected behaviors (excluded dirs
removed on restore; which mariadb client the container has).

If a check turns red, the diagnosis pattern that has worked twice now:

1. Read `crashtest-backups/crashtest/backup.log` to see how far the backup
   script got.
2. Read `crashtest-backups/crashtest/dumps/` files (especially small ones —
   an OCI runtime error gets written into the file when `docker exec` fails).
3. Read `.crashtest-last-run.log` for the most recent `restore.sh` output.
4. Look for stale artifacts vs current ones via `stat` timestamps.

## Portability constraints (lessons learned the hard way)

- **macOS bash is 3.2.** No `mapfile`, no `${var,,}`, no associative arrays.
- **macOS has no `flock`.** Use atomic `mkdir` locks.
- **Postgres 16+ `pg_dump` uses `COPY` not `INSERT INTO`** for data. Any
  validation that greps for `INSERT INTO` will fail on valid dumps.
- **MariaDB 11+ ships `mariadb-dump` and `mariadb`, not `mysqldump`/`mysql`.**
  When `docker exec`-ing a missing command, docker writes the error to the
  redirected output file — looks like a "successful" small dump unless you
  validate content.
- **rsync `--delete` protects excluded files from deletion** by default; needs
  `--delete-excluded` to keep a mirror clean of files that were once let
  through.
- **rsync patterns without a leading slash but containing `/`** are
  full-path-matched, not basename-matched. `*/cache/*` will not match a
  top-level `cache/`. Prefer trailing-slash dir patterns like `cache/`.

## Repository / git

The repo lives at the project root (`/Users/flopet17/projects/app_snap`).
Standard git, no special setup. Earlier in the project the user's mount
blocked `unlink`, so we used a workaround (external git-dir + history bundle);
that's all gone — the repo is now an ordinary in-folder one. The user enabled
"file deletion" permissions on this folder; both `outputs` (the scratchpad)
and `app_snap` (this folder) allow unlink.

`.gitignore` excludes: `__pycache__/`, `*.pyc`, `crashtest-backups/`,
`backup-crashtest.sh`, `.crashtest-last-run.log`, `.safety-*/`, and
`crashtest-stack/appdata/cache/tempfile.bin` (regenerable noise).

## Open items / known limitations

- **MongoDB is supported by code but never tested end-to-end.** The
  crash-test stack doesn't include Mongo; adding it would be a one-service
  extension to `docker-compose.yml` plus extending the harness wizard answers.
- **Hot-SQLite path is not crash-tested.** The harness always runs with
  `STOP=1`, so the `sqlite3 .backup` (host-side) branch isn't exercised.
- **`systemd` timer output is not implemented.** Currently the generator only
  prints a cron line. We explicitly chose cron over systemd for this project.
- **Restore "appdata-only" mode** works but isn't exercised by the harness
  (only `all` and `dbs` scopes are tested).
- **Single-Postgres-DB restore requires the target DB to exist.** `pg_dump`
  output (even with `--clean`) drops/recreates the schema inside an existing
  database. For full-server restores use the "ALL databases" option, which
  uses `pg_dumpall` (includes CREATE DATABASE).
- **No retention of multiple local timestamped copies.** "Overwrite latest"
  is intentional (Duplicati versions offsite). If the user later wants local
  point-in-time, the generator's `cfg["retention"]` config plumbing would
  need adding (currently absent).

## Workflow conventions

When making changes, the loop is:

1. Edit the script(s).
2. `python3 -c "import py_compile; py_compile.compile('backup-script-generator.py', doraise=True)"`
   for the generator; `bash -n restore.sh` / `bash -n crashtest.sh` for shell.
3. Have the user run `./crashtest.sh` on their Mac host (the sandbox has no
   Docker; running Linux tests here would give false confidence — see below).
4. Read artifacts under `crashtest-backups/` to diagnose any failures.
5. Commit. Plain git in the project folder.

**Tests can only be run on the user's host, not in the Claude sandbox.** The
sandbox is Linux without Docker and would mask the macOS-specific bugs (bash
3.2, no flock, MariaDB tool renames) that turned out to drive most of the
debugging. Use the harness's PASS/FAIL output, plus direct reads of
`crashtest-backups/` artifacts, as the diagnostic feedback loop.
