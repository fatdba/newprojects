#!/usr/bin/env bash
#
# ptosc_realtime_monitor.sh
#
# Read-only real-time monitor for restartable pt-online-schema-change runs.
#
# Usage:
#   ./ptosc_realtime_monitor.sh <schema> <table> [refresh_seconds]
#
# Examples:
#   ./ptosc_realtime_monitor.sh FATDBA111 transaction
#   ./ptosc_realtime_monitor.sh FATDBA111 transaction 30
#   ./ptosc_realtime_monitor.sh TABLE1 position 60
#
# Environment overrides:
#   CNF=/root/ptosc/ptosc.cnf
#   BASE_DIR=/root/ptosc
#   MYSQL=mysql
#
# Ctrl+C stops ONLY this monitor.
#

set -u
umask 077

SCHEMA="${1:-}"
TABLE="${2:-}"
INTERVAL="${3:-30}"

CNF="${CNF:-/root/ptosc/ptosc.cnf}"
BASE_DIR="${BASE_DIR:-/root/ptosc}"
MYSQL="${MYSQL:-mysql}"

NEW_TABLE="_${TABLE}_new"
OLD_TABLE="_${TABLE}_old"
RUN_ROOT="${BASE_DIR}/${SCHEMA}.${TABLE}"

usage() {
    echo "Usage: $0 <schema> <table> [refresh_seconds]" >&2
    exit 2
}

[[ -n "$SCHEMA" && -n "$TABLE" ]] || usage
[[ "$SCHEMA" =~ ^[A-Za-z0-9_$]+$ ]] || { echo "ERROR: invalid schema" >&2; exit 2; }
[[ "$TABLE"  =~ ^[A-Za-z0-9_$]+$ ]] || { echo "ERROR: invalid table" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "ERROR: refresh_seconds must be an integer" >&2; exit 2; }
(( INTERVAL >= 1 )) || { echo "ERROR: refresh_seconds must be >= 1" >&2; exit 2; }

[[ -r "$CNF" ]] || { echo "ERROR: cannot read $CNF" >&2; exit 2; }
command -v "$MYSQL" >/dev/null 2>&1 || { echo "ERROR: mysql client not found" >&2; exit 2; }

mysql_q() {
    "$MYSQL" --defaults-file="$CNF" \
        --batch --skip-column-names --raw \
        -e "$1" 2>/dev/null
}

mysql_table() {
    "$MYSQL" --defaults-file="$CNF" --table -e "$1" 2>/dev/null
}

mysql_q "SELECT 1;" >/dev/null || {
    echo "ERROR: cannot connect to MySQL using $CNF" >&2
    exit 1
}

fmt_bytes() {
    local n="${1:-0}"
    if [[ "$n" =~ ^[0-9]+$ ]] && command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$n" 2>/dev/null || echo "$n"
    else
        echo "$n"
    fi
}

fmt_elapsed() {
    local secs="${1:-0}"
    if ! [[ "$secs" =~ ^[0-9]+$ ]]; then
        echo "n/a"
        return
    fi
    local d h m s
    d=$((secs/86400))
    h=$(((secs%86400)/3600))
    m=$(((secs%3600)/60))
    s=$((secs%60))
    if (( d > 0 )); then
        printf "%dd %02dh %02dm %02ds" "$d" "$h" "$m" "$s"
    elif (( h > 0 )); then
        printf "%02dh %02dm %02ds" "$h" "$m" "$s"
    else
        printf "%02dm %02ds" "$m" "$s"
    fi
}

table_exists() {
    local t="$1"
    [[ "$(mysql_q "
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='${SCHEMA}'
          AND TABLE_NAME='${t}'
          AND TABLE_TYPE='BASE TABLE';
    " || echo 0)" == "1" ]]
}

table_create_time() {
    local t="$1"
    mysql_q "
      SELECT COALESCE(DATE_FORMAT(CREATE_TIME,'%Y-%m-%d %H:%i:%s'),'')
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA='${SCHEMA}'
        AND TABLE_NAME='${t}'
      LIMIT 1;
    " || true
}

file_bytes() {
    local f="$1"
    [[ -f "$f" ]] && stat -c %s "$f" 2>/dev/null || echo 0
}

get_status_value() {
    local name="$1"
    mysql_q "SHOW GLOBAL STATUS LIKE '${name}';" | awk '{print $2}' | head -1
}

get_var_value() {
    local name="$1"
    mysql_q "SHOW GLOBAL VARIABLES LIKE '${name}';" | awk '{print $2}' | head -1
}

run_start_epoch_from_dir() {
    local d="$1"
    local b="${d##*/}"
    if [[ "$b" =~ ^([0-9]{8})_([0-9]{6})$ ]]; then
        local y="${BASH_REMATCH[1]:0:4}"
        local mo="${BASH_REMATCH[1]:4:2}"
        local da="${BASH_REMATCH[1]:6:2}"
        local hh="${BASH_REMATCH[2]:0:2}"
        local mm="${BASH_REMATCH[2]:2:2}"
        local ss="${BASH_REMATCH[2]:4:2}"
        date -d "${y}-${mo}-${da} ${hh}:${mm}:${ss}" +%s 2>/dev/null || echo ""
    else
        echo ""
    fi
}

PREV_BOUNDARY=""
PREV_EPOCH=""
PREV_HISTORY_TS=""

snapshot() {
    local NOW NOW_EPOCH
    NOW="$(date '+%F %T %Z')"
    NOW_EPOCH="$(date +%s)"

    local DATADIR
    DATADIR="$(mysql_q "SELECT @@datadir;" || echo "/var/lib/mysql/")"

    local THREADS_RUNNING THREADS_CONNECTED MAX_CONNECTIONS
    THREADS_RUNNING="$(get_status_value Threads_running)"
    THREADS_CONNECTED="$(get_status_value Threads_connected)"
    MAX_CONNECTIONS="$(get_var_value max_connections)"

    local PTOSC_LINE PTOSC_PID MAX_LOAD CRITICAL_LOAD
    PTOSC_LINE="$(pgrep -af pt-online-schema-change 2>/dev/null \
        | grep -F "D=${SCHEMA},t=${TABLE}" \
        | head -1 || true)"
    PTOSC_PID=""
    MAX_LOAD=""
    CRITICAL_LOAD=""
    if [[ -n "$PTOSC_LINE" ]]; then
        PTOSC_PID="${PTOSC_LINE%% *}"
        MAX_LOAD="$(sed -n 's/.*--max-load=Threads_running=\([0-9][0-9]*\).*/\1/p' <<<"$PTOSC_LINE")"
        CRITICAL_LOAD="$(sed -n 's/.*--critical-load=Threads_running=\([0-9][0-9]*\).*/\1/p' <<<"$PTOSC_LINE")"
    fi

    local WRAPPER_LINE WRAPPER_PID
    WRAPPER_LINE="$(pgrep -af 'ptosc_.*defrag.*\.sh|ptosc_restartable_defrag.*\.sh' 2>/dev/null \
        | grep -F "${SCHEMA} ${TABLE}" \
        | head -1 || true)"
    WRAPPER_PID=""
    [[ -n "$WRAPPER_LINE" ]] && WRAPPER_PID="${WRAPPER_LINE%% *}"

    local RUN_DIR RUN_START_EPOCH RUN_ELAPSED
    RUN_DIR=""
    if [[ -r "${RUN_ROOT}/current_run" ]]; then
        RUN_DIR="$(cat "${RUN_ROOT}/current_run" 2>/dev/null || true)"
    fi
    RUN_START_EPOCH=""
    RUN_ELAPSED="n/a"
    if [[ -n "$RUN_DIR" ]]; then
        RUN_START_EPOCH="$(run_start_epoch_from_dir "$RUN_DIR")"
        if [[ "$RUN_START_EPOCH" =~ ^[0-9]+$ ]]; then
            RUN_ELAPSED="$(fmt_elapsed $((NOW_EPOCH-RUN_START_EPOCH)))"
        fi
    fi

    local TARGET_EXISTS=0 NEW_EXISTS=0 OLD_EXISTS=0
    table_exists "$TABLE" && TARGET_EXISTS=1
    table_exists "$NEW_TABLE" && NEW_EXISTS=1
    table_exists "$OLD_TABLE" && OLD_EXISTS=1

    local TRIG_COUNT
    TRIG_COUNT="$(mysql_q "
      SELECT COUNT(*)
      FROM information_schema.TRIGGERS
      WHERE TRIGGER_SCHEMA='${SCHEMA}'
        AND TRIGGER_NAME IN (
          'pt_osc_${SCHEMA}_${TABLE}_ins',
          'pt_osc_${SCHEMA}_${TABLE}_upd',
          'pt_osc_${SCHEMA}_${TABLE}_del'
        );
    " || echo "NA")"

    local HIST_ROW HIST_JOB HIST_DONE HIST_TS HIST_LOW HIST_UP HIST_AGE
    HIST_ROW="$(mysql_q "
      SELECT
        job_id,
        done,
        DATE_FORMAT(ts,'%Y-%m-%d %H:%i:%s'),
        COALESCE(lower_boundary,''),
        COALESCE(upper_boundary,''),
        TIMESTAMPDIFF(SECOND,ts,NOW())
      FROM percona.pt_osc_history
      WHERE db='${SCHEMA}'
        AND tbl='${TABLE}'
      ORDER BY job_id DESC
      LIMIT 1;
    " || true)"

    HIST_JOB="none"
    HIST_DONE="n/a"
    HIST_TS="n/a"
    HIST_LOW=""
    HIST_UP=""
    HIST_AGE="n/a"
    if [[ -n "$HIST_ROW" ]]; then
        IFS=$'\t' read -r HIST_JOB HIST_DONE HIST_TS HIST_LOW HIST_UP HIST_AGE <<<"$HIST_ROW"
    fi

    local LIVE_ROW LIVE_ID LIVE_TIME LIVE_STATE LIVE_SQL LIVE_BOUNDARY
    LIVE_ROW="$(mysql_q "
      SELECT
        ID,
        TIME,
        COALESCE(STATE,''),
        REPLACE(REPLACE(LEFT(INFO,220),CHAR(10),' '),CHAR(13),' '),
        COALESCE(REGEXP_SUBSTR(INFO,'[0-9]{4}-[0-9]{2}-[0-9]{2}'),'')
      FROM information_schema.PROCESSLIST
      WHERE DB='${SCHEMA}'
        AND INFO IS NOT NULL
        AND INFO LIKE '%${NEW_TABLE}%'
        AND (
             INFO LIKE 'INSERT LOW_PRIORITY IGNORE%'
          OR INFO LIKE 'SELECT /*!40001 SQL_NO_CACHE */%'
        )
      ORDER BY ID
      LIMIT 1;
    " || true)"

    LIVE_ID=""
    LIVE_TIME=""
    LIVE_STATE=""
    LIVE_SQL=""
    LIVE_BOUNDARY=""
    if [[ -n "$LIVE_ROW" ]]; then
        IFS=$'\t' read -r LIVE_ID LIVE_TIME LIVE_STATE LIVE_SQL LIVE_BOUNDARY <<<"$LIVE_ROW"
    fi

    # Stable fallback: first token of Percona's saved composite lower boundary.
    local CURRENT_BOUNDARY="$LIVE_BOUNDARY"
    if [[ -z "$CURRENT_BOUNDARY" && -n "$HIST_LOW" ]]; then
        CURRENT_BOUNDARY="${HIST_LOW%%,*}"
        CURRENT_BOUNDARY="${CURRENT_BOUNDARY//\'/}"
        CURRENT_BOUNDARY="${CURRENT_BOUNDARY//\"/}"
    fi

    local FIRST_PK FIRST_PK_TYPE MIN_KEY MAX_KEY KEY_PROGRESS="" KEY_REMAINING=""
    FIRST_PK="$(mysql_q "
      SELECT COLUMN_NAME
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA='${SCHEMA}'
        AND TABLE_NAME='${TABLE}'
        AND INDEX_NAME='PRIMARY'
        AND SEQ_IN_INDEX=1
      LIMIT 1;
    " || true)"

    FIRST_PK_TYPE=""
    if [[ -n "$FIRST_PK" ]]; then
        FIRST_PK_TYPE="$(mysql_q "
          SELECT DATA_TYPE
          FROM information_schema.COLUMNS
          WHERE TABLE_SCHEMA='${SCHEMA}'
            AND TABLE_NAME='${TABLE}'
            AND COLUMN_NAME='${FIRST_PK}'
          LIMIT 1;
        " || true)"
    fi

    MIN_KEY=""
    MAX_KEY=""

    if [[ "$FIRST_PK_TYPE" =~ ^(date|datetime|timestamp)$ && "$CURRENT_BOUNDARY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        local RANGE_ROW
        RANGE_ROW="$(mysql_q "
          SELECT DATE(MIN(\`${FIRST_PK}\`)), DATE(MAX(\`${FIRST_PK}\`))
          FROM \`${SCHEMA}\`.\`${TABLE}\`;
        " || true)"
        if [[ -n "$RANGE_ROW" ]]; then
            read -r MIN_KEY MAX_KEY <<<"$RANGE_ROW"
        fi
        if [[ "$MIN_KEY" =~ ^[0-9]{4}- && "$MAX_KEY" =~ ^[0-9]{4}- ]]; then
            local PROG_ROW
            PROG_ROW="$(mysql_q "
              SELECT
                ROUND(
                  100 * DATEDIFF('${CURRENT_BOUNDARY}','${MIN_KEY}')
                  / NULLIF(DATEDIFF('${MAX_KEY}','${MIN_KEY}'),0), 2
                ),
                GREATEST(DATEDIFF('${MAX_KEY}','${CURRENT_BOUNDARY}'),0);
            " || true)"
            [[ -n "$PROG_ROW" ]] && read -r KEY_PROGRESS KEY_REMAINING <<<"$PROG_ROW"
        fi
    elif [[ "$FIRST_PK_TYPE" =~ ^(tinyint|smallint|mediumint|int|integer|bigint|decimal|numeric)$ && "$CURRENT_BOUNDARY" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        local RANGE_ROW
        RANGE_ROW="$(mysql_q "
          SELECT MIN(\`${FIRST_PK}\`), MAX(\`${FIRST_PK}\`)
          FROM \`${SCHEMA}\`.\`${TABLE}\`;
        " || true)"
        if [[ -n "$RANGE_ROW" ]]; then
            read -r MIN_KEY MAX_KEY <<<"$RANGE_ROW"
        fi
        if [[ "$MIN_KEY" =~ ^-?[0-9]+([.][0-9]+)?$ && "$MAX_KEY" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            KEY_PROGRESS="$(mysql_q "
              SELECT ROUND(
                100 * ('${CURRENT_BOUNDARY}'-'${MIN_KEY}')
                / NULLIF(('${MAX_KEY}'-'${MIN_KEY}'),0), 2
              );
            " || true)"
        fi
    fi

    local BOUNDARY_MOVEMENT="n/a"
    if [[ -n "$PREV_BOUNDARY" && -n "$CURRENT_BOUNDARY" ]]; then
        if [[ "$CURRENT_BOUNDARY" != "$PREV_BOUNDARY" ]]; then
            BOUNDARY_MOVEMENT="YES (${PREV_BOUNDARY} -> ${CURRENT_BOUNDARY})"
        else
            # Composite boundaries can move inside the same first PK value.
            if [[ -n "$PREV_HISTORY_TS" && "$HIST_TS" != "$PREV_HISTORY_TS" ]]; then
                BOUNDARY_MOVEMENT="YES (history boundary advancing within ${CURRENT_BOUNDARY})"
            else
                BOUNDARY_MOVEMENT="not observed in last ${INTERVAL}s"
            fi
        fi
    fi
    PREV_BOUNDARY="$CURRENT_BOUNDARY"
    PREV_HISTORY_TS="$HIST_TS"
    PREV_EPOCH="$NOW_EPOCH"

    local TARGET_FILE NEW_FILE OLD_FILE TARGET_BYTES NEW_BYTES OLD_BYTES
    TARGET_FILE="${DATADIR%/}/${SCHEMA}/${TABLE}.ibd"
    NEW_FILE="${DATADIR%/}/${SCHEMA}/${NEW_TABLE}.ibd"
    OLD_FILE="${DATADIR%/}/${SCHEMA}/${OLD_TABLE}.ibd"
    TARGET_BYTES="$(file_bytes "$TARGET_FILE")"
    NEW_BYTES="$(file_bytes "$NEW_FILE")"
    OLD_BYTES="$(file_bytes "$OLD_FILE")"

    local FS_FREE_BYTES FS_FREE
    FS_FREE_BYTES="$(df -B1 --output=avail "${DATADIR%/}" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
    FS_FREE="$(fmt_bytes "$FS_FREE_BYTES")"

    local TABLE_STATS
    TABLE_STATS="$(mysql_q "
      SELECT
        TABLE_NAME,
        TABLE_ROWS,
        ROUND(DATA_LENGTH/POWER(1024,3),2),
        ROUND(INDEX_LENGTH/POWER(1024,3),2),
        ROUND((DATA_LENGTH+INDEX_LENGTH)/POWER(1024,3),2)
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA='${SCHEMA}'
        AND TABLE_NAME IN ('${TABLE}','${NEW_TABLE}','${OLD_TABLE}')
      ORDER BY FIELD(TABLE_NAME,'${TABLE}','${NEW_TABLE}','${OLD_TABLE}');
    " || true)"

    local MDL_COUNT
    MDL_COUNT="$(mysql_q "
      SELECT COUNT(*)
      FROM sys.schema_table_lock_waits
      WHERE object_schema='${SCHEMA}'
        AND object_name IN ('${TABLE}','${NEW_TABLE}','${OLD_TABLE}');
    " || echo "NA")"

    # Replica status. Empty on a standalone/primary server.
    local REPLICA_RAW REPLICA_IO REPLICA_SQL REPLICA_LAG REPLICA_SOURCE
    REPLICA_RAW="$("$MYSQL" --defaults-file="$CNF" -e "SHOW REPLICA STATUS\G" 2>/dev/null || true)"
    REPLICA_IO="$(awk -F': ' '/Replica_IO_Running:/{print $2; exit}' <<<"$REPLICA_RAW")"
    REPLICA_SQL="$(awk -F': ' '/Replica_SQL_Running:/{print $2; exit}' <<<"$REPLICA_RAW")"
    REPLICA_LAG="$(awk -F': ' '/Seconds_Behind_Source:/{print $2; exit}' <<<"$REPLICA_RAW")"
    REPLICA_SOURCE="$(awk -F': ' '/Source_Host:/{print $2; exit}' <<<"$REPLICA_RAW")"

    local STATUS="UNKNOWN"
    if [[ "$HIST_DONE" == "yes" && $TARGET_EXISTS -eq 1 && $NEW_EXISTS -eq 0 && $OLD_EXISTS -eq 1 && "$TRIG_COUNT" == "0" ]]; then
        STATUS="COMPLETE / SWAPPED - OLD TABLE RETAINED"
    elif [[ "$HIST_DONE" == "yes" && $TARGET_EXISTS -eq 1 && $NEW_EXISTS -eq 0 && $OLD_EXISTS -eq 0 && "$TRIG_COUNT" == "0" ]]; then
        STATUS="COMPLETE - OLD TABLE ALREADY DROPPED"
    elif [[ -n "$PTOSC_PID" && -n "$LIVE_SQL" ]]; then
        STATUS="COPYING"
    elif [[ -n "$PTOSC_PID" && "$THREADS_RUNNING" =~ ^[0-9]+$ && "$MAX_LOAD" =~ ^[0-9]+$ ]] \
         && (( THREADS_RUNNING > MAX_LOAD )); then
        STATUS="THROTTLED / PAUSED BY MAX-LOAD"
    elif [[ -n "$PTOSC_PID" ]]; then
        STATUS="PT-OSC RUNNING - BETWEEN CHUNKS / ANALYZE / CUTOVER"
    elif [[ -n "$WRAPPER_PID" ]]; then
        STATUS="WRAPPER RUNNING - PT-OSC PROCESS NOT CURRENTLY VISIBLE"
    elif [[ "$HIST_DONE" == "no" && $NEW_EXISTS -eq 1 && "$TRIG_COUNT" == "3" ]]; then
        STATUS="INTERRUPTED - RESUMABLE"
    elif [[ $TARGET_EXISTS -eq 1 && $NEW_EXISTS -eq 0 && $OLD_EXISTS -eq 0 && "$TRIG_COUNT" == "0" ]]; then
        STATUS="NOT RUNNING / CLEAN TARGET"
    fi

    local LAST_ERROR=""
    if [[ -n "$RUN_DIR" && -f "${RUN_DIR}/wrapper.log" ]]; then
        LAST_ERROR="$(grep -E 'ERROR:|FAILED rc=' "${RUN_DIR}/wrapper.log" 2>/dev/null | tail -1 || true)"
    fi
    if [[ "$STATUS" == "NOT RUNNING / CLEAN TARGET" && -n "$LAST_ERROR" ]]; then
        STATUS="FAILED / NOT RUNNING"
    fi

    printf '\033[2J\033[H'
    echo "================================================================================"
    echo "             pt-online-schema-change REAL-TIME MONITOR"
    echo "================================================================================"
    echo " Server     : $(hostname -s 2>/dev/null || hostname)"
    echo " Target     : ${SCHEMA}.${TABLE}"
    echo " Time       : ${NOW}"
    echo " Status     : ${STATUS}"
    echo " Elapsed    : ${RUN_ELAPSED} (current wrapper invocation)"
    echo " Run dir    : ${RUN_DIR:-not found}"
    echo "================================================================================"
    echo

    echo "[PROCESSES]"
    printf "  Wrapper PID       : %s\n" "${WRAPPER_PID:-not running}"
    printf "  pt-osc PID        : %s\n" "${PTOSC_PID:-not running}"
    printf "  max-load          : Threads_running=%s\n" "${MAX_LOAD:-n/a}"
    printf "  critical-load     : Threads_running=%s\n" "${CRITICAL_LOAD:-n/a}"
    echo

    echo "[MYSQL LOAD]"
    printf "  Threads_running   : %s\n" "${THREADS_RUNNING:-n/a}"
    printf "  Threads_connected : %s / %s max\n" "${THREADS_CONNECTED:-n/a}" "${MAX_CONNECTIONS:-n/a}"
    if [[ "$THREADS_RUNNING" =~ ^[0-9]+$ && "$MAX_LOAD" =~ ^[0-9]+$ ]]; then
        if (( THREADS_RUNNING > MAX_LOAD )); then
            echo "  Load state        : ABOVE max-load -> pt-osc should throttle"
        else
            echo "  Load state        : below max-load -> copying is allowed"
        fi
    fi
    echo

    echo "[RESTART / HISTORY]"
    printf "  job_id            : %s\n" "$HIST_JOB"
    printf "  done              : %s\n" "$HIST_DONE"
    printf "  last heartbeat    : %s\n" "$HIST_TS"
    printf "  heartbeat age     : %s seconds\n" "$HIST_AGE"
    printf "  lower boundary    : %.180s\n" "${HIST_LOW:-n/a}"
    printf "  upper boundary    : %.180s\n" "${HIST_UP:-n/a}"
    echo

    echo "[LIVE COPY / PROGRESS]"
    printf "  first PK          : %s (%s)\n" "${FIRST_PK:-n/a}" "${FIRST_PK_TYPE:-n/a}"
    printf "  current boundary  : %s\n" "${CURRENT_BOUNDARY:-not visible}"
    printf "  boundary moving   : %s\n" "$BOUNDARY_MOVEMENT"
    printf "  MySQL state       : %s\n" "${LIVE_STATE:-n/a}"
    printf "  chunk SQL time    : %s sec\n" "${LIVE_TIME:-n/a}"
    [[ -n "$LIVE_SQL" ]] && printf "  current SQL       : %.200s\n" "$LIVE_SQL"
    if [[ -n "$KEY_PROGRESS" && "$KEY_PROGRESS" != "NULL" ]]; then
        printf "  key-range progress: %s%% [approximate, NOT exact row %%]\n" "$KEY_PROGRESS"
        if [[ -n "$MIN_KEY" && -n "$MAX_KEY" ]]; then
            printf "  key range         : %s -> %s\n" "$MIN_KEY" "$MAX_KEY"
        fi
        [[ -n "$KEY_REMAINING" ]] && printf "  key units remain  : %s\n" "$KEY_REMAINING"
    fi
    echo

    echo "[OBJECT STATE]"
    printf "  %-28s : %s\n" "$TABLE" "$([[ $TARGET_EXISTS -eq 1 ]] && echo EXISTS || echo MISSING)"
    printf "  %-28s : %s\n" "$NEW_TABLE" "$([[ $NEW_EXISTS -eq 1 ]] && echo EXISTS || echo MISSING)"
    printf "  %-28s : %s\n" "$OLD_TABLE" "$([[ $OLD_EXISTS -eq 1 ]] && echo EXISTS || echo MISSING)"
    printf "  pt-osc sync triggers         : %s\n" "$TRIG_COUNT"
    echo

    echo "[TABLE / FILE SIZES]"
    printf "  %-28s : %s physical\n" "${TABLE}.ibd" "$(fmt_bytes "$TARGET_BYTES")"
    printf "  %-28s : %s physical\n" "${NEW_TABLE}.ibd" "$(fmt_bytes "$NEW_BYTES")"
    if (( OLD_BYTES > 0 )); then
        printf "  %-28s : %s physical\n" "${OLD_TABLE}.ibd" "$(fmt_bytes "$OLD_BYTES")"
    fi
    printf "  Filesystem free             : %s\n" "$FS_FREE"
    echo
    if [[ -n "$TABLE_STATS" ]]; then
        printf "  %-28s %-15s %-12s %-12s %-12s\n" "TABLE" "EST_ROWS" "DATA_GIB" "INDEX_GIB" "TOTAL_GIB"
        while IFS=$'\t' read -r tn rows dg ig tg; do
            printf "  %-28s %-15s %-12s %-12s %-12s\n" "$tn" "$rows" "$dg" "$ig" "$tg"
        done <<<"$TABLE_STATS"
        echo
    fi

    echo "[METADATA LOCKS]"
    printf "  MDL wait rows      : %s\n" "$MDL_COUNT"
    if [[ "$MDL_COUNT" =~ ^[0-9]+$ ]] && (( MDL_COUNT > 0 )); then
        mysql_table "
          SELECT
            object_name,
            waiting_pid,
            waiting_account,
            waiting_query_secs,
            blocking_pid,
            blocking_account,
            sql_kill_blocking_connection
          FROM sys.schema_table_lock_waits
          WHERE object_schema='${SCHEMA}'
            AND object_name IN ('${TABLE}','${NEW_TABLE}','${OLD_TABLE}');
        " || true
    fi
    echo

    echo "[REPLICA]"
    if [[ -n "$REPLICA_RAW" ]]; then
        printf "  Source             : %s\n" "${REPLICA_SOURCE:-n/a}"
        printf "  Replica_IO_Running : %s\n" "${REPLICA_IO:-n/a}"
        printf "  Replica_SQL_Running: %s\n" "${REPLICA_SQL:-n/a}"
        printf "  Seconds_Behind     : %s\n" "${REPLICA_LAG:-n/a}"
    else
        echo "  This instance did not return SHOW REPLICA STATUS."
    fi
    echo

    if [[ -n "$RUN_DIR" && -f "${RUN_DIR}/killed-blockers.log" ]]; then
        echo "[KILLED BLOCKERS - LAST 5]"
        if [[ -s "${RUN_DIR}/killed-blockers.log" ]]; then
            tail -5 "${RUN_DIR}/killed-blockers.log"
        else
            echo "  None."
        fi
        echo
    fi

    if [[ -n "$RUN_DIR" && -f "${RUN_DIR}/pt-online-schema-change.log" ]]; then
        echo "[PT-OSC LOG - LAST 8]"
        tail -8 "${RUN_DIR}/pt-online-schema-change.log"
        echo
    fi

    if [[ -n "$RUN_DIR" && -f "${RUN_DIR}/wrapper.log" ]]; then
        echo "[WRAPPER LOG - LAST 8]"
        tail -8 "${RUN_DIR}/wrapper.log"
        echo
    fi

    if [[ -n "$LAST_ERROR" ]]; then
        echo "[LAST WRAPPER ERROR]"
        echo "  $LAST_ERROR"
        echo
    fi

    echo "================================================================================"
    echo " Refresh every ${INTERVAL}s. Ctrl+C stops ONLY this monitor."
    echo "================================================================================"
}

while :; do
    snapshot
    sleep "$INTERVAL"
done

