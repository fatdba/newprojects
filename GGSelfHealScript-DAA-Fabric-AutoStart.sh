#!/bin/bash
###############################################################################
# GoldenGate Fabric Capacity Window Controller
#
# Purpose:
#   Cleanly stop GoldenGate CDC Replicats before Microsoft Fabric capacity
#   shutdown and automatically restart/validate them when capacity returns.
#
# Managed groups:
#   RP11ADON
#   RP19ADON
#
# Initial-load/test Replicats are intentionally NOT managed.
###############################################################################

set -u

###############################################################################
# CONFIGURATION
###############################################################################

ADMINCLIENT="/u01/app/ogg/ogg23ai/ogg23aidaa_MA/bin/adminclient"

OGG_URL="http://10.0.0.4:9001"
OGG_DEPLOYMENT="ORATOFAB23AI"
OGG_USER="oggadmin"

# Password is stored separately with chmod 600.
PASSWORD_FILE="/u01/app/ogg/.ogg_admin_password"

LOG_DIR="/u01/app/ogg/ogg_capacity_logs"
LOG_FILE="${LOG_DIR}/ogg_fabric_capacity_$(date +%Y%m%d).log"

REPLICATS=(
    "RP11ADON"
    "RP19ADON"
)

START_RETRIES=3
START_WAIT=20
RETRY_WAIT=60

mkdir -p "$LOG_DIR"

###############################################################################
# FUNCTIONS
###############################################################################

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') | $*" | tee -a "$LOG_FILE"
}


check_password_file()
{
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        log "ERROR: Password file not found: $PASSWORD_FILE"
        exit 1
    fi

    OGG_PASSWORD=$(<"$PASSWORD_FILE")

    if [[ -z "$OGG_PASSWORD" ]]; then
        log "ERROR: Password file is empty."
        exit 1
    fi
}


run_adminclient()
{
    local COMMANDS="$1"

    "$ADMINCLIENT" <<EOF
CONNECT ${OGG_URL} DEPLOYMENT ${OGG_DEPLOYMENT} USER ${OGG_USER} PASSWORD ${OGG_PASSWORD}
${COMMANDS}
EXIT
EOF
}


get_status()
{
    local GROUP="$1"

    run_adminclient "INFO REPLICAT ${GROUP}" 2>&1 |
        awk '
        /^Replicat[[:space:]]+/ {
            for (i=1; i<=NF; i++) {
                if ($i == "Status") {
                    print $(i+1)
                    exit
                }
            }
        }'
}

show_info()
{
    local GROUP="$1"

    log "Current status for ${GROUP}:"

    run_adminclient "
INFO REPLICAT ${GROUP}
" >> "$LOG_FILE" 2>&1
}


start_replicat()
{
    local GROUP="$1"
    local STATUS
    local ATTEMPT

    STATUS=$(get_status "$GROUP")

    log "${GROUP}: current status = ${STATUS:-UNKNOWN}"

    if [[ "$STATUS" == "RUNNING" ]]; then
        log "${GROUP}: already RUNNING. Nothing to do."
        return 0
    fi

    for ((ATTEMPT=1; ATTEMPT<=START_RETRIES; ATTEMPT++))
    do
        log "${GROUP}: START attempt ${ATTEMPT}/${START_RETRIES}"

        run_adminclient "
START REPLICAT ${GROUP}
" >> "$LOG_FILE" 2>&1

        log "${GROUP}: waiting ${START_WAIT} seconds for stabilization."
        sleep "$START_WAIT"

        STATUS=$(get_status "$GROUP")

        log "${GROUP}: status after START = ${STATUS:-UNKNOWN}"

        if [[ "$STATUS" == "RUNNING" ]]; then
            log "${GROUP}: successfully RUNNING."
            show_info "$GROUP"
            return 0
        fi

        if [[ "$STATUS" == "ABENDED" ]]; then
            log "WARNING: ${GROUP} ABENDED after restart."

            log "Capturing Replicat report for troubleshooting."

            run_adminclient "
VIEW REPORT ${GROUP}
" >> "$LOG_FILE" 2>&1
        fi

        if [[ "$ATTEMPT" -lt "$START_RETRIES" ]]; then
            log "${GROUP}: retrying after ${RETRY_WAIT} seconds."
            sleep "$RETRY_WAIT"
        fi
    done

    log "ERROR: ${GROUP} failed to remain RUNNING after ${START_RETRIES} attempts."
    return 1
}


stop_replicat()
{
    local GROUP="$1"
    local STATUS

    STATUS=$(get_status "$GROUP")

    log "${GROUP}: current status = ${STATUS:-UNKNOWN}"

    if [[ "$STATUS" == "STOPPED" ]]; then
        log "${GROUP}: already STOPPED."
        return 0
    fi

    if [[ "$STATUS" == "ABENDED" ]]; then
        log "${GROUP}: already ABENDED; no clean stop required."
        return 0
    fi

    if [[ "$STATUS" == "RUNNING" ]]; then
        log "${GROUP}: issuing controlled STOP."

        run_adminclient "
STOP REPLICAT ${GROUP}
" >> "$LOG_FILE" 2>&1

        sleep 10

        STATUS=$(get_status "$GROUP")

        log "${GROUP}: status after STOP = ${STATUS:-UNKNOWN}"

        if [[ "$STATUS" == "STOPPED" ]]; then
            log "${GROUP}: cleanly STOPPED."
            return 0
        else
            log "WARNING: ${GROUP} did not reach STOPPED state."
            return 1
        fi
    fi
}


start_all()
{
    local FAILED=0

    log "============================================================"
    log "GoldenGate Fabric capacity START window"
    log "============================================================"

    for GROUP in "${REPLICATS[@]}"
    do
        start_replicat "$GROUP" || FAILED=1
    done

    log "Final GoldenGate status:"

    run_adminclient "
INFO ALL
" >> "$LOG_FILE" 2>&1

    if [[ "$FAILED" -eq 0 ]]; then
        log "All managed CDC Replicats are RUNNING."
    else
        log "WARNING: One or more Replicats failed to start."
    fi

    log "============================================================"

    return "$FAILED"
}


stop_all()
{
    local FAILED=0

    log "============================================================"
    log "GoldenGate Fabric capacity STOP window"
    log "============================================================"

    for GROUP in "${REPLICATS[@]}"
    do
        stop_replicat "$GROUP" || FAILED=1
    done

    log "Final GoldenGate status:"

    run_adminclient "
INFO ALL
" >> "$LOG_FILE" 2>&1

    log "============================================================"

    return "$FAILED"
}


###############################################################################
# MAIN
###############################################################################

check_password_file

case "${1:-}" in

    start)
        start_all
        ;;

    stop)
        stop_all
        ;;

    status)
        run_adminclient "
INFO ALL
"
        ;;

    *)
        echo
        echo "Usage:"
        echo "  $0 start"
        echo "  $0 stop"
        echo "  $0 status"
        echo
        exit 1
        ;;
esac
