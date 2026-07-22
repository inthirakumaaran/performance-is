#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Measure metering ACCURACY: compare what JMeter actually did (from the results
# .jtl) against what the metering component recorded in the identity DB.
#
# Run on the bastion after a test (it can reach the RDS and the results JTLs):
#
#   verify-metering.sh mau <results.jtl> <rds_host> [db_user] [db_pass] [month]
#   verify-metering.sh m2m <results.jtl> <rds_host> [db_user] [db_pass]
#
#   month : MAU month bucket as MMYYYY (default = current UTC month).
#
# MAU  expected = distinct "user=<name>" labels among successful samples in the
#      JTL (the password-grant JMX embeds the username in the sample label).
#      actual   = COUNT(DISTINCT USER_ID) in IDN_MAU_COUNT for that month
#      (USER_ID is a globally-unique UUID, so this sums distinct users across all
#      tenants — matching the distinct user@tenant labels in the JTL).
# M2M  expected = number of successful (HTTP 200) client_credentials samples.
#      actual   = SUM(COUNT) in IDN_USAGE_COUNT for COUNT_TYPE='M2M_TOKEN'
#      (summed across all periods and nodes).
#
# Because the metering flush is asynchronous, the script polls the DB until the
# count stabilises before comparing. Prints accuracy % and exits non-zero if the
# accuracy is below THRESHOLD (default 99).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

METRIC="${1:?usage: verify-metering.sh <mau|m2m> <jtl> <rds_host> [user] [pass] [month]}"
JTL="${2:?results.jtl path required}"
DB_HOST="${3:?rds host required}"
DB_USER="${4:-wso2carbon}"
DB_PASS="${5:-wso2carbon}"
DB_NAME="${DB_NAME:-IDENTITY_DB}"
MONTH="${6:-$(date -u +%m%Y)}"
THRESHOLD="${THRESHOLD:-99}"           # min acceptable accuracy %
FLUSH_WAIT="${FLUSH_WAIT:-90}"         # max seconds to wait for flush to settle
POLL_STEP="${POLL_STEP:-10}"

sql() { mysql -N -B -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$1"; }

# distinct successful "user=..." labels
jtl_distinct_users() {
    awk -F',' '
        NR==1 { for(i=1;i<=NF;i++){if($i=="success")s=i; if($i=="label")l=i}; next }
        s && $s=="true" { if (match($l,/user=[^,;"]+/)) seen[substr($l,RSTART+5,RLENGTH-5)]=1 }
        END { n=0; for(k in seen)n++; print n }' "$1"
}
# successful sample count
jtl_success_count() {
    awk -F',' '
        NR==1 { for(i=1;i<=NF;i++) if($i=="success")s=i; next }
        s && $s=="true" { c++ } END { print c+0 }' "$1"
}

case "$METRIC" in
    mau)
        expected="$(jtl_distinct_users "$JTL")"
        query="SELECT COUNT(DISTINCT USER_ID) FROM IDN_MAU_COUNT WHERE MONTH_YEAR='$MONTH';"
        label="MAU distinct users (month $MONTH)"
        ;;
    m2m)
        expected="$(jtl_success_count "$JTL")"
        query="SELECT COALESCE(SUM(COUNT),0) FROM IDN_USAGE_COUNT WHERE COUNT_TYPE='M2M_TOKEN';"
        label="M2M new tokens"
        ;;
    *) echo "unknown metric: $METRIC (use mau|m2m)"; exit 2 ;;
esac

echo ">> Waiting for flush to settle (max ${FLUSH_WAIT}s) ..."
prev=-1; stable=0; waited=0; actual=0
while :; do
    actual="$(sql "$query" | tr -d '[:space:]')"; actual="${actual:-0}"
    if [ "$actual" = "$prev" ] && [ "$actual" -ge "$expected" ] 2>/dev/null; then
        stable=$((stable+POLL_STEP)); [ "$stable" -ge "$POLL_STEP" ] && break
    else
        stable=0; prev="$actual"
    fi
    [ "$waited" -ge "$FLUSH_WAIT" ] && break
    sleep "$POLL_STEP"; waited=$((waited+POLL_STEP))
done

# accuracy = 100 * actual / expected  (capped display; delta shown separately)
if [ "$expected" -gt 0 ] 2>/dev/null; then
    accuracy=$(awk -v a="$actual" -v e="$expected" 'BEGIN{printf "%.2f", (a/e)*100}')
else
    accuracy="n/a"
fi
delta=$(( actual - expected ))

echo "=================================================================="
printf "  metric   : %s\n" "$label"
printf "  expected : %s   (from %s)\n" "$expected" "$(basename "$JTL")"
printf "  actual   : %s   (from %s)\n" "$actual" "$DB_NAME@$DB_HOST"
printf "  delta    : %s\n" "$delta"
printf "  accuracy : %s%%\n" "$accuracy"
echo "=================================================================="

# Gate: pass if within threshold in both directions.
if [ "$expected" -gt 0 ] 2>/dev/null; then
    lo=$(awk -v e="$expected" -v t="$THRESHOLD" 'BEGIN{printf "%d", e*t/100}')
    if [ "$actual" -ge "$lo" ] && [ "$actual" -le "$expected" ]; then
        echo "RESULT: PASS (>= ${THRESHOLD}% and no over-count)"; exit 0
    fi
    echo "RESULT: FAIL (accuracy ${accuracy}% outside [${THRESHOLD}%,100%])"; exit 1
fi
echo "RESULT: INCONCLUSIVE (no successful samples in JTL)"; exit 1
