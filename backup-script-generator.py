#!/usr/bin/env python3
"""
backup-script-generator.py
===========================
An interactive wizard that generates a self-contained Bash backup script for a
single Docker-based service in a homelab.

The generated script, on a schedule:
  1. (optionally) stops the container(s) for a consistent copy
  2. dumps any databases to portable files
  3. rsyncs the appdata directory (minus excluded junk) into a backups dir
     on your array, overwriting the previous copy
  4. restarts the container(s)

Duplicati (or any offsite tool) then backs up that backups dir to Google Drive.

Usage:
    python3 backup-script-generator.py

You answer a handful of questions; it writes "backup-<app>.sh" (executable)
and prints a ready-to-paste cron line.
"""

import os
import stat
import sys
import textwrap
from datetime import datetime


# --------------------------------------------------------------------------- #
# Small prompt helpers
# --------------------------------------------------------------------------- #
def ask(prompt, default=None):
    suffix = f" [{default}]" if default not in (None, "") else ""
    try:
        val = input(f"{prompt}{suffix}: ").strip()
    except EOFError:
        val = ""
    return val if val else (default if default is not None else "")


def ask_yn(prompt, default=True):
    d = "Y/n" if default else "y/N"
    val = ask(f"{prompt} [{d}]", "").lower()
    if val == "":
        return default
    return val.startswith("y")


def ask_choice(prompt, choices):
    """choices: list of (key, label). Returns the chosen key."""
    print(prompt)
    for i, (_, label) in enumerate(choices, 1):
        print(f"  {i}) {label}")
    while True:
        raw = ask("Choose", "1")
        try:
            idx = int(raw)
            if 1 <= idx <= len(choices):
                return choices[idx - 1][0]
        except ValueError:
            pass
        print("  Please enter a number from the list.")


def banner(text):
    print("\n" + "=" * 60)
    print(text)
    print("=" * 60)


# --------------------------------------------------------------------------- #
# Shell-quoting helper for safely baking values into the generated script
# --------------------------------------------------------------------------- #
def sq(value):
    """Single-quote a value for safe inclusion in bash."""
    return "'" + str(value).replace("'", "'\\''") + "'"


# --------------------------------------------------------------------------- #
# Collect answers
# --------------------------------------------------------------------------- #
def collect():
    banner("Backup script generator")
    print(
        "Answer a few questions about one service. Paths should be absolute and\n"
        "as seen on the HOST (the machine/array where cron will run the script)."
    )

    cfg = {}
    cfg["app"] = ask("\nApp name (used for filenames and the backup subfolder)", "myapp")
    cfg["appdata"] = ask("Appdata directory to back up (absolute host path)",
                         f"/mnt/appdata/{cfg['app']}")
    cfg["dest_root"] = ask("Backups destination root on your array (absolute host path)",
                          "/mnt/backups/duplicati-source")

    # ---- container management -------------------------------------------- #
    banner("Container management")
    mode = ask_choice(
        "How is this app's container managed?",
        [("compose", "docker compose"),
         ("standalone", "standalone docker (by name)")],
    )
    cfg["container_mode"] = mode
    if mode == "compose":
        cfg["compose_dir"] = ask("Path to the compose project dir (folder with the compose file)",
                                cfg["appdata"])
        cfg["compose_service"] = ask("Specific service name to stop (blank = whole project)", "")
        cfg["containers"] = []
    else:
        names = ask("Container name(s), comma-separated", cfg["app"])
        cfg["containers"] = [n.strip() for n in names.split(",") if n.strip()]
        cfg["compose_dir"] = ""
        cfg["compose_service"] = ""

    cfg["stop"] = ask_yn(
        "\nStop the container(s) during the file copy for a consistent snapshot?\n"
        "(Recommended for SQLite-backed apps; gives a clean cold copy)",
        default=True,
    )

    # ---- databases -------------------------------------------------------- #
    banner("Database dumps")
    print(
        "Logical dumps are portable across version upgrades and are the safest\n"
        "way to capture a live database. Add one entry per database.\n"
        "Server DBs (postgres/mysql/mongo) are dumped via 'docker exec' into\n"
        "their container, so you need no DB client tools on the host."
    )
    dbs = []
    while ask_yn("\nAdd a database to dump?", default=False):
        dbtype = ask_choice(
            "Database type:",
            [("sqlite", "SQLite (a .db file inside appdata)"),
             ("postgres", "PostgreSQL"),
             ("mysql", "MySQL / MariaDB"),
             ("mongo", "MongoDB")],
        )
        db = {"type": dbtype}
        if dbtype == "sqlite":
            db["file"] = ask("  Path to the .db file (absolute host path)",
                            os.path.join(cfg["appdata"], "app.db"))
        else:
            db["container"] = ask("  Name of the container running the database",
                                  f"{cfg['app']}-db")
            db["user"] = ask("  Database user", "root" if dbtype == "mysql" else "postgres")
            db["password"] = ask("  Database password (blank if none / trusted auth)", "")
            if dbtype == "mongo":
                db["authdb"] = ask("  Auth database (blank if none)", "admin")
                db["name"] = ask("  Database name (blank = all databases)", "")
            else:
                db["all"] = ask_yn("  Dump ALL databases on this server?", default=False)
                if not db["all"]:
                    db["name"] = ask("  Database name to dump", cfg["app"])
        dbs.append(db)
    cfg["dbs"] = dbs

    # ---- excludes --------------------------------------------------------- #
    banner("Excludes (save space)")
    default_excludes = [
        "*/cache/*", "*/Cache/*", "*/Caches/*",
        "*/transcode/*", "*/transcodes/*", "*/Transcode/*",
        "*/thumbnails/*", "*/metadata/*Cache*",
        "*/logs/*", "*/log/*", "*.log", "*.tmp", "*/tmp/*",
    ]
    if ask_yn("Exclude common regenerable junk (caches, transcodes, logs, *.tmp)?", default=True):
        cfg["excludes"] = list(default_excludes)
    else:
        cfg["excludes"] = []
    extra = ask("Additional exclude patterns (comma-separated rsync patterns, blank for none)", "")
    cfg["excludes"] += [e.strip() for e in extra.split(",") if e.strip()]

    # ---- schedule --------------------------------------------------------- #
    banner("Schedule")
    print(
        "A cron expression has 5 fields: minute hour day-of-month month day-of-week.\n"
        "Examples:  '0 3 * * *' = 3:00 AM daily   |   '30 2 * * 0' = 2:30 AM Sundays"
    )
    cfg["cron"] = ask("Cron schedule", "0 3 * * *")

    # ---- output ----------------------------------------------------------- #
    default_out = os.path.join(os.getcwd(), f"backup-{cfg['app']}.sh")
    cfg["outfile"] = ask("\nWhere to write the generated script", default_out)

    return cfg


# --------------------------------------------------------------------------- #
# Build the database-dump bash for one DB
# --------------------------------------------------------------------------- #
def db_dump_snippet(db):
    t = db["type"]
    if t == "sqlite":
        return textwrap.dedent(f"""\
            # --- SQLite: {db['file']} ---
            SRC={sq(db['file'])}
            OUT="$DUMP_DIR/$(basename "$SRC").sqlite"
            if [ "$STOP" = "1" ]; then
                # App is stopped: a plain copy is consistent.
                cp -f "$SRC" "$OUT"
            else
                # App is running: use SQLite's online backup for a clean copy.
                # Requires the 'sqlite3' binary on the host (apt install sqlite3).
                sqlite3 "$SRC" ".backup '$OUT'"
            fi
            log "  sqlite dumped -> $OUT"
        """)

    if t == "postgres":
        target = "--all" if db.get("all") else f"-d {sq(db['name'])}"
        tool = "pg_dumpall" if db.get("all") else "pg_dump"
        args = "" if db.get("all") else f"-d {sq(db['name'])}"
        fname = "all-databases" if db.get("all") else db.get("name", "db")
        pw = f"-e PGPASSWORD={sq(db['password'])} " if db.get("password") else ""
        return textwrap.dedent(f"""\
            # --- PostgreSQL via container {db['container']} ---
            OUT="$DUMP_DIR/pg-{fname}.sql"
            docker exec {pw}{sq(db['container'])} {tool} -U {sq(db['user'])} {args} > "$OUT"
            log "  postgres dumped -> $OUT"
        """)

    if t == "mysql":
        sel = "--all-databases" if db.get("all") else f"--databases {db['name']}"
        fname = "all-databases" if db.get("all") else db.get("name", "db")
        pw = f"-e MYSQL_PWD={sq(db['password'])} " if db.get("password") else ""
        inner = f"-u{db['user']} --single-transaction --quick {sel}"
        cmd = (f"if command -v mariadb-dump >/dev/null 2>&1; then mariadb-dump {inner}; "
               f"else mysqldump {inner}; fi")
        return textwrap.dedent(f"""\
            # --- MySQL/MariaDB via container {db['container']} ---
            # MariaDB 11+ ships 'mariadb-dump' (no 'mysqldump'); MySQL ships 'mysqldump'.
            OUT="$DUMP_DIR/mysql-{fname}.sql"
            docker exec {pw}{sq(db['container'])} sh -c {sq(cmd)} > "$OUT"
            log "  mysql dumped -> $OUT"
        """)

    if t == "mongo":
        auth = ""
        if db.get("password"):
            auth = f"-u {sq(db['user'])} -p {sq(db['password'])} "
            if db.get("authdb"):
                auth += f"--authenticationDatabase {sq(db['authdb'])} "
        dbsel = f"--db {sq(db['name'])} " if db.get("name") else ""
        fname = db.get("name") or "all-databases"
        return textwrap.dedent(f"""\
            # --- MongoDB via container {db['container']} ---
            OUT="$DUMP_DIR/mongo-{fname}.archive.gz"
            docker exec {sq(db['container'])} sh -c "mongodump {auth}{dbsel}--archive --gzip" > "$OUT"
            log "  mongo dumped -> $OUT"
        """)

    return f"# (unknown db type: {t})\n"


# --------------------------------------------------------------------------- #
# Restore manifest: a sourceable file restore.sh reads to put an app back.
# Each DB is one line of 8 pipe-separated fields:
#   type|container|user|password|name|all|file|authdb
# --------------------------------------------------------------------------- #
def manifest_db_entries(dbs):
    lines = []
    for db in dbs:
        t = db["type"]
        if t == "sqlite":
            fields = ["sqlite", "", "", "", "", "", db["file"], ""]
        elif t in ("postgres", "mysql"):
            fields = [t, db["container"], db["user"], db.get("password", ""),
                      "" if db.get("all") else db.get("name", ""),
                      "1" if db.get("all") else "0", "", ""]
        elif t == "mongo":
            fields = ["mongo", db["container"], db["user"], db.get("password", ""),
                      db.get("name", ""), "", "", db.get("authdb", "")]
        else:
            continue
        lines.append("|".join(fields))
    return "\n".join(lines)


def manifest_text(cfg):
    containers = " ".join(cfg["containers"])
    entries = manifest_db_entries(cfg["dbs"])
    return (
        f"APP='{cfg['app']}'\n"
        f"APPDATA='{cfg['appdata']}'\n"
        f"CONTAINER_MODE='{cfg['container_mode']}'\n"
        f"COMPOSE_DIR='{cfg['compose_dir']}'\n"
        f"COMPOSE_SERVICE='{cfg['compose_service']}'\n"
        f"CONTAINERS='{containers}'\n"
        f"STOP='{1 if cfg['stop'] else 0}'\n"
        f"DB_ENTRIES='{entries}'\n"
    )


# --------------------------------------------------------------------------- #
# Build the full bash script
# --------------------------------------------------------------------------- #
def build_script(cfg):
    # stop / start commands
    if cfg["container_mode"] == "compose":
        svc = cfg["compose_service"]
        svc_arg = f" {sq(svc)}" if svc else ""
        stop_cmd = f'(cd {sq(cfg["compose_dir"])} && docker compose stop{svc_arg})'
        start_cmd = f'(cd {sq(cfg["compose_dir"])} && docker compose start{svc_arg})'
        targets_desc = f"compose project at {cfg['compose_dir']}" + (f" (service {svc})" if svc else "")
    else:
        names = " ".join(sq(c) for c in cfg["containers"])
        stop_cmd = f"docker stop {names}"
        start_cmd = f"docker start {names}"
        targets_desc = "containers: " + ", ".join(cfg["containers"])

    # excludes as rsync args
    exclude_lines = "".join(
        f"    --exclude={sq(p)} \\\n" for p in cfg["excludes"]
    )

    # db dumps
    if cfg["dbs"]:
        db_block = "\n".join(db_dump_snippet(db) for db in cfg["dbs"])
        db_section = textwrap.indent(db_block, "    ")
    else:
        db_section = "    log \"  no databases configured\"\n"

    stop_flag = "1" if cfg["stop"] else "0"
    manifest = manifest_text(cfg)
    generated = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    script = f"""#!/usr/bin/env bash
#
# backup-{cfg['app']}.sh  --  generated {generated}
# Service: {cfg['app']}
# Targets: {targets_desc}
#
# What it does, in order:
#   1. {'stops the container(s)' if cfg['stop'] else 'leaves the container(s) running'}
#   2. dumps configured databases into a 'dumps/' subfolder
#   3. rsyncs appdata into the backups dir (overwriting the previous copy)
#   4. restarts the container(s) {'(via a trap, even on error)' if cfg['stop'] else ''}
#
# Drop this in the app's root dir and schedule it with cron (see bottom).
# It is safe to re-run; an overlapping run is prevented by a lock file.

set -euo pipefail

# ----------------------------- CONFIG -------------------------------------- #
APP={sq(cfg['app'])}
APPDATA={sq(cfg['appdata'])}
DEST_ROOT={sq(cfg['dest_root'])}
STOP={stop_flag}                       # 1 = stop container(s) during file copy

DEST="$DEST_ROOT/$APP"            # this app's folder inside the backups root
DUMP_DIR="$DEST/dumps"            # database dumps live here
DATA_DIR="$DEST/appdata"          # mirrored appdata lives here
LOCKDIR="/tmp/backup-$APP.lock.d"  # atomic-mkdir lock (portable; no 'flock' needed)
LOGFILE="$DEST/backup.log"
# --------------------------------------------------------------------------- #

mkdir -p "$DEST" "$DUMP_DIR" "$DATA_DIR"

log() {{ echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$LOGFILE"; }}

# Prevent two runs overlapping. An atomic 'mkdir' is the lock, so this works
# everywhere -- including macOS, which has no util-linux 'flock'.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "Another run is in progress (lock: $LOCKDIR); exiting."
    exit 0
fi

require() {{ command -v "$1" >/dev/null 2>&1 || {{ log "ERROR: '$1' not found on host"; exit 1; }}; }}
require docker
require rsync

# Write a manifest describing how to restore this app. restore.sh reads this.
cat > "$DEST/restore-manifest.env" <<'MANIFEST'
{manifest}MANIFEST

STOPPED=0
start_containers() {{
    if [ "$STOPPED" = "1" ]; then
        log "Restarting container(s)..."
        {start_cmd}
        STOPPED=0
    fi
}}
# On exit: restart the app (if we stopped it) and release the lock.
cleanup() {{ start_containers; rmdir "$LOCKDIR" 2>/dev/null || true; }}
trap cleanup EXIT

log "===== Backup of $APP starting ====="

# 1) Dump databases (do this BEFORE stopping if you rely on docker exec,
#    so the DB container is still up).
log "Dumping databases..."
{db_section}
# 2) Stop containers for a consistent file copy (optional).
if [ "$STOP" = "1" ]; then
    log "Stopping container(s)..."
    {stop_cmd}
    STOPPED=1
fi

# 3) Mirror appdata into the backups dir (--delete keeps it an exact copy,
#    so old/removed files don't accumulate -> "overwrite latest").
log "Copying appdata -> $DATA_DIR"
rsync -a --delete \\
{exclude_lines}    "$APPDATA"/ "$DATA_DIR"/

# 4) Restart happens automatically via the EXIT trap.
log "===== Backup of $APP finished OK ====="

# --------------------------------------------------------------------------- #
# SCHEDULE (cron)
# --------------------------------------------------------------------------- #
# Install once with:   crontab -e
# Then add this line:
#
#   {cfg['cron']}  /bin/bash {os.path.join(cfg['appdata'], f'backup-{cfg["app"]}.sh')} >> {os.path.join(cfg['dest_root'], cfg['app'], 'cron.log')} 2>&1
#
# (Adjust the script path if you place it somewhere other than the appdata dir.)
"""
    return script


# --------------------------------------------------------------------------- #
def main():
    cfg = collect()
    script = build_script(cfg)

    out = cfg["outfile"]
    with open(out, "w") as f:
        f.write(script)
    # chmod +x
    st = os.stat(out)
    os.chmod(out, st.st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    script_runtime_path = os.path.join(cfg["appdata"], f"backup-{cfg['app']}.sh")
    cron_log = os.path.join(cfg["dest_root"], cfg["app"], "cron.log")

    banner("Done")
    print(f"Generated: {out}\n")
    print("Next steps:")
    print(f"  1. Copy it into the app's root dir, e.g.:")
    print(f"       cp {sq(out)} {sq(script_runtime_path)}")
    print(f"  2. Test it once by hand and watch the output:")
    print(f"       sudo /bin/bash {sq(script_runtime_path)}")
    print(f"  3. Schedule it: run  crontab -e  and add this line:\n")
    print(f"       {cfg['cron']}  /bin/bash {script_runtime_path} >> {cron_log} 2>&1\n")
    print("  4. Point Duplicati at the backups root so it captures every app:")
    print(f"       {cfg['dest_root']}")
    print("\nNote: each run writes a 'restore-manifest.env' into the app's backup")
    print("folder. Keep restore.sh in the backups root to restore any app from it.")


if __name__ == "__main__":
    sys.exit(main())
