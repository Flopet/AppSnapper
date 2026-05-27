#!/usr/bin/env bash
#
# crashtest.sh -- end-to-end self-test for the backup/restore toolkit
# ===================================================================
# Runs the WHOLE cycle against the crashtest-stack and reports PASS/FAIL:
#
#   setup     reset appdata + (re)create the stack so DBs re-seed cleanly
#   generate  drive the wizard non-interactively -> backup-crashtest.sh
#   backup    run it; verify dumps, manifest, excludes, and that the app restarts
#   recover   wreck the data, restore "everything", verify it all comes back
#   rollback  wreck again, restore but report the service BROKEN -> verify it
#             rolls back to the pre-restore state (the safety-net undo)
#   resilience  hide a dump file and confirm restore WARNs instead of dying
#
# It is safe to re-run; it resets itself each time. Nothing here touches your
# real services -- only the crashtest-* containers and crashtest-stack/appdata.
#
# Usage:   ./crashtest.sh
# Requires on the host: docker (with compose), python3, rsync.

set -uo pipefail   # deliberately NOT -e: the harness handles failures itself

ROOT="$(cd "$(dirname "$0")" && pwd)"
STACK="$ROOT/crashtest-stack"
GEN="$ROOT/backup-script-generator.py"
RESTORE="$ROOT/restore.sh"
BK="$ROOT/crashtest-backups"
BACKUP_SCRIPT="$ROOT/backup-crashtest.sh"
APPDATA="$STACK/appdata"
DB_APP="$APPDATA/app.db"
LOG="$ROOT/.crashtest-last-run.log"

PASS=0; FAIL=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; else G=; R=; Y=; B=; N=; fi
pass(){ PASS=$((PASS+1)); printf "  ${G}[PASS]${N} %s\n" "$1"; }
fail(){ FAIL=$((FAIL+1)); printf "  ${R}[FAIL]${N} %s\n" "$1"; }
info(){ printf "  ${Y}[INFO]${N} %s\n" "$1"; }
section(){ printf "\n${B}== %s ==${N}\n" "$1"; }
check(){ if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1 (got '$2', want '$3')"; fi; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not found."; exit 2; }; }
need docker; need python3; need rsync
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' not available."; exit 2; }

# --------------------------------------------------------------------------- #
# DB / data helpers
# --------------------------------------------------------------------------- #
MARIA_CLIENT="mariadb"
detect_maria_client(){
    for _ in $(seq 1 30); do
        c=$(docker exec crashtest-mariadb sh -c 'command -v mariadb || command -v mysql' 2>/dev/null | head -1)
        [ -n "$c" ] && { MARIA_CLIENT="$(basename "$c")"; return; }
        sleep 2
    done
}
pg_q(){ docker exec crashtest-postgres psql -U postgres -d testdb -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
maria_q(){ docker exec crashtest-mariadb "$MARIA_CLIENT" -uroot -prootpw -N -e "$1" testdb 2>/dev/null | tr -d '[:space:]'; }
sqlite_marker(){ python3 -c "import sqlite3,sys;r=sqlite3.connect(sys.argv[1]).execute(\"select value from settings where key='marker'\").fetchone();print(r[0] if r else 'MISSING')" "$DB_APP" 2>/dev/null; }
sqlite_set(){ python3 -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);c.execute(\"update settings set value=? where key='marker'\",(sys.argv[2],));c.commit()" "$DB_APP" "$1"; }
notes(){ cat "$APPDATA/data/notes.txt" 2>/dev/null; }
app_running(){ docker inspect -f '{{.State.Running}}' crashtest-app 2>/dev/null; }

wait_dbs(){
    info "waiting for databases to accept connections..."
    for _ in $(seq 1 45); do docker exec crashtest-postgres pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done
    detect_maria_client
    for _ in $(seq 1 45); do docker exec crashtest-mariadb "$MARIA_CLIENT" -uroot -prootpw -e 'select 1' >/dev/null 2>&1 && break; sleep 2; done
    info "mariadb client in container: $MARIA_CLIENT"
}

seed_appdata(){
    rm -rf "$APPDATA"; mkdir -p "$APPDATA/data" "$APPDATA/cache" "$APPDATA/logs"
    cat > "$APPDATA/config.yml" <<'C'
app_name: crashtest
theme: dark
data_version: 1
C
    echo "important user data v1 - original" > "$APPDATA/data/notes.txt"
    head -c 1048576 /dev/urandom > "$APPDATA/cache/tempfile.bin"
    printf '2026-05-27 12:00:00 INFO started\n' > "$APPDATA/logs/app.log"
    python3 - "$DB_APP" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT, value TEXT)")
c.execute("DELETE FROM settings")
c.executemany("INSERT INTO settings VALUES (?,?)",
              [("theme","dark"), ("version","1"), ("marker","original-data-v1")])
c.commit(); c.close()
PY
}

# Wreck every data store into a known, distinct state.
wreck_to(){  # $1 = label used as markers; $2 = widget row count to leave
    local label="$1" rows="$2"
    pg_q "DELETE FROM widgets;" >/dev/null
    maria_q "DELETE FROM widgets;" >/dev/null
    local i=1
    while [ "$i" -le "$rows" ]; do
        pg_q "INSERT INTO widgets (name, qty) VALUES ('$label-$i', $i);" >/dev/null
        maria_q "INSERT INTO widgets (name, qty) VALUES ('$label-$i', $i);" >/dev/null
        i=$((i+1))
    done
    echo "$label" > "$APPDATA/data/notes.txt"
    sqlite_set "$label"
}

run_restore(){  # $1 = "1|2|3" scope, $2 = "yes|no" works-correctly answer
    printf '1\n%s\nyes\n%s\n' "$1" "$2" | BACKUP_ROOT="$BK" bash "$RESTORE" >"$LOG" 2>&1
}

# --------------------------------------------------------------------------- #
section "SETUP  (resetting stack + appdata to a clean seed)"
# --------------------------------------------------------------------------- #
[ -f "$GEN" ] || { echo "Cannot find $GEN"; exit 2; }
[ -f "$RESTORE" ] || { echo "Cannot find $RESTORE"; exit 2; }
[ -f "$STACK/docker-compose.yml" ] || { echo "Cannot find the stack at $STACK"; exit 2; }

seed_appdata
( cd "$STACK" && docker compose down -v >/dev/null 2>&1; docker compose up -d >/dev/null 2>&1 )
wait_dbs
check "stack: crashtest-app is running" "$(app_running)" "true"
check "seed: postgres has 3 widgets" "$(pg_q 'select count(*) from widgets;')" "3"
check "seed: mariadb has 3 widgets"  "$(maria_q 'select count(*) from widgets;')" "3"
check "seed: sqlite marker"          "$(sqlite_marker)" "original-data-v1"

# --------------------------------------------------------------------------- #
section "GENERATE  (driving the wizard non-interactively)"
# --------------------------------------------------------------------------- #
rm -f "$BACKUP_SCRIPT"
printf '%s\n' \
  "crashtest" "$APPDATA" "$BK" \
  "1" "$STACK" "crashtest-app" "" \
  "y" "1" "$DB_APP" \
  "y" "2" "crashtest-postgres" "postgres" "postgres" "n" "testdb" \
  "y" "3" "crashtest-mariadb" "root" "rootpw" "n" "testdb" \
  "n" "" "" "" "$BACKUP_SCRIPT" | python3 "$GEN" >/dev/null 2>&1
[ -f "$BACKUP_SCRIPT" ] && pass "generator produced backup-crashtest.sh" || fail "generator did not produce the script"
if bash -n "$BACKUP_SCRIPT" 2>/dev/null; then pass "generated backup script has valid syntax"; else fail "generated backup script has a syntax error"; fi

# --------------------------------------------------------------------------- #
section "BACKUP  (run it; verify outputs, excludes, and restart)"
# --------------------------------------------------------------------------- #
if bash "$BACKUP_SCRIPT" >>"$LOG" 2>&1; then pass "backup script ran without error"; else fail "backup script exited non-zero (see $LOG)"; fi
D="$BK/crashtest"
[ -f "$D/restore-manifest.env" ] && pass "manifest written" || fail "manifest missing"
[ -f "$D/dumps/$(basename "$DB_APP").sqlite" ] && pass "sqlite dump present" || fail "sqlite dump missing"
[ -f "$D/dumps/pg-testdb.sql" ] && pass "postgres dump present" || fail "postgres dump missing"
if [ -f "$D/dumps/mysql-testdb.sql" ]; then pass "mariadb dump present"; else fail "mariadb dump missing -- likely 'mysqldump' absent in mariadb:11 (needs mariadb-dump)"; fi
[ -f "$D/appdata/config.yml" ] && pass "appdata config.yml backed up" || fail "appdata config.yml missing from backup"
[ -f "$D/appdata/data/notes.txt" ] && pass "appdata data/notes.txt backed up" || fail "appdata notes.txt missing from backup"
[ ! -e "$D/appdata/cache/tempfile.bin" ] && pass "exclude worked: cache/ not in backup" || fail "exclude FAILED: cache/ was backed up"
[ ! -e "$D/appdata/logs/app.log" ] && pass "exclude worked: logs/ not in backup" || fail "exclude FAILED: logs/ was backed up"
check "app restarted after backup" "$(app_running)" "true"

# --------------------------------------------------------------------------- #
section "RECOVER  (disaster -> restore everything -> data returns)"
# --------------------------------------------------------------------------- #
wreck_to "broken-B" 0
info "wrecked state: pg=$(pg_q 'select count(*) from widgets;') maria=$(maria_q 'select count(*) from widgets;') marker=$(sqlite_marker) notes=$(notes)"
run_restore "1" "yes"
check "recover: postgres rows restored" "$(pg_q 'select count(*) from widgets;')" "3"
check "recover: mariadb rows restored"  "$(maria_q 'select count(*) from widgets;')" "3"
check "recover: sqlite marker restored" "$(sqlite_marker)" "original-data-v1"
check "recover: notes file restored"    "$(notes)" "important user data v1 - original"
check "recover: app running after restore" "$(app_running)" "true"
if ls -d "$BK"/.safety-crashtest-* >/dev/null 2>&1; then fail "safety snapshot was left behind after a successful restore"; else pass "safety snapshot cleaned up after success"; fi
info "note: a full appdata restore uses rsync --delete, so regenerable excluded dirs (cache/, logs/) are removed on restore -- expected."

# --------------------------------------------------------------------------- #
section "ROLLBACK  (restore, report BROKEN -> undo to pre-restore state)"
# --------------------------------------------------------------------------- #
wreck_to "stateC" 1
info "pre-restore state: pg=$(pg_q 'select count(*) from widgets;') maria=$(maria_q 'select count(*) from widgets;') marker=$(sqlite_marker) notes=$(notes)"
run_restore "1" "no"   # restore brings back the 3-row backup, but we say it's broken
check "rollback: postgres back to pre-restore (1 row)" "$(pg_q 'select count(*) from widgets;')" "1"
check "rollback: mariadb back to pre-restore (1 row)"  "$(maria_q 'select count(*) from widgets;')" "1"
check "rollback: sqlite marker back to pre-restore"    "$(sqlite_marker)" "stateC"
check "rollback: notes back to pre-restore"            "$(notes)" "stateC"
check "rollback: app running afterward" "$(app_running)" "true"
if ls -d "$BK"/.safety-crashtest-* >/dev/null 2>&1; then fail "safety snapshot left behind after rollback"; else pass "safety snapshot cleaned up after rollback"; fi

# --------------------------------------------------------------------------- #
section "RESILIENCE  (missing/corrupt dump -> warn, don't crash)"
# --------------------------------------------------------------------------- #
mv "$D/dumps/pg-testdb.sql" "$D/dumps/pg-testdb.sql.hidden"
wreck_to "preMissing" 2
run_restore "3" "yes"   # databases-only restore with the postgres dump missing
if grep -qi "missing\|WARN" "$LOG"; then pass "restore warned about the missing postgres dump"; else fail "no warning emitted for missing dump"; fi
check "resilience: mariadb still restored despite pg dump missing" "$(maria_q 'select count(*) from widgets;')" "3"
check "resilience: postgres left untouched (still pre-restore 2 rows)" "$(pg_q 'select count(*) from widgets;')" "2"
mv "$D/dumps/pg-testdb.sql.hidden" "$D/dumps/pg-testdb.sql"

# --------------------------------------------------------------------------- #
section "CLEANUP  (restore everything to the clean backup state)"
# --------------------------------------------------------------------------- #
run_restore "1" "yes"
check "final: postgres clean" "$(pg_q 'select count(*) from widgets;')" "3"
check "final: mariadb clean"  "$(maria_q 'select count(*) from widgets;')" "3"
info "stack left running. To tear it down:  (cd $STACK && docker compose down -v)"

# --------------------------------------------------------------------------- #
printf "\n${B}==================== RESULTS ====================${N}\n"
printf "  ${G}PASS: %d${N}    ${R}FAIL: %d${N}\n" "$PASS" "$FAIL"
printf "  full command log: %s\n" "$LOG"
if [ "$FAIL" -eq 0 ]; then printf "  ${G}${B}All checks passed.${N}\n"; exit 0
else printf "  ${R}${B}Some checks failed -- see above.${N}\n"; exit 1; fi
