#!/usr/bin/env bash
#
# restore.sh -- interactive restore for backups made by backup-<app>.sh
# =====================================================================
# Drop this in the ROOT of your backups directory (the DEST_ROOT you gave the
# generator) and run it:   ./restore.sh
#
# It finds every app's "restore-manifest.env", lets you pick one, asks what to
# restore, and then restores it WITH A SAFETY NET:
#
#   1. stop the app's container(s) / stack
#   2. take a temporary snapshot of the CURRENT state (so we can undo)
#   3. restore the chosen backup over it
#   4. start the app and ask you to test it
#        - works  -> delete the temp snapshot and finish
#        - broken -> roll the app back to the temp snapshot (original state)
#
# Preview everything without changing anything:
#     DRY_RUN=1 ./restore.sh
#
# Requirements on the host: docker, rsync (and sqlite3 only if a SQLite app was
# backed up while running).

set -euo pipefail

DRY="${DRY_RUN:-0}"
ROOT="${BACKUP_ROOT:-$(cd "$(dirname "$0")" && pwd)}"

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
note() { echo "$@"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

# Run a plain command, or just print it under DRY_RUN.
runc() {
    if [ "$DRY" = "1" ]; then echo "  [dry-run] $*"; else "$@"; fi
}

# docker compose in the project dir (handles the cd subshell + dry-run).
compose() {
    if [ "$DRY" = "1" ]; then
        echo "  [dry-run] (cd $COMPOSE_DIR && docker compose $*)"
    else
        ( cd "$COMPOSE_DIR" && docker compose "$@" )
    fi
}

require() {
    command -v "$1" >/dev/null 2>&1 && return 0
    if [ "$DRY" = "1" ]; then echo "  (note: '$1' not found -- fine for a dry run)"; return 0; fi
    echo "ERROR: '$1' not found on host"; exit 1
}

stop_app() {
    note "Stopping $APP ..."
    if [ "$CONTAINER_MODE" = "compose" ]; then
        if [ -n "$COMPOSE_SERVICE" ]; then compose stop "$COMPOSE_SERVICE"; else compose stop; fi
    else
        runc docker stop $CONTAINERS
    fi
}

start_app() {
    note "Starting $APP ..."
    if [ "$CONTAINER_MODE" = "compose" ]; then
        if [ -n "$COMPOSE_SERVICE" ]; then compose start "$COMPOSE_SERVICE"; else compose start; fi
    else
        runc docker start $CONTAINERS
    fi
}

# Make sure a specific DB container is up (needed for docker-exec dump/import,
# e.g. when a whole compose stack was stopped).
db_up() { [ -n "$1" ] && runc docker start "$1"; }

# --------------------------------------------------------------------------- #
# Dump the CURRENT live state of every configured DB into <dir>/dumps
# (used to build the temporary safety snapshot before we overwrite anything).
# --------------------------------------------------------------------------- #
dump_current_dbs() {
    local dd="$1"
    runc mkdir -p "$dd"
    while IFS='|' read -r type container user password name allflag file authdb; do
        [ -z "$type" ] && continue
        case "$type" in
            sqlite)
                local out="$dd/$(basename "$file").sqlite"
                if [ -f "$file" ] || [ "$DRY" = "1" ]; then runc cp -f "$file" "$out"; fi ;;
            postgres)
                db_up "$container"
                local fn; [ "$allflag" = "1" ] && fn="all-databases" || fn="$name"
                local tool args; [ "$allflag" = "1" ] && { tool="pg_dumpall"; args=""; } || { tool="pg_dump"; args="-d $name"; }
                if [ "$DRY" = "1" ]; then
                    echo "  [dry-run] docker exec ${password:+-e PGPASSWORD=***} $container $tool -U $user $args > $dd/pg-$fn.sql"
                else
                    docker exec ${password:+-e PGPASSWORD=$password} "$container" $tool -U "$user" $args > "$dd/pg-$fn.sql"
                fi ;;
            mysql)
                db_up "$container"
                local fn sel; [ "$allflag" = "1" ] && { fn="all-databases"; sel="--all-databases"; } || { fn="$name"; sel="--databases $name"; }
                # MariaDB 11+ has 'mariadb-dump' (no 'mysqldump'); MySQL has 'mysqldump'.
                local mdump="if command -v mariadb-dump >/dev/null 2>&1; then mariadb-dump -u$user --single-transaction --quick $sel; else mysqldump -u$user --single-transaction --quick $sel; fi"
                if [ "$DRY" = "1" ]; then
                    echo "  [dry-run] docker exec ${password:+-e MYSQL_PWD=***} $container sh -c '<mariadb-dump|mysqldump> $sel' > $dd/mysql-$fn.sql"
                else
                    docker exec ${password:+-e MYSQL_PWD=$password} "$container" sh -c "$mdump" > "$dd/mysql-$fn.sql"
                fi ;;
            mongo)
                db_up "$container"
                local fn="${name:-all-databases}"
                local auth=""; [ -n "$password" ] && { auth="-u $user -p $password"; [ -n "$authdb" ] && auth="$auth --authenticationDatabase $authdb"; }
                local dbsel=""; [ -n "$name" ] && dbsel="--db $name"
                if [ "$DRY" = "1" ]; then
                    echo "  [dry-run] docker exec $container sh -c 'mongodump $auth $dbsel --archive --gzip' > $dd/mongo-$fn.archive.gz"
                else
                    docker exec "$container" sh -c "mongodump $auth $dbsel --archive --gzip" > "$dd/mongo-$fn.archive.gz"
                fi ;;
        esac
    done <<< "$DB_ENTRIES"
}

# --------------------------------------------------------------------------- #
# Import every configured DB from <dir>/dumps back into its container.
# --------------------------------------------------------------------------- #
import_dbs() {
    local dd="$1"
    while IFS='|' read -r type container user password name allflag file authdb; do
        [ -z "$type" ] && continue
        case "$type" in
            sqlite)
                local in="$dd/$(basename "$file").sqlite"
                if [ -f "$in" ] || [ "$DRY" = "1" ]; then
                    note "  sqlite: $in -> $file"
                    runc cp -f "$in" "$file"
                fi ;;
            postgres)
                db_up "$container"
                local fn dbarg; [ "$allflag" = "1" ] && { fn="all-databases"; dbarg="-d postgres"; } || { fn="$name"; dbarg="-d $name"; }
                local in="$dd/pg-$fn.sql"
                note "  postgres: $in -> container $container"
                if [ "$DRY" = "1" ]; then
                    echo "  [dry-run] docker exec -i ${password:+-e PGPASSWORD=***} $container psql -U $user $dbarg < $in"
                else
                    [ -f "$in" ] && docker exec -i ${password:+-e PGPASSWORD=$password} "$container" psql -U "$user" $dbarg < "$in" || echo "  WARN: missing $in"
                fi ;;
            mysql)
                db_up "$container"
                local fn; [ "$allflag" = "1" ] && fn="all-databases" || fn="$name"
                local in="$dd/mysql-$fn.sql"
                note "  mysql: $in -> container $container"
                # MariaDB 11+ uses the 'mariadb' client; MySQL uses 'mysql'.
                local mcli="if command -v mariadb >/dev/null 2>&1; then mariadb -u$user; else mysql -u$user; fi"
                if [ "$DRY" = "1" ]; then
                    echo "  [dry-run] docker exec -i ${password:+-e MYSQL_PWD=***} $container sh -c '<mariadb|mysql>' < $in"
                else
                    [ -f "$in" ] && docker exec -i ${password:+-e MYSQL_PWD=$password} "$container" sh -c "$mcli" < "$in" || echo "  WARN: missing $in"
                fi ;;
            mongo)
                db_up "$container"
                local fn="${name:-all-databases}"
                local in="$dd/mongo-$fn.archive.gz"
                local auth=""; [ -n "$password" ] && { auth="-u $user -p $password"; [ -n "$authdb" ] && auth="$auth --authenticationDatabase $authdb"; }
                note "  mongo: $in -> container $container"
                if [ "$DRY" = "1" ]; then
                    echo "  [dry-run] docker exec -i $container sh -c 'mongorestore $auth --archive --gzip --drop' < $in"
                else
                    [ -f "$in" ] && docker exec -i "$container" sh -c "mongorestore $auth --archive --gzip --drop" < "$in" || echo "  WARN: missing $in"
                fi ;;
        esac
    done <<< "$DB_ENTRIES"
}

# Apply a payload (appdata + dbs) from SRC according to MODE (all|appdata|dbs).
apply_payload() {
    local src="$1" mode="$2"
    if [ "$mode" = "all" ] || [ "$mode" = "appdata" ]; then
        note "Restoring appdata from $src/appdata -> $APPDATA"
        runc rsync -a --delete "$src/appdata"/ "$APPDATA"/
    fi
    if [ "$mode" = "all" ] || [ "$mode" = "dbs" ]; then
        note "Restoring databases from $src/dumps ..."
        import_dbs "$src/dumps"
    fi
}

# Snapshot current state into DST according to MODE (app must be stopped first).
snapshot_current() {
    local dst="$1" mode="$2"
    runc mkdir -p "$dst/appdata" "$dst/dumps"
    if [ "$mode" = "all" ] || [ "$mode" = "appdata" ]; then
        note "Snapshotting current appdata -> $dst/appdata"
        runc rsync -a --delete "$APPDATA"/ "$dst/appdata"/
    fi
    if [ "$mode" = "all" ] || [ "$mode" = "dbs" ]; then
        note "Snapshotting current databases -> $dst/dumps"
        dump_current_dbs "$dst/dumps"
    fi
}

ask() { local a; read -r -p "$1 " a; echo "$a"; }

# --------------------------------------------------------------------------- #
# 1) Pick an app
# --------------------------------------------------------------------------- #
require docker
require rsync

hr; echo "Restore tool  (backups root: $ROOT)"
[ "$DRY" = "1" ] && echo ">>> DRY RUN: nothing will actually change <<<"
hr

# Portable manifest list (no 'mapfile' -- macOS ships bash 3.2 which lacks it).
MANIFESTS=()
while IFS= read -r _m; do MANIFESTS+=("$_m"); done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name restore-manifest.env 2>/dev/null | sort)
if [ "${#MANIFESTS[@]}" -eq 0 ]; then
    echo "No restore-manifest.env files found under $ROOT."
    echo "Run a backup first, or set BACKUP_ROOT to the right directory."
    exit 1
fi

echo "Which app do you want to restore?"
i=1
for m in "${MANIFESTS[@]}"; do
    app_name="$(grep -E "^APP=" "$m" | head -1 | cut -d"'" -f2)"
    echo "  $i) $app_name   ($(dirname "$m"))"
    i=$((i + 1))
done
sel="$(ask "Enter a number:")"
if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#MANIFESTS[@]}" ]; then
    echo "Invalid selection."; exit 1
fi
MANIFEST="${MANIFESTS[$((sel - 1))]}"
APPDIR="$(dirname "$MANIFEST")"

# Load the manifest (defines APP, APPDATA, CONTAINER_MODE, COMPOSE_*, CONTAINERS,
# STOP, DB_ENTRIES).
# shellcheck disable=SC1090
source "$MANIFEST"

# --------------------------------------------------------------------------- #
# 2) Pick what to restore
# --------------------------------------------------------------------------- #
echo; echo "What should be restored for '$APP'?"
echo "  1) Everything (appdata + databases)"
echo "  2) Appdata only"
echo "  3) Databases only"
case "$(ask "Enter a number [1]:")" in
    2) MODE="appdata" ;;
    3) MODE="dbs" ;;
    *) MODE="all" ;;
esac

# --------------------------------------------------------------------------- #
# 3) Confirm (this is destructive)
# --------------------------------------------------------------------------- #
echo; hr
echo "About to restore:   $APP"
echo "  scope:            $MODE"
echo "  from backup:      $APPDIR"
echo "  appdata target:   $APPDATA"
echo "  containers:       ${CONTAINERS:-($CONTAINER_MODE)}"
echo "A temporary safety snapshot of the CURRENT state will be taken first,"
echo "so this can be undone if the restored copy doesn't work."
hr
if [ "$DRY" != "1" ]; then
    [ "$(ask "Type 'yes' to proceed:")" = "yes" ] || { echo "Aborted."; exit 0; }
fi

SAFETY="$ROOT/.safety-$APP-$(date +%Y%m%d-%H%M%S)"

# --------------------------------------------------------------------------- #
# 4) Stop -> snapshot current -> restore chosen backup -> start
# --------------------------------------------------------------------------- #
echo; note "=== Step 1/4: stopping app ==="
stop_app

echo; note "=== Step 2/4: safety snapshot of current state -> $SAFETY ==="
snapshot_current "$SAFETY" "$MODE"

echo; note "=== Step 3/4: restoring chosen backup ==="
apply_payload "$APPDIR" "$MODE"

echo; note "=== Step 4/4: starting app ==="
start_app

# --------------------------------------------------------------------------- #
# 5) Verify with the user; keep or roll back
# --------------------------------------------------------------------------- #
echo; hr
echo "Restore complete. Please TEST '$APP' now (open it, log in, check data)."
hr
if [ "$DRY" = "1" ]; then
    echo "[dry-run] Would now ask whether the service works."
    echo "[dry-run]   yes -> delete $SAFETY"
    echo "[dry-run]   no  -> roll back from $SAFETY"
    exit 0
fi

if [ "$(ask "Is '$APP' working correctly? [yes/no]:")" = "yes" ]; then
    note "Great. Removing the temporary safety snapshot."
    rm -rf "$SAFETY"
    echo "Done. '$APP' restored successfully."
else
    echo; hr
    echo "Rolling '$APP' back to its pre-restore state from the safety snapshot..."
    hr
    stop_app
    apply_payload "$SAFETY" "$MODE"
    start_app
    rm -rf "$SAFETY"
    echo "Rollback complete. '$APP' is back to how it was before the restore."
    echo "The restored copy may be corrupt or incomplete -- check the backup in:"
    echo "  $APPDIR"
    exit 1
fi
