#!/usr/bin/env bash
#
# gcp_billing_query.sh — Query GCP daily billing data via BigQuery
#
# Usage:
#   ./gcp_billing_query.sh [OPTIONS]
#
# Options:
#   --project PROJECT_ID        GCP project ID (default: gcloud config)
#   --dataset DATASET           BigQuery billing export dataset (default: auto-detect)
#   --billing-account ACCOUNT   Billing account ID (default: auto-detect)
#   --date YYYY-MM-DD           Target date (default: yesterday)
#   --output DIR                Save report to directory
#   --format table|json|md      Output format (default: md)
#   --compare                   Include previous day comparison
#   -h, --help                  Show this help
#

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────
PROJECT_ID=""
DATASET=""
BILLING_ACCOUNT=""
TARGET_DATE=""
OUTPUT_DIR=""
FORMAT="md"
COMPARE=true

# ─── Parse Arguments ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT_ID="$2"; shift 2 ;;
    --dataset)        DATASET="$2"; shift 2 ;;
    --billing-account) BILLING_ACCOUNT="$2"; shift 2 ;;
    --date)           TARGET_DATE="$2"; shift 2 ;;
    --output)         OUTPUT_DIR="$2"; shift 2 ;;
    --format)         FORMAT="$2"; shift 2 ;;
    --compare)        COMPARE=true; shift ;;
    --no-compare)     COMPARE=false; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Preflight Checks ──────────────────────────────────────────────────
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is not installed." >&2
    echo "Install Google Cloud SDK: https://cloud.google.com/sdk/docs/install" >&2
    exit 1
  fi
}

check_command gcloud
check_command bq
check_command jq

# Check authentication
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  echo "ERROR: No active gcloud account. Run 'gcloud auth login' first." >&2
  exit 1
fi
echo "Authenticated as: $ACTIVE_ACCOUNT" >&2

# ─── Resolve Parameters ────────────────────────────────────────────────
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT_ID" ]]; then
    echo "ERROR: No project ID. Use --project or 'gcloud config set project PROJECT_ID'" >&2
    exit 1
  fi
fi
echo "Project: $PROJECT_ID" >&2

if [[ -z "$TARGET_DATE" ]]; then
  # Default to yesterday (billing data has ~24h delay)
  if [[ "$(uname)" == "Darwin" ]]; then
    TARGET_DATE=$(date -v-1d +%Y-%m-%d)
  else
    TARGET_DATE=$(date -d "yesterday" +%Y-%m-%d)
  fi
fi
echo "Target date: $TARGET_DATE" >&2

# ─── Resolve Billing Account ───────────────────────────────────────────
if [[ -z "$BILLING_ACCOUNT" ]]; then
  BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" \
    --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)
  if [[ -z "$BILLING_ACCOUNT" ]]; then
    echo "ERROR: Cannot determine billing account for project $PROJECT_ID" >&2
    echo "Use --billing-account ACCOUNT_ID" >&2
    exit 1
  fi
fi
BILLING_ACCOUNT_CLEAN=$(echo "$BILLING_ACCOUNT" | tr '-' '_' | tr '[:upper:]' '[:lower:]')
echo "Billing account: $BILLING_ACCOUNT" >&2

# ─── Auto-detect BigQuery Dataset ───────────────────────────────────────
if [[ -z "$DATASET" ]]; then
  echo "Auto-detecting billing export dataset..." >&2
  # Look for common billing export table patterns
  DATASETS=$(bq ls --project_id="$PROJECT_ID" --format=json 2>/dev/null || echo "[]")
  for ds in $(echo "$DATASETS" | jq -r '.[].datasetReference.datasetId'); do
    TABLE_CHECK=$(bq ls --project_id="$PROJECT_ID" "$ds" 2>/dev/null | grep -c "gcp_billing_export" || true)
    if [[ "$TABLE_CHECK" -gt 0 ]]; then
      DATASET="$ds"
      echo "Found billing export in dataset: $DATASET" >&2
      break
    fi
  done

  if [[ -z "$DATASET" ]]; then
    echo "ERROR: No BigQuery billing export dataset found." >&2
    echo "Set up billing export: https://cloud.google.com/billing/docs/how-to/export-data-bigquery" >&2
    echo "Or specify with --dataset DATASET_NAME" >&2
    exit 1
  fi
fi

# ─── Detect Billing Table ──────────────────────────────────────────────
BILLING_TABLE=$(bq ls --project_id="$PROJECT_ID" "$DATASET" --format=json 2>/dev/null \
  | jq -r '.[].tableReference.tableId' \
  | grep "gcp_billing_export" \
  | head -1 || true)

if [[ -z "$BILLING_TABLE" ]]; then
  # Try standard naming convention
  BILLING_TABLE="gcp_billing_export_v1_${BILLING_ACCOUNT_CLEAN}"
fi

FULL_TABLE="${PROJECT_ID}.${DATASET}.${BILLING_TABLE}"
echo "Billing table: $FULL_TABLE" >&2

# ─── Query Billing Data ────────────────────────────────────────────────
if [[ "$COMPARE" == true ]]; then
  PREV_DATE=""
  if [[ "$(uname)" == "Darwin" ]]; then
    PREV_DATE=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" -v-1d +%Y-%m-%d)
  else
    PREV_DATE=$(date -d "$TARGET_DATE - 1 day" +%Y-%m-%d)
  fi

  QUERY="
SELECT
  DATE(usage_start_time) AS date,
  service.description AS service_name,
  ROUND(SUM(cost), 4) AS total_cost,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 4) AS total_credits,
  currency
FROM \`${FULL_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN '${PREV_DATE}' AND '${TARGET_DATE}'
GROUP BY date, service_name, currency
HAVING total_cost + total_credits != 0
ORDER BY date DESC, total_cost DESC
"
else
  QUERY="
SELECT
  service.description AS service_name,
  ROUND(SUM(cost), 4) AS total_cost,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 4) AS total_credits,
  currency
FROM \`${FULL_TABLE}\`
WHERE DATE(usage_start_time) = '${TARGET_DATE}'
GROUP BY service_name, currency
HAVING total_cost + total_credits != 0
ORDER BY total_cost DESC
"
fi

echo "Running billing query..." >&2
RAW_RESULT=$(bq query --use_legacy_sql=false --format=json --max_rows=1000 "$QUERY" 2>/dev/null)

if [[ -z "$RAW_RESULT" || "$RAW_RESULT" == "[]" ]]; then
  echo "WARNING: No billing data found for $TARGET_DATE." >&2
  echo "Billing data may have a 24-48 hour delay." >&2
  exit 0
fi

# ─── Format Output ──────────────────────────────────────────────────────
generate_markdown() {
  local data="$1"
  local date="$2"
  local project="$3"
  local account="$4"

  # Get currency
  CURRENCY=$(echo "$data" | jq -r '.[0].currency // "USD"')

  # Today's data
  TODAY_DATA=$(echo "$data" | jq -r --arg d "$date" '[.[] | select(.date == $d or .date == null)]')
  TOTAL_COST=$(echo "$TODAY_DATA" | jq '[.[].total_cost | tonumber] | add // 0 | . * 100 | round / 100')
  TOTAL_CREDITS=$(echo "$TODAY_DATA" | jq '[.[].total_credits | tonumber] | add // 0 | . * 100 | round / 100')
  NET_COST=$(echo "$TOTAL_COST $TOTAL_CREDITS" | awk '{printf "%.2f", $1 + $2}')

  echo "# GCP Daily Billing Report"
  echo ""
  echo "**Project:** \`$project\`"
  echo "**Date:** $date"
  echo "**Billing Account:** \`$account\`"
  echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
  echo "## Cost Breakdown by Service"
  echo ""

  if [[ "$COMPARE" == true ]]; then
    echo "| Service | Cost ($CURRENCY) | Credits | Net Cost | vs Previous Day |"
    echo "|---------|-----------------|---------|----------|----------------|"

    # Build comparison data
    PREV_DATE_VAL=""
    if [[ "$(uname)" == "Darwin" ]]; then
      PREV_DATE_VAL=$(date -j -f "%Y-%m-%d" "$date" -v-1d +%Y-%m-%d)
    else
      PREV_DATE_VAL=$(date -d "$date - 1 day" +%Y-%m-%d)
    fi

    echo "$TODAY_DATA" | jq -r '
      sort_by(-.total_cost | tonumber) | .[] |
      "\(.service_name)\t\(.total_cost)\t\(.total_credits)"
    ' | while IFS=$'\t' read -r svc cost credits; do
      net=$(echo "$cost $credits" | awk '{printf "%.2f", $1 + $2}')
      # Find previous day cost for this service
      prev_cost=$(echo "$data" | jq -r --arg d "$PREV_DATE_VAL" --arg s "$svc" '
        [.[] | select(.date == $d and .service_name == $s)] | .[0].total_cost // "0"
      ')
      prev_credits=$(echo "$data" | jq -r --arg d "$PREV_DATE_VAL" --arg s "$svc" '
        [.[] | select(.date == $d and .service_name == $s)] | .[0].total_credits // "0"
      ')
      prev_net=$(echo "$prev_cost $prev_credits" | awk '{printf "%.2f", $1 + $2}')
      diff=$(echo "$net $prev_net" | awk '{printf "%.2f", $1 - $2}')
      if (( $(echo "$prev_net > 0" | bc -l 2>/dev/null || echo 0) )); then
        pct=$(echo "$diff $prev_net" | awk '{if ($2 != 0) printf "%.0f", ($1/$2)*100; else print "—"}')
        if (( $(echo "$diff > 0" | bc -l 2>/dev/null || echo 0) )); then
          change="+\$${diff} (↑ ${pct}%)"
        elif (( $(echo "$diff < 0" | bc -l 2>/dev/null || echo 0) )); then
          change="\$${diff} (↓ ${pct#-}%)"
        else
          change="\$0.00 (—)"
        fi
      else
        if (( $(echo "$net > 0" | bc -l 2>/dev/null || echo 0) )); then
          change="NEW"
        else
          change="—"
        fi
      fi
      printf "| %s | \$%s | \$%s | \$%s | %s |\n" "$svc" "$cost" "$credits" "$net" "$change"
    done
  else
    echo "| Service | Cost ($CURRENCY) | Credits | Net Cost |"
    echo "|---------|-----------------|---------|----------|"
    echo "$TODAY_DATA" | jq -r '
      sort_by(-.total_cost | tonumber) | .[] |
      "\(.service_name)\t\(.total_cost)\t\(.total_credits)"
    ' | while IFS=$'\t' read -r svc cost credits; do
      net=$(echo "$cost $credits" | awk '{printf "%.2f", $1 + $2}')
      printf "| %s | \$%s | \$%s | \$%s |\n" "$svc" "$cost" "$credits" "$net"
    done
  fi

  echo ""
  echo "## Summary"
  echo ""
  echo "- **Total Cost:** \$${TOTAL_COST} ${CURRENCY}"
  echo "- **Total Credits:** \$${TOTAL_CREDITS} ${CURRENCY}"
  echo "- **Net Cost:** \$${NET_COST} ${CURRENCY}"

  if [[ "$COMPARE" == true ]]; then
    PREV_TOTAL=$(echo "$data" | jq -r --arg d "$PREV_DATE_VAL" '
      [.[] | select(.date == $d) | .total_cost | tonumber] | add // 0 | . * 100 | round / 100
    ')
    PREV_CREDITS_TOTAL=$(echo "$data" | jq -r --arg d "$PREV_DATE_VAL" '
      [.[] | select(.date == $d) | .total_credits | tonumber] | add // 0 | . * 100 | round / 100
    ')
    PREV_NET=$(echo "$PREV_TOTAL $PREV_CREDITS_TOTAL" | awk '{printf "%.2f", $1 + $2}')
    TOTAL_DIFF=$(echo "$NET_COST $PREV_NET" | awk '{printf "%.2f", $1 - $2}')
    echo "- **Previous Day Net:** \$${PREV_NET} ${CURRENCY}"
    echo "- **Day-over-Day Change:** \$${TOTAL_DIFF} ${CURRENCY}"
  fi

  echo ""
  echo "## Top Cost Drivers"
  echo ""
  echo "$TODAY_DATA" | jq -r --arg total "$TOTAL_COST" '
    sort_by(-.total_cost | tonumber) | .[0:5] | to_entries[] |
    "\(.key + 1). **\(.value.service_name)** — $\(.value.total_cost) (\(
      if ($total | tonumber) > 0
      then ((.value.total_cost | tonumber) / ($total | tonumber) * 100 | round | tostring) + "%"
      else "0%"
      end
    ) of total)"
  '

  # Alerts
  if [[ "$COMPARE" == true ]]; then
    echo ""
    echo "## Alerts"
    echo ""
    ALERTS=$(echo "$TODAY_DATA" | jq -r --arg prev_date "$PREV_DATE_VAL" --argjson all_data "$data" '
      [.[] | . as $today |
        ($all_data | [.[] | select(.date == $prev_date and .service_name == $today.service_name)] | .[0]) as $prev |
        if $prev then
          (($today.total_cost | tonumber) - ($prev.total_cost | tonumber)) as $diff |
          if ($prev.total_cost | tonumber) > 0 then
            ($diff / ($prev.total_cost | tonumber) * 100) as $pct |
            if $pct > 20 then
              "⚠️ **\($today.service_name)** cost increased by \($pct | round)% ($\($prev.total_cost) → $\($today.total_cost))"
            else empty end
          else empty end
        else empty end
      ] | if length == 0 then ["✅ No significant cost anomalies detected."] else . end | .[]
    ')
    echo "$ALERTS"
  fi
}

generate_json() {
  local data="$1"
  echo "$data" | jq --arg date "$TARGET_DATE" --arg project "$PROJECT_ID" --arg account "$BILLING_ACCOUNT" '{
    report: {
      project: $project,
      date: $date,
      billing_account: $account,
      generated_at: (now | todate),
      services: [.[] | {
        service: .service_name,
        date: (.date // $date),
        cost: (.total_cost | tonumber),
        credits: (.total_credits | tonumber),
        net_cost: ((.total_cost | tonumber) + (.total_credits | tonumber)),
        currency: .currency
      }],
      total_cost: ([.[] | select(.date == $date or .date == null) | .total_cost | tonumber] | add // 0),
      total_credits: ([.[] | select(.date == $date or .date == null) | .total_credits | tonumber] | add // 0)
    }
  }'
}

generate_table() {
  local data="$1"
  local date="$2"

  CURRENCY=$(echo "$data" | jq -r '.[0].currency // "USD"')

  printf "\n%-40s %12s %12s %12s\n" "SERVICE" "COST" "CREDITS" "NET ($CURRENCY)"
  printf "%-40s %12s %12s %12s\n" "$(printf '%.0s─' {1..40})" "$(printf '%.0s─' {1..12})" "$(printf '%.0s─' {1..12})" "$(printf '%.0s─' {1..12})"

  echo "$data" | jq -r --arg d "$date" '
    [.[] | select(.date == $d or .date == null)] |
    sort_by(-.total_cost | tonumber) | .[] |
    "\(.service_name)\t\(.total_cost)\t\(.total_credits)"
  ' | while IFS=$'\t' read -r svc cost credits; do
    net=$(echo "$cost $credits" | awk '{printf "%.2f", $1 + $2}')
    printf "%-40s %12s %12s %12s\n" "$svc" "\$$cost" "\$$credits" "\$$net"
  done

  TOTAL=$(echo "$data" | jq -r --arg d "$date" '
    [.[] | select(.date == $d or .date == null) | .total_cost | tonumber] | add // 0 | . * 100 | round / 100
  ')
  CRED=$(echo "$data" | jq -r --arg d "$date" '
    [.[] | select(.date == $d or .date == null) | .total_credits | tonumber] | add // 0 | . * 100 | round / 100
  ')
  NET=$(echo "$TOTAL $CRED" | awk '{printf "%.2f", $1 + $2}')

  printf "%-40s %12s %12s %12s\n" "$(printf '%.0s─' {1..40})" "$(printf '%.0s─' {1..12})" "$(printf '%.0s─' {1..12})" "$(printf '%.0s─' {1..12})"
  printf "%-40s %12s %12s %12s\n" "TOTAL" "\$$TOTAL" "\$$CRED" "\$$NET"
  echo ""
}

# ─── Generate Output ────────────────────────────────────────────────────
case "$FORMAT" in
  md|markdown)
    OUTPUT=$(generate_markdown "$RAW_RESULT" "$TARGET_DATE" "$PROJECT_ID" "$BILLING_ACCOUNT")
    ;;
  json)
    OUTPUT=$(generate_json "$RAW_RESULT")
    ;;
  table)
    OUTPUT=$(generate_table "$RAW_RESULT" "$TARGET_DATE")
    ;;
  *)
    echo "ERROR: Unknown format '$FORMAT'. Use: md, json, table" >&2
    exit 1
    ;;
esac

echo "$OUTPUT"

# ─── Save to File ──────────────────────────────────────────────────────
if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  case "$FORMAT" in
    md|markdown) EXT="md" ;;
    json)        EXT="json" ;;
    table)       EXT="txt" ;;
  esac
  OUTFILE="${OUTPUT_DIR}/billing-${TARGET_DATE}.${EXT}"
  echo "$OUTPUT" > "$OUTFILE"
  echo "Report saved to: $OUTFILE" >&2
fi
