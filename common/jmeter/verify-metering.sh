#!/usr/bin/env bash
# Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com) All Rights Reserved.
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
#
# -----------------------------------------------------------------------------
# Verify WSO2 IS usage-metering accuracy (MAU + M2M tokens) after a perf run.
#
# Runs on the bastion node, which can reach both RDS instances and can ssh to
# the IS nodes using the aliases set up by setup-jmeter-client-is.sh.
#
#   verify-metering.sh reset  --identity-host <rds> [opts]
#   verify-metering.sh verify --identity-host <rds> --session-host <session-rds> [opts]
#
# WHY IT LOOKS LIKE THIS
# ----------------------
# Both metrics are checked against ground truth that the Identity Server itself
# records independently of the metering component, so nothing has to be inferred
# from the JMeter side (no JMX label hacks, no unique-scope tricks):
#
#   MAU : ground truth = distinct USER_ID in SESSION_DB.IDN_AUTH_USER_SESSION_MAPPING
#         (one row per user per session -> exactly the users that authenticated).
#         Truncated by clean_session_database.sql before every scenario.
#   M2M : ground truth = rows in IDENTITY_DB.IDN_OAUTH2_ACCESS_TOKEN with
#         GRANT_TYPE='client_credentials'. A reused token does not create a row,
#         which is precisely the component's "new tokens only" rule.
#         Truncated by clean_database.sql before every scenario.
#
# Each metric is reported as a 4-stage pipeline so a mismatch points at the stage
# that lost (or invented) counts instead of just yielding a bad percentage:
#
#   MAU : authenticated -> recorded in cache -> flushed to IDN_MAU_COUNT -> published
#   M2M : token issued  -> handler increment -> drained by collector      -> stored by receiver
#
# Stages 2/3 are read from the IS logs and are diagnostic only: they need DEBUG on
# org.wso2.carbon.usage.data.collector.identity and are reported as "n/a" without
# it. restart-is.sh wipes repository/logs on every scenario, so these counts are
# always scoped to the scenario just executed.
#
# MAU is compared as a SET of user ids, so both under- and over-counting surface
# with sample ids to chase. M2M is a volume metric and is compared as a total.
#
# CAVEATS
#   * Stages 2/3 need DEBUG on org.wso2.carbon.usage.data.collector.identity. That
#     also emits one line per login and per token issuance, which is fine for an
#     accuracy run but will distort a throughput run — set those loggers to INFO in
#     the pack's log4j2.properties before measuring performance.
#   * If OAuth token cleanup is enabled, rows for renewed/revoked tokens can be
#     deleted, which erodes the M2M ground truth (stage 1) without affecting what
#     the component counted. Stage 1 < stage 3 == stage 4 is that situation, not an
#     over-count by the metering component.
# -----------------------------------------------------------------------------

set -uo pipefail

DB_USER="wso2carbon"
DB_PASS="wso2carbon"
IDENTITY_DB="IDENTITY_DB"
SESSION_DB="SESSION_DB"
identity_host=""
session_host=""
month=""
metric="all"
settle_seconds=240
poll_seconds=15
is_hosts=""
out_file=""
tolerance_percent=0
scenario_label=""
state_file="/tmp/metering-state.env"
purge_receiver=false
summary_file=""

script_name=$(basename "$0")

function usage() {
    cat <<EOF

Usage:
  $script_name reset  --identity-host <host> [--db-user U] [--db-pass P]
  $script_name verify --identity-host <host> --session-host <host> [options]

Commands:
  reset     Prepare for a scenario: clear IDN_MAU_COUNT and record the receiver's
            current M2M total as a baseline in the state file. Run it AFTER the IS
            restart, so the in-memory MAU cache is already empty and cannot
            re-populate the table on the next flush.
  verify    Compare the metering output against the Identity Server's own records
            and print the per-stage report.

Options:
  --identity-host <host>   RDS host holding IDENTITY_DB (required).
  --session-host <host>    RDS host holding SESSION_DB (required for verify).
  --db-user <user>         DB user. Default: $DB_USER.
  --db-pass <pass>         DB password. Default: $DB_PASS.
  --metric <all|mau|m2m>   Which metric to verify. Default: $metric.
  --month <MMYYYY>         MAU month bucket. Default: current UTC month.
  --settle-seconds <n>     Max wait for the flush/publish cycles to settle. Default: $settle_seconds.
  --poll-seconds <n>       Poll interval while settling. Default: $poll_seconds.
  --is-hosts "<a b ...>"   ssh aliases of the IS nodes, for the log-based stages.
  --tolerance <percent>    Percent deviation reported as WARN instead of FAIL. Default: $tolerance_percent.
  --label <text>           Free-text label (scenario / concurrency) for the report header.
  --out <file>             Write the report to this file as well as stdout.
  --summary-file <file>    Append a one-line result to this file, so a whole run can
                           be read at a glance instead of opening every report.
  --state-file <file>      Where reset stores the receiver baseline. Default: $state_file.
  --purge-receiver         reset only: also delete the receiver's USAGE_COUNT /
                           DAILY_USAGE_COUNT / MONTHLY_USAGE_COUNT rows. Off by
                           default because those rows are hash-chained
                           (RECORD_HASH / PREVIOUS_HASH); the baseline makes
                           deleting them unnecessary.
  -h, --help               Show this help.

Exit codes: 0 pass, 1 fail, 2 usage error, 3 inconclusive (no traffic recorded).
EOF
}

command="${1:-}"
if [[ -z $command ]]; then
    usage
    exit 2
fi
shift || true

case "$command" in
reset | verify) ;;
-h | --help)
    usage
    exit 0
    ;;
*)
    echo "ERROR: unknown command '$command'"
    usage
    exit 2
    ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
    --identity-host)
        identity_host="$2"
        shift 2
        ;;
    --session-host)
        session_host="$2"
        shift 2
        ;;
    --db-user)
        DB_USER="$2"
        shift 2
        ;;
    --db-pass)
        DB_PASS="$2"
        shift 2
        ;;
    --metric)
        metric="$2"
        shift 2
        ;;
    --month)
        month="$2"
        shift 2
        ;;
    --settle-seconds)
        settle_seconds="$2"
        shift 2
        ;;
    --poll-seconds)
        poll_seconds="$2"
        shift 2
        ;;
    --is-hosts)
        is_hosts="$2"
        shift 2
        ;;
    --tolerance)
        tolerance_percent="$2"
        shift 2
        ;;
    --label)
        scenario_label="$2"
        shift 2
        ;;
    --out)
        out_file="$2"
        shift 2
        ;;
    --state-file)
        state_file="$2"
        shift 2
        ;;
    --summary-file)
        summary_file="$2"
        shift 2
        ;;
    --purge-receiver)
        purge_receiver=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "ERROR: unknown option '$1'"
        usage
        exit 2
        ;;
    esac
done

if [[ -z $identity_host ]]; then
    echo "ERROR: --identity-host is required."
    exit 2
fi
if [[ $command == "verify" && -z $session_host ]]; then
    echo "ERROR: --session-host is required for verify."
    exit 2
fi
case "$metric" in
all | mau | m2m) ;;
*)
    echo "ERROR: --metric must be one of all|mau|m2m"
    exit 2
    ;;
esac
if [[ -z $month ]]; then
    # MAUCacheManager stamps MONTH_YEAR from the IS server's local time; EC2 nodes run UTC.
    month=$(date -u +%m%Y)
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# ── DB helpers ───────────────────────────────────────────────────────────────

# run_sql <db> <host> <query> -> rows on stdout, stderr suppressed (missing tables
# are an expected, reported outcome rather than a hard failure).
function run_sql() {

    local db="$1" host="$2" query="$3"
    mysql -N -B --connect-timeout=15 -h "$host" -u "$DB_USER" -p"$DB_PASS" "$db" -e "$query" 2>/dev/null
}

# run_sql_number <db> <host> <query> -> first value, or empty when unavailable.
function run_sql_number() {

    local value
    value=$(run_sql "$1" "$2" "$3" | head -1 | tr -d '[:space:]')
    if [[ $value == "NULL" ]]; then
        value="0"
    fi
    echo "$value"
}

function check_db() {

    local db="$1" host="$2" label="$3"
    local error
    error=$(mysql -N -B --connect-timeout=15 -h "$host" -u "$DB_USER" -p"$DB_PASS" "$db" \
        -e "SELECT 1" 2>&1 >/dev/null | grep -v "Using a password on the command line")
    if [[ -n $error ]]; then
        echo "ERROR: cannot query $label ($db@$host): $error"
        return 1
    fi
    return 0
}

# A missing table and an empty table look identical through COUNT(*) queries; this
# separates them so "nothing was metered" is never confused with "the pack/dbscript
# never created the table".
function table_exists() {

    local db="$1" host="$2" table="$3" found
    found=$(run_sql_number "$db" "$host" \
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND TABLE_NAME='$table'")
    [[ $(num_or_zero "$found") -gt 0 ]]
}

function missing_tables() {

    local missing="" spec db host table
    for spec in "$IDENTITY_DB|$identity_host|IDN_MAU_COUNT" \
        "$IDENTITY_DB|$identity_host|USAGE_COUNT" \
        "$IDENTITY_DB|$identity_host|DAILY_USAGE_COUNT" \
        "$IDENTITY_DB|$identity_host|IDN_OAUTH2_ACCESS_TOKEN" \
        "$SESSION_DB|$session_host|IDN_AUTH_USER_SESSION_MAPPING"; do
        db="${spec%%|*}"
        host="${spec#*|}"
        host="${host%%|*}"
        table="${spec##*|}"
        table_exists "$db" "$host" "$table" || missing+="$db.$table "
    done
    echo "${missing% }"
}

function num_or_zero() {

    local value="${1:-}"
    if [[ $value =~ ^-?[0-9]+$ ]]; then
        echo "$value"
    else
        echo "0"
    fi
}

# ── IS log helpers (diagnostic stages) ───────────────────────────────────────

CARBON_LOG="/home/ubuntu/wso2is/repository/logs/wso2carbon.log"

# is_log_cmd <host> <remote command> -> stdout, empty on any failure.
function is_log_cmd() {

    local host="$1" remote_cmd="$2"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$host" "$remote_cmd" 2>/dev/null
}

# Sums a per-node count across all IS nodes. Prints "total|per-node breakdown",
# or "n/a|" when no node produced a usable number (e.g. DEBUG logging is off).
function sum_over_is_nodes() {

    local remote_cmd="$1"
    local total=0 breakdown="" saw_value=false host value
    for host in $is_hosts; do
        value=$(is_log_cmd "$host" "$remote_cmd" | tail -1 | tr -d '[:space:]')
        if [[ $value =~ ^[0-9]+$ ]]; then
            saw_value=true
            total=$((total + value))
            breakdown+="$host:$value "
        else
            breakdown+="$host:? "
        fi
    done
    if [[ $saw_value == true ]]; then
        echo "$total|$breakdown"
    else
        echo "n/a|$breakdown"
    fi
}

# Distinct MAU cache keys recorded across the cluster. Each key is
# "<userId>:<tenant>|<MMYYYY>", so distinct keys == distinct metered users.
function distinct_mau_log_users() {

    local host
    : >"$tmp_dir/log_mau_keys.raw"
    for host in $is_hosts; do
        is_log_cmd "$host" "grep -o 'Recorded login: key=[^ ]*' $CARBON_LOG 2>/dev/null | sort -u" \
            >>"$tmp_dir/log_mau_keys.raw"
    done
    if [[ ! -s "$tmp_dir/log_mau_keys.raw" ]]; then
        echo "n/a"
        return
    fi
    sort -u "$tmp_dir/log_mau_keys.raw" | wc -l | tr -d '[:space:]'
}

# Sum of "count=N" over the collector's publish log lines for one count type.
# UsageCountDataCollector logs the drained value whether or not the receiver
# accepted it, so this reflects everything the collector took out of the cache.
function published_from_logs() {

    local count_type="$1"
    local pattern="usage count: type=$count_type count="
    sum_over_is_nodes "grep -o '${pattern}[0-9]*' $CARBON_LOG 2>/dev/null | awk -F'count=' '{s+=\$2} END{print s+0}'"
}

# ── reset ────────────────────────────────────────────────────────────────────

if [[ $command == "reset" ]]; then
    echo "Preparing usage-metering state in $IDENTITY_DB@$identity_host ..."

    # IDN_MAU_COUNT is a plain table and must start empty: the MAU ground truth
    # (IDN_AUTH_USER_SESSION_MAPPING) is truncated per scenario, so leftover rows
    # from an earlier scenario would look like over-counting.
    {
        echo "DELETE FROM IDN_MAU_COUNT;"
        if [[ $purge_receiver == true ]]; then
            # DEPLOYMENT_META_INFORMATION is deliberately left alone: it is the
            # receiver's node registry, USAGE_COUNT has an FK to it, and it is only
            # re-populated at server start-up.
            echo "SET FOREIGN_KEY_CHECKS=0;"
            echo "DELETE FROM USAGE_COUNT;"
            echo "DELETE FROM DAILY_USAGE_COUNT;"
            echo "DELETE FROM MONTHLY_USAGE_COUNT;"
            echo "SET FOREIGN_KEY_CHECKS=1;"
        fi
    } >"$tmp_dir/reset.sql"

    # --force: an older pack without the receiver tables must not abort the rest.
    mysql --force --connect-timeout=15 -h "$identity_host" -u "$DB_USER" -p"$DB_PASS" \
        "$IDENTITY_DB" <"$tmp_dir/reset.sql" 2>&1 |
        grep -v "Using a password on the command line" || true

    # The receiver's rows are hash-chained, so instead of deleting them we remember
    # the current total and verify the delta produced by the coming scenario.
    m2m_baseline=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" \
        "SELECT COALESCE(SUM(VALUE),0) FROM USAGE_COUNT WHERE COUNT_TYPE='M2M_TOKEN'")")
    m2m_daily_baseline=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" \
        "SELECT COALESCE(SUM(VALUE),0) FROM DAILY_USAGE_COUNT WHERE COUNT_TYPE='M2M_TOKEN'")")
    {
        echo "m2m_baseline=$m2m_baseline"
        echo "m2m_daily_baseline=$m2m_daily_baseline"
    } >"$state_file"

    echo "Reset done (m2m baseline: $m2m_baseline, state: $state_file)."
    exit 0
fi

# ── verify ───────────────────────────────────────────────────────────────────

check_db "$IDENTITY_DB" "$identity_host" "identity DB" || exit 2
check_db "$SESSION_DB" "$session_host" "session DB" || exit 2

missing_table_list=$(missing_tables)
if [[ -n $missing_table_list ]]; then
    echo "WARN: tables not found: $missing_table_list"
    echo "      (the metering/receiver tables come from the pack's dbscripts/identity/mysql.sql,"
    echo "       which create_database.sql sources — check the pack if they are missing.)"
fi

# Baselines written by `reset`; absent means "measure absolute totals".
m2m_baseline=0
m2m_daily_baseline=0
baseline_source="none (absolute totals)"
if [[ -f $state_file ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    m2m_baseline=$(num_or_zero "${m2m_baseline:-0}")
    m2m_daily_baseline=$(num_or_zero "${m2m_daily_baseline:-0}")
    baseline_source="$state_file (m2m baseline $m2m_baseline)"
fi

Q_AUTHENTICATED_USERS="SELECT COUNT(DISTINCT USER_ID) FROM IDN_AUTH_USER_SESSION_MAPPING"
Q_AUTHENTICATED_IDS="SELECT DISTINCT USER_ID FROM IDN_AUTH_USER_SESSION_MAPPING"
Q_MAU_DISTINCT="SELECT COUNT(DISTINCT USER_ID) FROM IDN_MAU_COUNT WHERE MONTH_YEAR='$month'"
Q_MAU_ROWS="SELECT COUNT(*) FROM IDN_MAU_COUNT WHERE MONTH_YEAR='$month'"
Q_MAU_IDS="SELECT DISTINCT USER_ID FROM IDN_MAU_COUNT WHERE MONTH_YEAR='$month'"
# The latest row, not MAX: with mau_interval_publish the coordinator republishes the
# month's running distinct count every cycle, so only the most recent row is current.
Q_MAU_PUBLISHED="SELECT COALESCE((SELECT VALUE FROM USAGE_COUNT WHERE COUNT_TYPE='MAU' ORDER BY CREATED_TIME DESC LIMIT 1),0)"
Q_CC_TOKENS="SELECT COUNT(*) FROM IDN_OAUTH2_ACCESS_TOKEN WHERE GRANT_TYPE='client_credentials'"
Q_M2M_PUBLISHED="SELECT COALESCE(SUM(VALUE),0) FROM USAGE_COUNT WHERE COUNT_TYPE='M2M_TOKEN'"
Q_M2M_DAILY="SELECT COALESCE(SUM(VALUE),0) FROM DAILY_USAGE_COUNT WHERE COUNT_TYPE='M2M_TOKEN'"
Q_M2M_PUBLISH_ROWS="SELECT COUNT(*) FROM USAGE_COUNT WHERE COUNT_TYPE='M2M_TOKEN'"

# Wait for the asynchronous stages to settle: the MAU flush task (flushInterval,
# minutes) and the usage-count collector (IntervalSeconds). Both values must stop
# moving for two consecutive polls before we compare anything.
echo "Waiting for the metering flush/publish cycles to settle (max ${settle_seconds}s) ..."
waited=0
prev_signature=""
stable_polls=0
while :; do
    mau_now=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_MAU_DISTINCT")")
    m2m_now=$(($(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_M2M_PUBLISHED")") - m2m_baseline))
    signature="$mau_now/$m2m_now"
    if [[ $signature == "$prev_signature" ]]; then
        stable_polls=$((stable_polls + 1))
        if [[ $stable_polls -ge 2 ]]; then
            break
        fi
    else
        stable_polls=0
        prev_signature="$signature"
    fi
    if [[ $waited -ge $settle_seconds ]]; then
        echo "WARN: values still changing after ${settle_seconds}s; comparing anyway."
        break
    fi
    nap=$poll_seconds
    if [[ $((waited + nap)) -gt $settle_seconds ]]; then
        nap=$((settle_seconds - waited))
    fi
    sleep "$nap"
    waited=$((waited + nap))
done
echo "Settled after ${waited}s (mau_distinct=$mau_now, m2m_published=$m2m_now)."

report="$tmp_dir/report.txt"
overall_status=0
verified_any=false

# Placeholders so the one-line summary is well formed even when only one metric ran.
authenticated="-"
mau_distinct="-"
missing="-"
extra="-"
tokens_issued="-"
m2m_published="-"
m2m_delta="-"

{
    echo "=================================================================="
    echo " WSO2 IS usage-metering verification"
    [[ -n $scenario_label ]] && echo " label            : $scenario_label"
    echo " generated        : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo " month bucket     : $month"
    echo " identity db      : $IDENTITY_DB@$identity_host"
    echo " session db       : $SESSION_DB@$session_host"
    echo " is nodes (logs)  : ${is_hosts:-<none provided>}"
    echo " receiver baseline: $baseline_source"
    echo " settled after    : ${waited}s"
    if [[ -n $missing_table_list ]]; then
        echo " MISSING TABLES   : $missing_table_list"
    fi
    echo "=================================================================="
} >"$report"

# ── MAU ──────────────────────────────────────────────────────────────────────

if [[ $metric == "all" || $metric == "mau" ]]; then
    verified_any=true

    authenticated=$(num_or_zero "$(run_sql_number "$SESSION_DB" "$session_host" "$Q_AUTHENTICATED_USERS")")
    mau_distinct=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_MAU_DISTINCT")")
    mau_rows=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_MAU_ROWS")")
    mau_published=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_MAU_PUBLISHED")")
    mau_logged=$(distinct_mau_log_users)

    run_sql "$SESSION_DB" "$session_host" "$Q_AUTHENTICATED_IDS" | sort -u >"$tmp_dir/authenticated_ids"
    run_sql "$IDENTITY_DB" "$identity_host" "$Q_MAU_IDS" | sort -u >"$tmp_dir/metered_ids"
    comm -23 "$tmp_dir/authenticated_ids" "$tmp_dir/metered_ids" >"$tmp_dir/missing_ids"
    comm -13 "$tmp_dir/authenticated_ids" "$tmp_dir/metered_ids" >"$tmp_dir/extra_ids"
    missing=$(wc -l <"$tmp_dir/missing_ids" | tr -d '[:space:]')
    extra=$(wc -l <"$tmp_dir/extra_ids" | tr -d '[:space:]')

    if [[ $authenticated -gt 0 ]]; then
        mau_accuracy=$(awk -v a="$mau_distinct" -v e="$authenticated" 'BEGIN{printf "%.2f", (a/e)*100}')
    else
        mau_accuracy="n/a"
    fi

    if [[ $authenticated -eq 0 && $mau_distinct -eq 0 ]]; then
        mau_verdict="INCONCLUSIVE (no user authentications in this scenario)"
    elif [[ $authenticated -eq 0 ]]; then
        mau_verdict="FAIL (metered $mau_distinct users but none authenticated - over-count)"
        overall_status=1
    elif [[ $missing -eq 0 && $extra -eq 0 ]]; then
        mau_verdict="PASS (exact set match)"
    else
        deviation=$(awk -v m="$missing" -v x="$extra" -v e="$authenticated" \
            'BEGIN{printf "%.4f", ((m+x)/e)*100}')
        if awk -v d="$deviation" -v t="$tolerance_percent" 'BEGIN{exit !(d<=t)}'; then
            mau_verdict="WARN (deviation ${deviation}% within tolerance ${tolerance_percent}%)"
        else
            mau_verdict="FAIL (deviation ${deviation}% exceeds tolerance ${tolerance_percent}%)"
            overall_status=1
        fi
    fi

    {
        echo ""
        echo " MAU  (distinct users authenticated in month $month)"
        echo " -----------------------------------------------------------------"
        printf "  1. authenticated   %-42s : %s\n" "SESSION_DB.IDN_AUTH_USER_SESSION_MAPPING" "$authenticated"
        printf "  2. recorded (log)  %-42s : %s\n" "IS log '[MAU] Recorded login' (distinct)" "$mau_logged"
        printf "  3. flushed to DB   %-42s : %s  (rows: %s)\n" "IDENTITY_DB.IDN_MAU_COUNT" "$mau_distinct" "$mau_rows"
        printf "  4. published       %-42s : %s\n" "IDENTITY_DB.USAGE_COUNT type=MAU (latest)" "$mau_published"
        echo ""
        printf "  missing (authenticated, not metered) : %s\n" "$missing"
        printf "  extra   (metered, not authenticated) : %s\n" "$extra"
        printf "  stage-3 accuracy                     : %s%%\n" "$mau_accuracy"
        printf "  VERDICT: %s\n" "$mau_verdict"
    } >>"$report"

    if [[ $missing -gt 0 ]]; then
        {
            echo "  sample missing user ids:"
            head -5 "$tmp_dir/missing_ids" | sed 's/^/    /'
        } >>"$report"
    fi
    if [[ $extra -gt 0 ]]; then
        {
            echo "  sample extra user ids:"
            head -5 "$tmp_dir/extra_ids" | sed 's/^/    /'
        } >>"$report"
    fi

    # A wrong month bucket looks identical to "nothing was metered"; make it obvious.
    if [[ $mau_rows -eq 0 && $authenticated -gt 0 ]]; then
        buckets=$(run_sql "$IDENTITY_DB" "$identity_host" \
            "SELECT CONCAT(MONTH_YEAR,'=',COUNT(*)) FROM IDN_MAU_COUNT GROUP BY MONTH_YEAR" | paste -sd' ' -)
        {
            echo "  NOTE: no rows for month $month. Buckets present in IDN_MAU_COUNT: ${buckets:-<table empty>}"
        } >>"$report"
    fi
fi

# ── M2M ──────────────────────────────────────────────────────────────────────

if [[ $metric == "all" || $metric == "m2m" ]]; then
    verified_any=true

    tokens_issued=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_CC_TOKENS")")
    m2m_published_total=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_M2M_PUBLISHED")")
    m2m_publish_rows=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_M2M_PUBLISH_ROWS")")
    m2m_daily_total=$(num_or_zero "$(run_sql_number "$IDENTITY_DB" "$identity_host" "$Q_M2M_DAILY")")
    # Scenario-scoped values: the receiver's rows accumulate across scenarios.
    m2m_published=$((m2m_published_total - m2m_baseline))
    m2m_daily=$((m2m_daily_total - m2m_daily_baseline))

    m2m_incremented_pair=$(sum_over_is_nodes "grep -c '\[M2M\] Incremented' $CARBON_LOG 2>/dev/null")
    m2m_incremented="${m2m_incremented_pair%%|*}"
    m2m_incremented_by_node="${m2m_incremented_pair#*|}"
    m2m_drained_pair=$(published_from_logs "M2M_TOKEN")
    m2m_drained="${m2m_drained_pair%%|*}"
    m2m_drained_by_node="${m2m_drained_pair#*|}"

    if [[ $tokens_issued -gt 0 ]]; then
        m2m_accuracy=$(awk -v a="$m2m_published" -v e="$tokens_issued" 'BEGIN{printf "%.2f", (a/e)*100}')
    else
        m2m_accuracy="n/a"
    fi
    m2m_delta=$((m2m_published - tokens_issued))

    if [[ $tokens_issued -eq 0 && $m2m_published -eq 0 ]]; then
        m2m_verdict="INCONCLUSIVE (no client_credentials tokens issued in this scenario)"
    elif [[ $tokens_issued -eq 0 ]]; then
        m2m_verdict="FAIL (counted $m2m_published tokens but none were issued - over-count)"
        overall_status=1
    elif [[ $m2m_delta -eq 0 ]]; then
        m2m_verdict="PASS (exact match)"
    else
        deviation=$(awk -v d="$m2m_delta" -v e="$tokens_issued" 'BEGIN{printf "%.4f", (d<0?-d:d)/e*100}')
        if awk -v d="$deviation" -v t="$tolerance_percent" 'BEGIN{exit !(d<=t)}'; then
            m2m_verdict="WARN (deviation ${deviation}% within tolerance ${tolerance_percent}%)"
        else
            m2m_verdict="FAIL (deviation ${deviation}% exceeds tolerance ${tolerance_percent}%)"
            overall_status=1
        fi
    fi

    {
        echo ""
        echo " M2M_TOKEN  (new client_credentials access tokens)"
        echo " -----------------------------------------------------------------"
        printf "  1. tokens issued   %-42s : %s\n" "IDENTITY_DB.IDN_OAUTH2_ACCESS_TOKEN" "$tokens_issued"
        printf "  2. handler counted %-42s : %s   [%s]\n" "IS log '[M2M] Incremented'" "$m2m_incremented" "${m2m_incremented_by_node% }"
        printf "  3. collector drained %-40s : %s   [%s]\n" "IS log 'usage count: type=M2M_TOKEN'" "$m2m_drained" "${m2m_drained_by_node% }"
        printf "  4. receiver stored %-42s : %s  (table total: %s, rows: %s)\n" "IDENTITY_DB.USAGE_COUNT type=M2M_TOKEN" "$m2m_published" "$m2m_published_total" "$m2m_publish_rows"
        printf "     aggregated       %-42s : %s\n" "IDENTITY_DB.DAILY_USAGE_COUNT type=M2M_TOKEN" "$m2m_daily"
        echo ""
        printf "  delta (stage 4 - stage 1)            : %s\n" "$m2m_delta"
        printf "  stage-4 accuracy                     : %s%%\n" "$m2m_accuracy"
        printf "  VERDICT: %s\n" "$m2m_verdict"
    } >>"$report"

    if [[ $tokens_issued -gt 0 && $m2m_published -le 0 ]]; then
        {
            echo "  NOTE: the receiver stored nothing for this scenario. Either the collector cycle"
            echo "        (usage_tracking.usage_count_collector.interval_seconds) has not"
            echo "        elapsed yet, or the receiver is not persisting. Compare with"
            echo "        stage 3 to tell those apart."
        } >>"$report"
    fi
fi

echo "==================================================================" >>"$report"
if [[ $verified_any == true && $overall_status -eq 0 ]]; then
    overall_text="OK"
    echo " RESULT: OK" >>"$report"
else
    overall_text="MISMATCH"
    echo " RESULT: MISMATCH - see the stage that first diverges above." >>"$report"
fi
echo "==================================================================" >>"$report"

if [[ -n $summary_file ]]; then
    if [[ ! -f $summary_file ]]; then
        printf '%-66s | %-38s | %-32s | %s\n' \
            "scenario / users / heap" "MAU (truth/metered/missing/extra)" "M2M (truth/metered/delta)" "result" \
            >"$summary_file"
    fi
    printf '%-66s | %10s /%8s /%7s /%6s | %11s /%9s /%8s | %s\n' \
        "${scenario_label:-unlabelled}" \
        "$authenticated" "$mau_distinct" "$missing" "$extra" \
        "$tokens_issued" "$m2m_published" "$m2m_delta" \
        "$overall_text" >>"$summary_file"
fi

cat "$report"
if [[ -n $out_file ]]; then
    cp "$report" "$out_file"
    echo "Report written to $out_file"
fi

if [[ $verified_any != true ]]; then
    exit 3
fi
exit "$overall_status"
