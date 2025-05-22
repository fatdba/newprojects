#!/bin/bash

# Usage: ./run_pdhc.sh -f [html|csv] -c "[sqlplus_connect_string]"
# Example: ./run_pdhc.sh -f html -c "sys/oracle90@ORCLPDB1 as sysdba"

FORMAT="html"
SCRIPT_NAME="/home/oracle/pdhc1.sql"
START_TIME=$(date +'%d-%b-%Y %H:%M:%S')
START_TIMESTAMP=$(date +%s)
CONNECT_STRING=""

while getopts ":f:c:" opt; do
  case $opt in
    f) FORMAT="$OPTARG"
    ;;
    c) CONNECT_STRING="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1
    ;;
  esac
done

if [ -z "$CONNECT_STRING" ]; then
  echo "[ERROR] Connection string not provided. Use -c "/ as sysdba" or similar."
  exit 1
fi

echo "=============================================="
echo " RENAPS - Database Health Check"
echo " Format: $FORMAT"
echo " Connect: $CONNECT_STRING"
echo " Started: $START_TIME"
echo "=============================================="

RUN_ID=$(date +'%d%b%Y_%H%M%S')
BASE_NAME="healthcheck_${RUN_ID}"
OUTPUT_FILE="/home/oracle/${BASE_NAME}.${FORMAT}"
LOG_FILE="/home/oracle/${BASE_NAME}.log"

case "$FORMAT" in
  html)
    MARKUP="set markup html on spool on entmap off"
    ;;
  csv)
    MARKUP="set markup csv on"
    ;;
  *)
    echo "Unsupported format. Use html or csv."
    exit 1
    ;;
esac

# Build temp SQL runner
TMP_SQL="/home/oracle/tmp_pdhc_runner_${RUN_ID}.sql"
echo "$MARKUP" > $TMP_SQL
echo "spool ${OUTPUT_FILE}" >> $TMP_SQL
cat "$SCRIPT_NAME" >> $TMP_SQL
echo "spool off" >> $TMP_SQL
echo "exit;" >> $TMP_SQL

echo "[INFO] Running health check now..."
sqlplus -s "$CONNECT_STRING" @"$TMP_SQL" > "$LOG_FILE" 2>&1
STATUS=$?

END_TIMESTAMP=$(date +%s)
DURATION=$((END_TIMESTAMP - START_TIMESTAMP))
END_TIME=$(date +'%d-%b-%Y %H:%M:%S')

echo "=============================================="
echo " Report saved to: $OUTPUT_FILE"
echo " Log file saved to: $LOG_FILE"
echo " Start time : $START_TIME"
echo " End time   : $END_TIME"
echo " Duration   : $DURATION seconds"
echo "=============================================="

if grep -qE 'ORA-|SP2-' "$LOG_FILE"; then
  echo "[ERROR] SQL*Plus runtime errors encountered:"
  grep -E 'ORA-|SP2-' "$LOG_FILE"
  echo "Refer to SQL*Plus stderr log: $LOG_FILE"
  exit 2
elif [ $STATUS -ne 0 ]; then
  echo "[ERROR] SQL*Plus failed to execute. Exit status: $STATUS"
  cat "$LOG_FILE"
  exit $STATUS
else
  echo "[INFO] Health check completed successfully."
fi
