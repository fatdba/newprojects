#!/usr/bin/env bash
#
# ptosc_restartable_defrag.sh
#
# Restartable pt-online-schema-change wrapper for large InnoDB table rebuilds.
#
# Tested target design:
#   MySQL 8.0.x
#   Percona Toolkit pt-online-schema-change 3.7.1-4
#
# Key safety/restart properties:
#   * Fresh runs use --history, --no-drop-new-table, --no-drop-triggers,
#     and --no-drop-old-table.
#   * Re-running this same wrapper after a crash/reboot automatically resumes
#     the newest matching unfinished history job from its last completed chunk.
#   * If copying was already complete but cutover did not finish, the wrapper
#     verifies the history state + shadow table + all 3 sync triggers, then
#     performs the atomic RENAME with blocker handling.
#   * If cutover completed but cleanup was interrupted, the wrapper completes
#     trigger cleanup and ANALYZE.
#   * Metadata-lock watchdog kills ONLY sessions that MySQL reports as blocking
#     this ptosc_user's metadata-lock request on the target/shadow/old objects.
#   * Original table is retained after swap by default (AUTO_DROP_OLD=0).
#   * Busy-system defaults use higher Threads_running thresholds, but remain
#     environment-overridable.
#   * MDL blocker killing is restricted by user allow-list and wait duration.
#   * Post-cutover validation analyzes both copies (when retained), verifies
#     column/index definitions, history state, triggers, and PK range metadata.
#
# IMPORTANT:
#   This script will NOT automatically adopt or destroy an untracked shadow
#   table.  A partial table from an older non-history run must be cleaned up
#   manually before the first fresh run with this wrapper.
#
# Usage (auto mode - recommended):
#   nohup /root/defrag/tools/ptosc_restartable_defrag.sh IAVM position \
#     > /root/defrag/tools/IAVM.position.restartable.nohup.out 2>&1 &
#
# After an OS reboot/crash:
#   Run the exact same command again.  If a valid unfinished history job and
#   its shadow table + triggers remain, the wrapper resumes automatically.
#
# To force a brand-new run after a previous successful run:
#   MODE=fresh nohup ... IAVM position ...
#
# Default:
#   AUTO_DROP_OLD=0   -> retain the original as _<table>_old after swap.
#   AUTO_DROP_OLD=1   -> drop the old table only after successful cutover,
#                        trigger cleanup, and ANALYZE.
#

set -Eeuo pipefail
umask 077

###############################################################################
# Configuration
###############################################################################

SCHEMA="${1:-}"
TABLE="${2:-}"
MODE="${MODE:-auto}"                     # auto | fresh | resume

PTOSC="${PTOSC:-/root/defrag/tools/percona-toolkit-3.x/bin/pt-online-schema-change}"
CNF="${CNF:-/root/ptosc/ptosc.cnf}"
MYSQL="${MYSQL:-mysql}"
BASE_DIR="${BASE_DIR:-/root/ptosc}"

HISTORY_TABLE="${HISTORY_TABLE:-percona.pt_osc_history}"

ALTER_CLAUSE="${ALTER_CLAUSE:-ENGINE=InnoDB}"
CHUNK_INDEX="${CHUNK_INDEX:-PRIMARY}"
CHUNK_SIZE="${CHUNK_SIZE:-500}"
CHUNK_TIME="${CHUNK_TIME:-0.5}"
CHUNK_SIZE_LIMIT="${CHUNK_SIZE_LIMIT:-4}"

# Busy pre-production defaults. These remain environment-overridable.
# Threads_connected does NOT drive pt-osc throttling; Threads_running does.
MAX_LOAD="${MAX_LOAD:-Threads_running=80}"
CRITICAL_LOAD="${CRITICAL_LOAD:-Threads_running=160}"

# Keep lock waits short so pt-osc backs off instead of becoming a long blocker.
INNODB_LOCK_WAIT_TIMEOUT="${INNODB_LOCK_WAIT_TIMEOUT:-1}"
LOCK_WAIT_TIMEOUT="${LOCK_WAIT_TIMEOUT:-10}"

# More retry tolerance for transient contention on a busy pre-production host.
CREATE_TRIGGER_TRIES="${CREATE_TRIGGER_TRIES:-180}"
DROP_TRIGGER_TRIES="${DROP_TRIGGER_TRIES:-180}"
SWAP_TRIES="${SWAP_TRIES:-180}"
ANALYZE_TRIES="${ANALYZE_TRIES:-60}"
COPY_TRIES="${COPY_TRIES:-60}"
RETRY_WAIT="${RETRY_WAIT:-1}"

# Two-second polling is still responsive while reducing monitoring overhead.
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"
DDL_TRIES="${DDL_TRIES:-180}"

# PRE-PROD MDL safety. Only allow-listed users can be auto-killed, and only
# after they have blocked pt-osc for at least BLOCKER_KILL_AFTER_SECS.
# Default allow-list matches the backup blocker encountered in INTG.
KILL_MDL_BLOCKERS="${KILL_MDL_BLOCKERS:-1}"
KILL_BLOCKER_USERS="${KILL_BLOCKER_USERS:-backup}"
BLOCKER_KILL_AFTER_SECS="${BLOCKER_KILL_AFTER_SECS:-30}"

# Post-cutover validation.
ANALYZE_OLD_AFTER_SWAP="${ANALYZE_OLD_AFTER_SWAP:-1}"
STRICT_STRUCTURE_VALIDATION="${STRICT_STRUCTURE_VALIDATION:-1}"

# Retain original table after successful cutover by default.
AUTO_DROP_OLD="${AUTO_DROP_OLD:-0}"

# Hard emergency free-space floor.  This is not the expected shadow size.
MIN_FREE_GIB="${MIN_FREE_GIB:-500}"

###############################################################################
# Basic validation and deterministic names
###############################################################################

usage() {
    cat >&2 <<EOF
Usage:
  $0 <schema> <table>

Example:
  AUTO_DROP_OLD=0 nohup $0 IAVM position > /root/defrag/tools/IAVM.position.restartable.nohup.out 2>&1 &

Busy-server override example:
  MAX_LOAD=Threads_running=100 CRITICAL_LOAD=Threads_running=180 AUTO_DROP_OLD=0 \
    nohup $0 IAVM position > /root/defrag/tools/IAVM.position.restartable.nohup.out 2>&1 &

MODE values:
  auto   - resume a valid interrupted job; otherwise start fresh (default)
  fresh  - require a clean state and start a new history job
  resume - require a valid resumable history job
EOF
    exit 2
}

[[ -n "$SCHEMA" && -n "$TABLE" ]] || usage
[[ "$MODE" =~ ^(auto|fresh|resume)$ ]] || { echo "ERROR: MODE must be auto, fresh, or resume" >&2; exit 2; }

valid_ident() {
    [[ "$1" =~ ^[A-Za-z0-9_$]+$ ]]
}

valid_ident "$SCHEMA" || { echo "ERROR: invalid schema name: $SCHEMA" >&2; exit 2; }
valid_ident "$TABLE"  || { echo "ERROR: invalid table name: $TABLE" >&2; exit 2; }

HISTORY_DB="${HISTORY_TABLE%%.*}"
HISTORY_TBL="${HISTORY_TABLE#*.}"
[[ "$HISTORY_DB" != "$HISTORY_TABLE" ]] || { echo "ERROR: HISTORY_TABLE must be db.table" >&2; exit 2; }
valid_ident "$HISTORY_DB" || { echo "ERROR: invalid history DB: $HISTORY_DB" >&2; exit 2; }
valid_ident "$HISTORY_TBL" || { echo "ERROR: invalid history table: $HISTORY_TBL" >&2; exit 2; }

NEW_TABLE="_${TABLE}_new"
OLD_TABLE="_${TABLE}_old"

(( ${#NEW_TABLE} <= 64 )) || { echo "ERROR: generated new table name exceeds 64 chars" >&2; exit 2; }
(( ${#OLD_TABLE} <= 64 )) || { echo "ERROR: generated old table name exceeds 64 chars" >&2; exit 2; }

RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_ROOT="${BASE_DIR}/${SCHEMA}.${TABLE}"
RUN_DIR="${RUN_ROOT}/${RUN_ID}"

WRAPPER_LOG="${RUN_DIR}/wrapper.log"
PTOSC_LOG="${RUN_DIR}/pt-online-schema-change.log"
DRYRUN_LOG="${RUN_DIR}/dry-run.log"
KILL_LOG="${RUN_DIR}/killed-blockers.log"
BASELINE_LOG="${RUN_DIR}/baseline.txt"
FINAL_LOG="${RUN_DIR}/final-validation.txt"
PAUSE_FILE="${RUN_DIR}/pause.flag"
PTOSC_PID_FILE="${RUN_DIR}/ptosc.pid"
WATCHDOG_PID_FILE="${RUN_DIR}/watchdog.pid"
WATCHDOG_STOP="${RUN_DIR}/watchdog.stop"
SUCCESS_MARKER="${RUN_ROOT}/success.marker"

mkdir -p "$RUN_DIR" "$RUN_ROOT"
chmod 700 "$RUN_DIR" "$RUN_ROOT"
printf '%s\n' "$RUN_DIR" > "${RUN_ROOT}/current_run"

touch "$WRAPPER_LOG" "$PTOSC_LOG" "$DRYRUN_LOG" "$KILL_LOG"
chmod 600 "$WRAPPER_LOG" "$PTOSC_LOG" "$DRYRUN_LOG" "$KILL_LOG"

# One wrapper for this target at a time.
exec 9>"${RUN_ROOT}/wrapper.lock"
if ! flock -n 9; then
    echo "ERROR: another wrapper for ${SCHEMA}.${TABLE} is already running." >&2
    exit 2
fi

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$WRAPPER_LOG"
}

die() {
    log "ERROR: $*"
    exit 1
}

###############################################################################
# MySQL helpers
###############################################################################

mysql_q() {
    "$MYSQL" --defaults-file="$CNF" \
        --batch --skip-column-names --raw \
        -e "$1"
}

mysql_exec() {
    "$MYSQL" --defaults-file="$CNF" -e "$1"
}

table_exists() {
    local t="$1"
    [[ "$(mysql_q "
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME='${t}'
          AND TABLE_TYPE='BASE TABLE';
    " 2>/dev/null || echo 0)" == "1" ]]
}

target_trigger_count() {
    mysql_q "
        SELECT COUNT(*)
        FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA='${SCHEMA}'
          AND TRIGGER_NAME IN (
              'pt_osc_${SCHEMA}_${TABLE}_ins',
              'pt_osc_${SCHEMA}_${TABLE}_upd',
              'pt_osc_${SCHEMA}_${TABLE}_del'
          );
    " 2>/dev/null || echo 0
}

trigger_event_table() {
    mysql_q "
        SELECT COALESCE(GROUP_CONCAT(DISTINCT EVENT_OBJECT_TABLE ORDER BY EVENT_OBJECT_TABLE),'')
        FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA='${SCHEMA}'
          AND TRIGGER_NAME IN (
              'pt_osc_${SCHEMA}_${TABLE}_ins',
              'pt_osc_${SCHEMA}_${TABLE}_upd',
              'pt_osc_${SCHEMA}_${TABLE}_del'
          );
    " 2>/dev/null || true
}

history_table_exists() {
    [[ "$(mysql_q "
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='${HISTORY_DB}'
          AND TABLE_NAME='${HISTORY_TBL}'
          AND TABLE_TYPE='BASE TABLE';
    " 2>/dev/null || echo 0)" == "1" ]]
}

shadow_create_time() {
    mysql_q "
        SELECT COALESCE(DATE_FORMAT(CREATE_TIME,'%Y-%m-%d %H:%i:%s'),'1970-01-01 00:00:00')
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME='${NEW_TABLE}'
        LIMIT 1;
    " 2>/dev/null || true
}

latest_resumable_job() {
    local ct
    ct="$(shadow_create_time)"
    [[ -n "$ct" ]] || return 0

    mysql_q "
        SELECT job_id
        FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
        WHERE db='${SCHEMA}'
          AND tbl='${TABLE}'
          AND altr='${ALTER_CLAUSE}'
          AND new_table_name='${NEW_TABLE}'
          AND done='no'
          AND lower_boundary IS NOT NULL
          AND upper_boundary IS NOT NULL
          AND LENGTH(lower_boundary) > 0
          AND LENGTH(upper_boundary) > 0
          AND ts >= '${ct}'
        ORDER BY job_id DESC
        LIMIT 1;
    " 2>/dev/null || true
}

latest_copy_complete_job() {
    local ct
    ct="$(shadow_create_time)"
    [[ -n "$ct" ]] || return 0

    mysql_q "
        SELECT job_id
        FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
        WHERE db='${SCHEMA}'
          AND tbl='${TABLE}'
          AND altr='${ALTER_CLAUSE}'
          AND new_table_name='${NEW_TABLE}'
          AND done='yes'
          AND ts >= '${ct}'
        ORDER BY job_id DESC
        LIMIT 1;
    " 2>/dev/null || true
}

latest_history_job() {
    mysql_q "
        SELECT job_id
        FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
        WHERE db='${SCHEMA}'
          AND tbl='${TABLE}'
          AND altr='${ALTER_CLAUSE}'
        ORDER BY job_id DESC
        LIMIT 1;
    " 2>/dev/null || true
}

###############################################################################
# Busy-system safety helpers
###############################################################################

blocker_user_allowed() {
    local u="$1"
    local list=",${KILL_BLOCKER_USERS// /},"
    [[ "$KILL_BLOCKER_USERS" == "*" || "$list" == *",${u},"* ]]
}

status_value() {
    local name="$1"
    mysql_q "
        SELECT VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME='${name}'
        LIMIT 1;
    " 2>/dev/null || true
}

###############################################################################
# Preconditions
###############################################################################

log "============================================================"
log "Restartable pt-osc automation for ${SCHEMA}.${TABLE}"
log "mode=${MODE}; run=${RUN_DIR}"
log "============================================================"

[[ -x "$PTOSC" ]] || die "pt-online-schema-change not executable: $PTOSC"
[[ -r "$CNF" ]] || die "MySQL defaults file not readable: $CNF"
command -v "$MYSQL" >/dev/null 2>&1 || die "mysql client not found"
command -v flock >/dev/null 2>&1 || die "flock not found"
command -v numfmt >/dev/null 2>&1 || die "numfmt not found"

# --history requires Perl JSON.
perl -MJSON -e 'exit 0' >/dev/null 2>&1 \
    || die "Perl JSON module is required by pt-osc --history (RHEL/OEL package: perl-JSON)."

mysql_q "SELECT 1;" >/dev/null || die "Cannot connect using $CNF"

[[ "$KILL_MDL_BLOCKERS" =~ ^[01]$ ]] \
    || die "KILL_MDL_BLOCKERS must be 0 or 1."
[[ "$BLOCKER_KILL_AFTER_SECS" =~ ^[0-9]+$ ]] \
    || die "BLOCKER_KILL_AFTER_SECS must be a non-negative integer."
[[ "$ANALYZE_OLD_AFTER_SWAP" =~ ^[01]$ ]] \
    || die "ANALYZE_OLD_AFTER_SWAP must be 0 or 1."
[[ "$STRICT_STRUCTURE_VALIDATION" =~ ^[01]$ ]] \
    || die "STRICT_STRUCTURE_VALIDATION must be 0 or 1."
[[ "$AUTO_DROP_OLD" =~ ^[01]$ ]] \
    || die "AUTO_DROP_OLD must be 0 or 1."

MYSQL_VERSION="$(mysql_q "SELECT @@version;")"
CURRENT_ACCOUNT="$(mysql_q "SELECT CURRENT_USER();")"
PTOSC_USER="${CURRENT_ACCOUNT%@*}"

log "MySQL=${MYSQL_VERSION}; account=${CURRENT_ACCOUNT}; tool=$("$PTOSC" --version 2>&1 | head -1)"

# Validate configured load thresholds and capture a pre-run workload snapshot.
MAX_LOAD_VALUE=""
CRITICAL_LOAD_VALUE=""
if [[ "$MAX_LOAD" =~ ^Threads_running=([0-9]+)$ ]]; then
    MAX_LOAD_VALUE="${BASH_REMATCH[1]}"
fi
if [[ "$CRITICAL_LOAD" =~ ^Threads_running=([0-9]+)$ ]]; then
    CRITICAL_LOAD_VALUE="${BASH_REMATCH[1]}"
fi

if [[ -n "$MAX_LOAD_VALUE" && -n "$CRITICAL_LOAD_VALUE" ]]; then
    (( CRITICAL_LOAD_VALUE > MAX_LOAD_VALUE )) \
        || die "CRITICAL_LOAD (${CRITICAL_LOAD_VALUE}) must be greater than MAX_LOAD (${MAX_LOAD_VALUE})."
fi

CURRENT_THREADS_RUNNING="$(status_value Threads_running)"
CURRENT_THREADS_CONNECTED="$(status_value Threads_connected)"
MAX_CONNECTIONS="$(mysql_q "SELECT @@GLOBAL.max_connections;" 2>/dev/null || true)"
log "Load snapshot: Threads_running=${CURRENT_THREADS_RUNNING:-unknown}; Threads_connected=${CURRENT_THREADS_CONNECTED:-unknown}; max_connections=${MAX_CONNECTIONS:-unknown}; max-load=${MAX_LOAD}; critical-load=${CRITICAL_LOAD}"

if [[ "$CURRENT_THREADS_RUNNING" =~ ^[0-9]+$ && "$CRITICAL_LOAD_VALUE" =~ ^[0-9]+$ ]]; then
    (( CURRENT_THREADS_RUNNING < CRITICAL_LOAD_VALUE )) \
        || die "Current Threads_running=${CURRENT_THREADS_RUNNING} is already at/above critical threshold ${CRITICAL_LOAD_VALUE}; refusing to start."
fi
if [[ "$CURRENT_THREADS_RUNNING" =~ ^[0-9]+$ && "$MAX_LOAD_VALUE" =~ ^[0-9]+$ ]] \
   && (( CURRENT_THREADS_RUNNING > MAX_LOAD_VALUE )); then
    log "WARNING: current Threads_running=${CURRENT_THREADS_RUNNING} is above max-load ${MAX_LOAD_VALUE}; pt-osc may initially pause until load drops."
fi

# Watchdog dependency.
mysql_q "SELECT COUNT(*) FROM sys.schema_table_lock_waits;" >/dev/null \
    || die "Cannot read sys.schema_table_lock_waits"

# KILL privilege is required only when automatic MDL blocker termination is enabled.
if [[ "$KILL_MDL_BLOCKERS" == "1" ]]; then
    GRANTS="$("$MYSQL" --defaults-file="$CNF" -Nse "SHOW GRANTS FOR CURRENT_USER();" 2>/dev/null || true)"
    grep -Eqi 'CONNECTION_ADMIN|SUPER|ALL PRIVILEGES' <<<"$GRANTS" \
        || die "KILL_MDL_BLOCKERS=1 requires CONNECTION_ADMIN (or SUPER)."
fi

# History table is intentionally pre-created by DBA/root so ptosc_user does not
# need CREATE DATABASE globally.
history_table_exists || die "History table ${HISTORY_TABLE} does not exist. Create it with the one-time setup SQL before running."

# Verify exact required history columns exist.
HIST_COLS="$(mysql_q "
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='${HISTORY_DB}'
      AND TABLE_NAME='${HISTORY_TBL}'
      AND COLUMN_NAME IN
          ('job_id','db','tbl','new_table_name','altr','args',
           'lower_boundary','upper_boundary','done','ts');
")"
[[ "$HIST_COLS" == "10" ]] || die "History table ${HISTORY_TABLE} does not have the required pt-osc structure."

# Verify history read/write without mutating it.
mysql_q "
    SELECT COUNT(*)
    FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
    WHERE 1=0;
" >/dev/null || die "Cannot SELECT from ${HISTORY_TABLE}"

# Original must exist for fresh/resume/cutover recovery.
table_exists "$TABLE" || die "Original/active table ${SCHEMA}.${TABLE} does not exist."

ENGINE="$(mysql_q "
    SELECT ENGINE
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA='${SCHEMA}' AND TABLE_NAME='${TABLE}';
")"
[[ "$ENGINE" == "InnoDB" ]] || die "Target engine is ${ENGINE}; expected InnoDB."

PK_COLS="$(mysql_q "
    SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA='${SCHEMA}'
      AND TABLE_NAME='${TABLE}'
      AND INDEX_NAME='PRIMARY';
")"
[[ -n "$PK_COLS" ]] || die "PRIMARY KEY is required because --chunk-index=PRIMARY is used."
log "PRIMARY KEY columns=${PK_COLS}"

# Avoid automatic rename recovery on FK tables.
FK_COUNT="$(mysql_q "
    SELECT COUNT(*)
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE
       (
         TABLE_SCHEMA='${SCHEMA}'
         AND TABLE_NAME='${TABLE}'
         AND REFERENCED_TABLE_NAME IS NOT NULL
       )
       OR
       (
         REFERENCED_TABLE_SCHEMA='${SCHEMA}'
         AND REFERENCED_TABLE_NAME='${TABLE}'
       );
")"
(( FK_COUNT == 0 )) || die "Foreign keys reference/from ${SCHEMA}.${TABLE}; this automation intentionally refuses FK tables."

# Do not run beside another pt-osc targeting this table.
if pgrep -af pt-online-schema-change 2>/dev/null \
    | grep -F "D=${SCHEMA},t=${TABLE}" >/dev/null 2>&1; then
    pgrep -af pt-online-schema-change | grep -F "D=${SCHEMA},t=${TABLE}" | tee -a "$WRAPPER_LOG"
    die "Another pt-online-schema-change is already targeting ${SCHEMA}.${TABLE}."
fi

FREE_BYTES="$(df -B1 --output=avail /var/lib/mysql | tail -1 | tr -d ' ')"
MIN_FREE_BYTES=$(( MIN_FREE_GIB * 1024 * 1024 * 1024 ))
(( FREE_BYTES >= MIN_FREE_BYTES )) \
    || die "Only $(numfmt --to=iec-i "$FREE_BYTES") free on /var/lib/mysql; hard floor=${MIN_FREE_GIB} GiB."
log "Data filesystem free=$(numfmt --to=iec-i "$FREE_BYTES")"

{
    echo "=== $(date '+%F %T') BASELINE ==="
    df -h /var/lib/mysql
    df -h /var/lib/mysql-binlog 2>/dev/null || true
    echo
    "$MYSQL" --defaults-file="$CNF" -e "
        SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE,TABLE_ROWS,AUTO_INCREMENT,
               ROUND(DATA_LENGTH/1024/1024/1024/1024,3) AS DATA_TIB,
               ROUND(INDEX_LENGTH/1024/1024/1024/1024,3) AS INDEX_TIB,
               ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024/1024/1024,3) AS TOTAL_TIB
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME IN ('${TABLE}','${NEW_TABLE}','${OLD_TABLE}');

        SELECT job_id,db,tbl,new_table_name,done,ts,
               LEFT(lower_boundary,200) AS lower_boundary,
               LEFT(upper_boundary,200) AS upper_boundary
        FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
        WHERE db='${SCHEMA}' AND tbl='${TABLE}'
        ORDER BY job_id DESC LIMIT 10;
    " 2>&1
} > "$BASELINE_LOG"

###############################################################################
# Metadata-lock blocker watchdog
###############################################################################

kill_confirmed_blockers_once() {
    local rows pid blocker_user wait_secs details skip_tag

    rows="$(mysql_q "
        SELECT DISTINCT
               blocking_pid,
               SUBSTRING_INDEX(blocking_account,'@',1) AS blocking_user,
               COALESCE(waiting_query_secs,0)
        FROM sys.schema_table_lock_waits
        WHERE object_schema='${SCHEMA}'
          AND object_name IN ('${TABLE}','${NEW_TABLE}','${OLD_TABLE}')
          AND blocking_pid IS NOT NULL
          AND SUBSTRING_INDEX(waiting_account,'@',1)='${PTOSC_USER}';
    " 2>/dev/null || true)"

    [[ -n "$rows" ]] || return 0

    while IFS=$'\t' read -r pid blocker_user wait_secs; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$wait_secs" =~ ^[0-9]+$ ]] || wait_secs=0

        # Let short-lived production-like transactions clear naturally.
        (( wait_secs >= BLOCKER_KILL_AFTER_SECS )) || continue

        details="$(mysql_q "
            SELECT CONCAT_WS(' | ',
                PROCESSLIST_ID,
                COALESCE(PROCESSLIST_USER,''),
                COALESCE(PROCESSLIST_HOST,''),
                COALESCE(PROCESSLIST_TIME,0),
                COALESCE(PROCESSLIST_STATE,''),
                REPLACE(REPLACE(COALESCE(LEFT(PROCESSLIST_INFO,500),''),CHAR(10),' '),CHAR(13),' ')
            )
            FROM performance_schema.threads
            WHERE PROCESSLIST_ID=${pid};
        " 2>/dev/null || true)"

        [[ -n "$details" ]] || continue
        skip_tag="SKIPPED blocker pid=${pid}"

        if [[ "$KILL_MDL_BLOCKERS" != "1" ]]; then
            if ! grep -Fq "$skip_tag" "$KILL_LOG" 2>/dev/null; then
                log "BLOCKER DETECTED but auto-kill disabled: ${details}"
                printf '%s %s reason=auto-kill-disabled user=%s wait_secs=%s | %s\n' \
                    "$(date '+%F %T')" "$skip_tag" "$blocker_user" "$wait_secs" "$details" >> "$KILL_LOG"
            fi
            continue
        fi

        if ! blocker_user_allowed "$blocker_user"; then
            if ! grep -Fq "$skip_tag" "$KILL_LOG" 2>/dev/null; then
                log "BLOCKER DETECTED but user '${blocker_user}' is not in KILL_BLOCKER_USERS='${KILL_BLOCKER_USERS}': ${details}"
                printf '%s %s reason=user-not-allowlisted user=%s wait_secs=%s | %s\n' \
                    "$(date '+%F %T')" "$skip_tag" "$blocker_user" "$wait_secs" "$details" >> "$KILL_LOG"
            fi
            continue
        fi

        log "BLOCKER APPROVED FOR KILL after ${wait_secs}s: ${details}"
        printf '%s BLOCKER user=%s wait_secs=%s | %s\n' \
            "$(date '+%F %T')" "$blocker_user" "$wait_secs" "$details" >> "$KILL_LOG"

        if mysql_exec "KILL CONNECTION ${pid};" >>"$KILL_LOG" 2>&1; then
            log "KILLED allow-listed blocking connection ${pid} (${blocker_user})"
            printf '%s KILLED pid=%s user=%s\n' "$(date '+%F %T')" "$pid" "$blocker_user" >> "$KILL_LOG"
        else
            log "WARNING: could not kill blocker ${pid}; will retry while the wait still exists"
        fi
    done <<<"$rows"
}

watchdog() {
    log "Metadata-lock watchdog started (poll=${WATCH_INTERVAL}s)"
    while [[ ! -f "$WATCHDOG_STOP" ]]; do
        kill_confirmed_blockers_once || true
        sleep "$WATCH_INTERVAL"
    done
    log "Metadata-lock watchdog stopped"
}

WATCHDOG_PID=""
start_watchdog() {
    rm -f "$WATCHDOG_STOP"
    watchdog &
    WATCHDOG_PID=$!
    printf '%s\n' "$WATCHDOG_PID" > "$WATCHDOG_PID_FILE"
}

stop_watchdog() {
    touch "$WATCHDOG_STOP" 2>/dev/null || true
    if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
}

cleanup_exit() {
    local rc=$?
    stop_watchdog
    if (( rc != 0 )); then
        log "FAILED rc=${rc}; no blind table/trigger cleanup performed."
        log "Inspect ${RUN_DIR} and ${HISTORY_TABLE}."
    fi
}
trap cleanup_exit EXIT INT TERM

###############################################################################
# State detection
###############################################################################

TARGET_EXISTS=0
NEW_EXISTS=0
OLD_EXISTS=0
table_exists "$TABLE" && TARGET_EXISTS=1
table_exists "$NEW_TABLE" && NEW_EXISTS=1
table_exists "$OLD_TABLE" && OLD_EXISTS=1

TRIG_COUNT="$(target_trigger_count)"
TRIG_TABLES="$(trigger_event_table)"
RESUME_JOB=""
DONE_JOB=""

if (( NEW_EXISTS == 1 )); then
    RESUME_JOB="$(latest_resumable_job)"
    DONE_JOB="$(latest_copy_complete_job)"
fi

log "STATE target=${TARGET_EXISTS} new=${NEW_EXISTS} old=${OLD_EXISTS} triggers=${TRIG_COUNT} trigger_tables=${TRIG_TABLES:-none} resumable_job=${RESUME_JOB:-none} copy_done_job=${DONE_JOB:-none}"

ACTION=""

# Completed wrapper marker from a previous successful invocation.
# In auto mode, never start another rebuild merely because the old table was
# later dropped.  A new intentional rebuild requires MODE=fresh.
if [[ "$MODE" == "auto" && -f "$SUCCESS_MARKER" && $TARGET_EXISTS -eq 1 && $NEW_EXISTS -eq 0 && $TRIG_COUNT -eq 0 ]]; then
    log "Previous successful run marker exists."
    log "Nothing to resume. A new intentional rebuild requires MODE=fresh."
    exit 0
fi

if [[ "$MODE" == "fresh" ]]; then
    (( TARGET_EXISTS == 1 && NEW_EXISTS == 0 && OLD_EXISTS == 0 && TRIG_COUNT == 0 )) \
        || die "MODE=fresh requires only ${SCHEMA}.${TABLE}; no shadow, old table, or pt-osc triggers may exist."
    ACTION="fresh"

elif [[ "$MODE" == "resume" ]]; then
    (( TARGET_EXISTS == 1 && NEW_EXISTS == 1 && OLD_EXISTS == 0 && TRIG_COUNT == 3 )) \
        || die "MODE=resume requires original + shadow + exactly 3 pt-osc triggers and no old table."
    [[ -n "$RESUME_JOB" ]] || die "No valid unfinished history job with saved boundaries exists for this shadow table."
    ACTION="resume"

else
    # MODE=auto
    if (( TARGET_EXISTS == 1 && NEW_EXISTS == 0 && OLD_EXISTS == 0 && TRIG_COUNT == 0 )); then
        ACTION="fresh"

    elif (( TARGET_EXISTS == 1 && NEW_EXISTS == 1 && OLD_EXISTS == 0 && TRIG_COUNT == 3 )); then
        if [[ -n "$RESUME_JOB" ]]; then
            ACTION="resume"
        elif [[ -n "$DONE_JOB" ]]; then
            ACTION="recover_swap"
        else
            die "Shadow + triggers exist but no matching resumable/completed history job exists. This is an untracked or inconsistent partial run; manual review/cleanup is required."
        fi

    elif (( TARGET_EXISTS == 1 && NEW_EXISTS == 0 && OLD_EXISTS == 1 )); then
        ACTION="post_swap_cleanup"

    else
        die "Unexpected object state. Refusing automatic DROP/RENAME."
    fi
fi

log "Selected action=${ACTION}"

###############################################################################
# DDL retry helper
###############################################################################

run_ddl_retry() {
    local label="$1"
    local sql="$2"
    local i

    for ((i=1; i<=DDL_TRIES; i++)); do
        if mysql_exec "
            SET SESSION lock_wait_timeout=${LOCK_WAIT_TIMEOUT};
            ${sql}
        " >>"$WRAPPER_LOG" 2>&1; then
            log "${label}: success on attempt ${i}"
            return 0
        fi

        log "${label}: attempt ${i}/${DDL_TRIES} failed; checking confirmed blocker and retrying"
        kill_confirmed_blockers_once || true
        sleep "$RETRY_WAIT"
    done

    log "ERROR: ${label} failed after ${DDL_TRIES} attempts"
    return 1
}

drop_ptosc_triggers() {
    run_ddl_retry "Drop DELETE trigger" \
        "DROP TRIGGER IF EXISTS \`${SCHEMA}\`.\`pt_osc_${SCHEMA}_${TABLE}_del\`;" || return 1
    run_ddl_retry "Drop UPDATE trigger" \
        "DROP TRIGGER IF EXISTS \`${SCHEMA}\`.\`pt_osc_${SCHEMA}_${TABLE}_upd\`;" || return 1
    run_ddl_retry "Drop INSERT trigger" \
        "DROP TRIGGER IF EXISTS \`${SCHEMA}\`.\`pt_osc_${SCHEMA}_${TABLE}_ins\`;" || return 1
}

###############################################################################
# pt-osc common arguments
###############################################################################

COMMON_ARGS=(
    --defaults-file="$CNF"
    --alter="$ALTER_CLAUSE"
    --chunk-index="$CHUNK_INDEX"
    --chunk-size="$CHUNK_SIZE"
    --chunk-time="$CHUNK_TIME"
    --chunk-size-limit="$CHUNK_SIZE_LIMIT"
    --recursion-method=none
    --max-load="$MAX_LOAD"
    --critical-load="$CRITICAL_LOAD"
    --set-vars="innodb_lock_wait_timeout=${INNODB_LOCK_WAIT_TIMEOUT},lock_wait_timeout=${LOCK_WAIT_TIMEOUT}"
    --tries="create_triggers:${CREATE_TRIGGER_TRIES}:${RETRY_WAIT},drop_triggers:${DROP_TRIGGER_TRIES}:${RETRY_WAIT},copy_rows:${COPY_TRIES}:${RETRY_WAIT},swap_tables:${SWAP_TRIES}:${RETRY_WAIT},analyze_table:${ANALYZE_TRIES}:${RETRY_WAIT}"
    --analyze-before-swap
    --progress="time,30"
    --statistics
    --print
    --no-buffer-stdout
    --pause-file="$PAUSE_FILE"
    --pid="$PTOSC_PID_FILE"
    --no-version-check

    # Required for supported restart/resume behavior.
    --history
    --history-table="$HISTORY_TABLE"
    --no-drop-new-table
    --no-drop-triggers
    --no-drop-old-table
)

###############################################################################
# Fresh start
###############################################################################

if [[ "$ACTION" == "fresh" ]]; then
    rm -f "$SUCCESS_MARKER"

    log "Running dry run before fresh restartable job."

    if ! "$PTOSC" \
        --defaults-file="$CNF" \
        --alter="$ALTER_CLAUSE" \
        --new-table-name="$NEW_TABLE" \
        --chunk-index="$CHUNK_INDEX" \
        --chunk-size="$CHUNK_SIZE" \
        --chunk-time="$CHUNK_TIME" \
        --chunk-size-limit="$CHUNK_SIZE_LIMIT" \
        --recursion-method=none \
        --max-load="$MAX_LOAD" \
        --critical-load="$CRITICAL_LOAD" \
        --set-vars="innodb_lock_wait_timeout=${INNODB_LOCK_WAIT_TIMEOUT},lock_wait_timeout=${LOCK_WAIT_TIMEOUT}" \
        --analyze-before-swap \
        --print \
        --no-version-check \
        --dry-run \
        "D=${SCHEMA},t=${TABLE}" \
        >"$DRYRUN_LOG" 2>&1
    then
        die "Dry run failed. Review ${DRYRUN_LOG}"
    fi

    table_exists "$NEW_TABLE" && die "Dry run unexpectedly left ${SCHEMA}.${NEW_TABLE} behind."
    log "Dry run OK."

    start_watchdog
    log "Starting FRESH restartable pt-osc job."

    set +e
    "$PTOSC" \
        "${COMMON_ARGS[@]}" \
        --new-table-name="$NEW_TABLE" \
        --execute \
        "D=${SCHEMA},t=${TABLE}" \
        >"$PTOSC_LOG" 2>&1
    PTOSC_RC=$?
    set -e

    log "Fresh pt-osc process exited rc=${PTOSC_RC}"

###############################################################################
# Resume
###############################################################################

elif [[ "$ACTION" == "resume" ]]; then
    log "Resuming Percona history job_id=${RESUME_JOB} from its last completed chunk."
    log "Existing shadow=${SCHEMA}.${NEW_TABLE}; existing triggers=${TRIG_COUNT}"

    start_watchdog

    set +e
    "$PTOSC" \
        "${COMMON_ARGS[@]}" \
        --resume="$RESUME_JOB" \
        --execute \
        "D=${SCHEMA},t=${TABLE}" \
        >"$PTOSC_LOG" 2>&1
    PTOSC_RC=$?
    set -e

    log "Resumed pt-osc process exited rc=${PTOSC_RC}"

###############################################################################
# Already copy-complete or post-swap after a reboot
###############################################################################

elif [[ "$ACTION" == "recover_swap" ]]; then
    PTOSC_RC=99
    log "History job_id=${DONE_JOB} says row copy completed, but shadow is still unswapped."
    start_watchdog

elif [[ "$ACTION" == "post_swap_cleanup" ]]; then
    PTOSC_RC=0
    log "Detected already-swapped state; proceeding with safe cleanup/validation."
    start_watchdog
fi

###############################################################################
# Re-inspect state after pt-osc (or immediately for recovery)
###############################################################################

TARGET_EXISTS=0
NEW_EXISTS=0
OLD_EXISTS=0
table_exists "$TABLE" && TARGET_EXISTS=1
table_exists "$NEW_TABLE" && NEW_EXISTS=1
table_exists "$OLD_TABLE" && OLD_EXISTS=1

TRIG_COUNT="$(target_trigger_count)"
TRIG_TABLES="$(trigger_event_table)"

if (( NEW_EXISTS == 1 )); then
    RESUME_JOB="$(latest_resumable_job)"
    DONE_JOB="$(latest_copy_complete_job)"
else
    RESUME_JOB=""
    DONE_JOB=""
fi

log "POST-PTOSC STATE target=${TARGET_EXISTS} new=${NEW_EXISTS} old=${OLD_EXISTS} triggers=${TRIG_COUNT} trigger_tables=${TRIG_TABLES:-none} resumable_job=${RESUME_JOB:-none} copy_done_job=${DONE_JOB:-none}"

###############################################################################
# State machine after execution
###############################################################################

# Case 1: Normal pt-osc swap completed (or a reboot occurred after swap).
if (( TARGET_EXISTS == 1 && NEW_EXISTS == 0 && OLD_EXISTS == 1 )); then
    log "Cutover is complete: active=${SCHEMA}.${TABLE}, retained original=${SCHEMA}.${OLD_TABLE}"

# Case 2: Copy completed but swap did not complete.
elif (( TARGET_EXISTS == 1 && NEW_EXISTS == 1 && OLD_EXISTS == 0 && TRIG_COUNT == 3 )) && [[ -n "$DONE_JOB" ]]; then
    log "Verified copy-complete / unswapped state using history job_id=${DONE_JOB}."
    log "All 3 synchronization triggers still exist; attempting atomic recovery swap."

    run_ddl_retry "Atomic table swap" "
        RENAME TABLE
            \`${SCHEMA}\`.\`${TABLE}\` TO \`${SCHEMA}\`.\`${OLD_TABLE}\`,
            \`${SCHEMA}\`.\`${NEW_TABLE}\` TO \`${SCHEMA}\`.\`${TABLE}\`;
    " || die "Copy completed, but atomic recovery swap could not be completed."

    TARGET_EXISTS=0
    NEW_EXISTS=0
    OLD_EXISTS=0
    table_exists "$TABLE" && TARGET_EXISTS=1
    table_exists "$NEW_TABLE" && NEW_EXISTS=1
    table_exists "$OLD_TABLE" && OLD_EXISTS=1

    (( TARGET_EXISTS == 1 && NEW_EXISTS == 0 && OLD_EXISTS == 1 )) \
        || die "Unexpected state after recovery RENAME."

    log "Atomic recovery swap succeeded."

# Case 3: Copy is incomplete but safely resumable.
elif (( TARGET_EXISTS == 1 && NEW_EXISTS == 1 && OLD_EXISTS == 0 && TRIG_COUNT == 3 )) && [[ -n "$RESUME_JOB" ]]; then
    log "Copy remains incomplete but is safely resumable."
    log "Resume job_id=${RESUME_JOB}"
    log "DO NOT DROP ${SCHEMA}.${NEW_TABLE} or the pt-osc triggers."
    log "Re-run this same wrapper after correcting the interruption/reboot condition."
    stop_watchdog
    trap - EXIT INT TERM
    exit 75

else
    die "Unexpected/inconsistent post-run state. No blind cleanup performed."
fi

###############################################################################
# Post-cutover validation helpers
###############################################################################

column_signature() {
    local t="$1"
    mysql_q "
        SET SESSION group_concat_max_len=1048576;
        SELECT SHA2(
            GROUP_CONCAT(
                CONCAT_WS('|',
                    ORDINAL_POSITION,
                    COLUMN_NAME,
                    COLUMN_TYPE,
                    IS_NULLABLE,
                    COALESCE(COLUMN_DEFAULT,'<NULL>'),
                    EXTRA,
                    COALESCE(COLLATION_NAME,''),
                    COALESCE(GENERATION_EXPRESSION,'')
                )
                ORDER BY ORDINAL_POSITION
                SEPARATOR '\n'
            ),256
        )
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME='${t}';
    " 2>/dev/null || true
}

index_signature() {
    local t="$1"
    mysql_q "
        SET SESSION group_concat_max_len=1048576;
        SELECT SHA2(
            GROUP_CONCAT(
                CONCAT_WS('|',
                    INDEX_NAME,
                    NON_UNIQUE,
                    SEQ_IN_INDEX,
                    COALESCE(COLUMN_NAME,''),
                    COALESCE(SUB_PART,''),
                    COALESCE(COLLATION,''),
                    INDEX_TYPE,
                    COALESCE(EXPRESSION,''),
                    COALESCE(IS_VISIBLE,'YES')
                )
                ORDER BY INDEX_NAME,SEQ_IN_INDEX
                SEPARATOR '\n'
            ),256
        )
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME='${t}';
    " 2>/dev/null || true
}

pk_range_json() {
    local t="$1"
    local pk="$2"
    mysql_q "
        SELECT JSON_ARRAY(MIN(\`${pk}\`),MAX(\`${pk}\`))
        FROM \`${SCHEMA}\`.\`${t}\`;
    " 2>/dev/null || true
}

run_post_cutover_validation() {
    local active_col_sig old_col_sig active_idx_sig old_idx_sig
    local first_pk active_range old_range hist_done

    log "Running post-cutover validation gate."

    table_exists "$TABLE" || die "Post-cutover validation: active table is missing."
    if table_exists "$NEW_TABLE"; then
        die "Post-cutover validation: shadow table ${SCHEMA}.${NEW_TABLE} still exists."
    fi

    REMAINING_TRIGGERS="$(target_trigger_count)"
    (( REMAINING_TRIGGERS == 0 )) \
        || die "Post-cutover validation: ${REMAINING_TRIGGERS} pt-osc trigger(s) still remain."

    hist_done="$(mysql_q "
        SELECT done
        FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
        WHERE db='${SCHEMA}'
          AND tbl='${TABLE}'
          AND altr='${ALTER_CLAUSE}'
        ORDER BY job_id DESC
        LIMIT 1;
    " 2>/dev/null || true)"
    [[ "$hist_done" == "yes" ]] \
        || die "Post-cutover validation: latest history job is not done=yes (value='${hist_done:-missing}')."

    if table_exists "$OLD_TABLE"; then
        active_col_sig="$(column_signature "$TABLE")"
        old_col_sig="$(column_signature "$OLD_TABLE")"
        active_idx_sig="$(index_signature "$TABLE")"
        old_idx_sig="$(index_signature "$OLD_TABLE")"

        log "Validation signatures: columns active=${active_col_sig:-missing} old=${old_col_sig:-missing}; indexes active=${active_idx_sig:-missing} old=${old_idx_sig:-missing}"

        if [[ "$STRICT_STRUCTURE_VALIDATION" == "1" ]]; then
            [[ -n "$active_col_sig" && "$active_col_sig" == "$old_col_sig" ]] \
                || die "Post-cutover validation: column definitions differ between active and retained old table. Old table will NOT be dropped."
            [[ -n "$active_idx_sig" && "$active_idx_sig" == "$old_idx_sig" ]] \
                || die "Post-cutover validation: index definitions differ between active and retained old table. Old table will NOT be dropped."
        fi

        # Informational only: application DML can legitimately change range
        # immediately after the atomic cutover, so this must not be a hard gate.
        first_pk="$(mysql_q "
            SELECT COLUMN_NAME
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA='${SCHEMA}'
              AND TABLE_NAME='${TABLE}'
              AND INDEX_NAME='PRIMARY'
              AND SEQ_IN_INDEX=1
            LIMIT 1;
        " 2>/dev/null || true)"

        if [[ -n "$first_pk" ]]; then
            active_range="$(pk_range_json "$TABLE" "$first_pk")"
            old_range="$(pk_range_json "$OLD_TABLE" "$first_pk")"
            log "Leading-PK range (${first_pk}): active=${active_range:-unknown}; old=${old_range:-unknown}"
            if [[ -n "$active_range" && -n "$old_range" && "$active_range" != "$old_range" ]]; then
                log "WARNING: leading-PK range differs; post-cutover DML can legitimately cause this."
            fi
        fi
    fi

    log "Post-cutover validation gate PASSED."
}

###############################################################################
# Successful cutover cleanup
###############################################################################

# After successful rename, synchronization triggers live on the retained old
# table and are no longer needed. Drop them by exact schema-level trigger name.
TRIG_COUNT="$(target_trigger_count)"
if (( TRIG_COUNT > 0 )); then
    log "Removing ${TRIG_COUNT} retained pt-osc synchronization trigger(s) after successful cutover."
    drop_ptosc_triggers || die "Cutover succeeded but pt-osc trigger cleanup failed."
fi

REMAINING_TRIGGERS="$(target_trigger_count)"
(( REMAINING_TRIGGERS == 0 )) || die "pt-osc synchronization triggers still remain after cleanup."

# Refresh optimizer statistics on the active rebuilt table after cutover.
run_ddl_retry "ANALYZE active table" \
    "ANALYZE TABLE \`${SCHEMA}\`.\`${TABLE}\`;" \
    || die "ANALYZE TABLE failed on active table after successful cutover."

# Refresh retained-old statistics too. This avoids stale TABLE_ROWS/size
# estimates during validation, which was observed in INTG.
if table_exists "$OLD_TABLE" && [[ "$ANALYZE_OLD_AFTER_SWAP" == "1" ]]; then
    run_ddl_retry "ANALYZE retained old table" \
        "ANALYZE TABLE \`${SCHEMA}\`.\`${OLD_TABLE}\`;" \
        || die "ANALYZE TABLE failed on retained old table. Old table will NOT be dropped."
fi

# Validation gate runs before any automatic DROP of the retained original.
run_post_cutover_validation

if table_exists "$OLD_TABLE"; then
    if [[ "$AUTO_DROP_OLD" == "1" ]]; then
        log "AUTO_DROP_OLD=1: validation passed; dropping retained original ${SCHEMA}.${OLD_TABLE}."
        run_ddl_retry "Drop retained original table" \
            "DROP TABLE \`${SCHEMA}\`.\`${OLD_TABLE}\`;" \
            || die "Cutover/validation succeeded but dropping old table failed."
    else
        log "AUTO_DROP_OLD=0: retaining original as ${SCHEMA}.${OLD_TABLE} for manual/application validation."
    fi
fi

###############################################################################
# Final report
###############################################################################

{
    echo "=== $(date '+%F %T') FINAL ==="
    df -h /var/lib/mysql
    df -h /var/lib/mysql-binlog 2>/dev/null || true
    echo
    "$MYSQL" --defaults-file="$CNF" -e "
        SELECT TABLE_NAME,ENGINE,TABLE_ROWS,AUTO_INCREMENT,
               ROUND(DATA_LENGTH/1024/1024/1024/1024,3) AS DATA_TIB,
               ROUND(INDEX_LENGTH/1024/1024/1024/1024,3) AS INDEX_TIB,
               ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024/1024/1024,3) AS TOTAL_TIB
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME IN ('${TABLE}','${NEW_TABLE}','${OLD_TABLE}');

        SELECT TRIGGER_NAME,EVENT_OBJECT_TABLE
        FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA='${SCHEMA}'
          AND TRIGGER_NAME LIKE 'pt_osc_${SCHEMA}_${TABLE}%';

        SELECT job_id,db,tbl,new_table_name,done,ts,
               LEFT(lower_boundary,200) AS lower_boundary,
               LEFT(upper_boundary,200) AS upper_boundary
        FROM \`${HISTORY_DB}\`.\`${HISTORY_TBL}\`
        WHERE db='${SCHEMA}' AND tbl='${TABLE}'
        ORDER BY job_id DESC LIMIT 10;

        SELECT database_name,table_name,last_update,n_rows,
               clustered_index_size,sum_of_other_index_sizes
        FROM mysql.innodb_table_stats
        WHERE database_name='${SCHEMA}'
          AND table_name IN ('${TABLE}','${OLD_TABLE}');

        SELECT VARIABLE_NAME,VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME IN ('Threads_running','Threads_connected')
        ORDER BY VARIABLE_NAME;
    " 2>&1

    DATADIR="$($MYSQL --defaults-file="$CNF" -Nse "SELECT @@datadir;" 2>/dev/null || true)"
    if [[ -n "$DATADIR" ]]; then
        echo
        echo "Physical .ibd files (if file-per-table):"
        ls -lh "${DATADIR%/}/${SCHEMA}/${TABLE}.ibd" \
               "${DATADIR%/}/${SCHEMA}/${OLD_TABLE}.ibd" 2>/dev/null || true
        stat -c '%n %s bytes' \
             "${DATADIR%/}/${SCHEMA}/${TABLE}.ibd" \
             "${DATADIR%/}/${SCHEMA}/${OLD_TABLE}.ibd" 2>/dev/null || true
    fi
} > "$FINAL_LOG"

LATEST_JOB="$(latest_history_job)"
{
    echo "completed_at=$(date '+%F %T')"
    echo "schema=${SCHEMA}"
    echo "table=${TABLE}"
    echo "latest_history_job=${LATEST_JOB:-unknown}"
    echo "auto_drop_old=${AUTO_DROP_OLD}"
    echo "max_load=${MAX_LOAD}"
    echo "critical_load=${CRITICAL_LOAD}"
    echo "kill_mdl_blockers=${KILL_MDL_BLOCKERS}"
    echo "kill_blocker_users=${KILL_BLOCKER_USERS}"
    echo "blocker_kill_after_secs=${BLOCKER_KILL_AFTER_SECS}"
    echo "analyze_old_after_swap=${ANALYZE_OLD_AFTER_SWAP}"
    echo "strict_structure_validation=${STRICT_STRUCTURE_VALIDATION}"
} > "$SUCCESS_MARKER"
chmod 600 "$SUCCESS_MARKER"

stop_watchdog
trap - EXIT INT TERM

log "============================================================"
log "SUCCESS: ${SCHEMA}.${TABLE} restartable pt-osc workflow completed."
log "Final validation : ${FINAL_LOG}"
log "Killed blockers  : ${KILL_LOG}"
log "pt-osc log       : ${PTOSC_LOG}"
if table_exists "$OLD_TABLE"; then
    log "Original retained: ${SCHEMA}.${OLD_TABLE}"
fi
log "============================================================"

exit 0
