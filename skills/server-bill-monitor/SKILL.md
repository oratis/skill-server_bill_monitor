---
name: server-bill-monitor
description: >
  Use this skill when the user asks about cloud billing, daily cost reports,
  GCP spending, service cost breakdown, or wants to monitor Google Cloud expenses.
  Trigger phrases: "billing report", "cloud costs", "GCP spending", "daily bill",
  "cost breakdown", "how much am I spending", "server bill".
version: 1.0.0
license: MIT
allowed-tools: [Bash, Read, Write, Glob, Grep]
argument-hint: "[--project PROJECT_ID] [--date YYYY-MM-DD] [--billing-account ACCOUNT_ID] [--format table|json|markdown] [--bigquery DATASET]"
---

# Server Bill Monitor

Generate a daily Google Cloud Platform billing report summarizing costs by service.

## Overview

This skill queries GCP billing data and produces a clear, formatted report showing:
- Per-service cost breakdown for the specified date
- Total daily spend
- Cost trend compared to previous day (when available)
- Top cost drivers highlighted

## Prerequisites

Before running, verify the following:

1. **gcloud CLI** is installed and authenticated (`gcloud auth list`)
2. **Billing account** is accessible (`gcloud billing accounts list`)
3. One of these billing data sources is available:
   - **BigQuery Billing Export** (recommended, most detailed) — user must have a billing export dataset configured
   - **Cloud Billing API** via `gcloud` — works without BigQuery but less granular

Run a quick check:
```bash
gcloud --version && gcloud auth list --filter=status:ACTIVE --format="value(account)"
```

## Workflow

### Phase 1: Environment Check

1. Verify `gcloud` CLI is installed and authenticated
2. Determine the target project ID:
   - Use `--project` argument if provided
   - Otherwise use `gcloud config get-value project`
3. Determine the target date:
   - Use `--date` argument if provided (format: YYYY-MM-DD)
   - Otherwise use yesterday's date (billing data has ~24h delay)
4. Determine billing data source:
   - If `--bigquery DATASET` is provided, use BigQuery export
   - Otherwise, attempt BigQuery first by checking for common billing export datasets
   - Fall back to Cloud Billing API if BigQuery is not available

### Phase 2: Query Billing Data

#### Option A: BigQuery Billing Export (Preferred)

Use the helper script or run directly:

```bash
bq query --use_legacy_sql=false --format=prettyjson "
SELECT
  service.description AS service_name,
  ROUND(SUM(cost), 2) AS total_cost,
  currency
FROM \`PROJECT_ID.DATASET.gcp_billing_export_v1_BILLING_ACCOUNT_ID\`
WHERE DATE(usage_start_time) = 'TARGET_DATE'
GROUP BY service_name, currency
HAVING total_cost > 0
ORDER BY total_cost DESC
"
```

To also get the previous day for comparison:

```bash
bq query --use_legacy_sql=false --format=prettyjson "
SELECT
  DATE(usage_start_time) AS date,
  service.description AS service_name,
  ROUND(SUM(cost), 2) AS total_cost,
  currency
FROM \`PROJECT_ID.DATASET.gcp_billing_export_v1_BILLING_ACCOUNT_ID\`
WHERE DATE(usage_start_time) BETWEEN DATE_SUB('TARGET_DATE', INTERVAL 1 DAY) AND 'TARGET_DATE'
GROUP BY date, service_name, currency
HAVING total_cost > 0
ORDER BY date DESC, total_cost DESC
"
```

#### Option B: Cloud Billing Budgets API Fallback

If BigQuery export is not configured, use the Billing API:

```bash
# List billing accounts
gcloud billing accounts list --format="json"

# List projects linked to a billing account
gcloud billing projects list --billing-account=BILLING_ACCOUNT_ID --format="json"

# Get cost info via gcloud (limited granularity)
gcloud billing accounts describe BILLING_ACCOUNT_ID --format="json"
```

Note: The direct `gcloud billing` commands provide limited daily breakdown.
If detailed per-service daily costs are needed, strongly recommend setting up BigQuery billing export.

#### Option C: Cost Table from Billing Console Export (CSV)

If the user has exported CSV billing data:

```bash
# Parse a billing CSV export
cat billing_export.csv | head -20
```

### Phase 3: Generate Report

Format the billing data into a clear report. Use the format specified by `--format` (default: markdown).

#### Report Template (Markdown)

```markdown
# GCP Daily Billing Report

**Project:** PROJECT_ID
**Date:** TARGET_DATE
**Billing Account:** ACCOUNT_ID

## Cost Breakdown by Service

| Service | Cost (USD) | Change vs Previous Day |
|---------|-----------|----------------------|
| Compute Engine | $XX.XX | +$X.XX (↑ XX%) |
| Cloud Storage | $XX.XX | -$X.XX (↓ XX%) |
| BigQuery | $XX.XX | $0.00 (—) |
| ... | ... | ... |

## Summary

- **Total Daily Cost:** $XXX.XX
- **Previous Day Cost:** $XXX.XX
- **Change:** +/- $XX.XX (↑/↓ XX%)

## Top Cost Drivers

1. **Compute Engine** — $XX.XX (XX% of total)
2. **Cloud Storage** — $XX.XX (XX% of total)
3. **BigQuery** — $XX.XX (XX% of total)

## Alerts

- ⚠️ Services with >20% cost increase flagged above
- ✅ No anomalies detected / ⚠️ Anomalies found: [details]
```

#### Report Template (Table - for terminal)

Use a simple ASCII table format suitable for terminal display.

### Phase 4: Deliver Report

1. Display the report directly to the user in the conversation
2. If the user wants to save it, write to `./billing-reports/YYYY-MM-DD.md`
3. Suggest scheduling via Claude Code's `/schedule` skill for daily automation

## Important Notes

- **Billing data delay**: GCP billing data typically has a 12-24 hour delay. Yesterday's data is the most recent reliable data.
- **Permissions required**: The authenticated account needs `roles/billing.viewer` or `roles/bigquery.dataViewer` on the billing export dataset.
- **Currency**: Report uses the currency from the billing data (usually USD).
- **Free tier**: Some services show $0.00 costs — these are filtered out by default.
- **Costs are estimates**: Reported costs may differ slightly from the final invoice due to credits, sustained use discounts, and committed use discounts being applied later.

## Error Handling

- If `gcloud` is not installed: Provide installation instructions (https://cloud.google.com/sdk/docs/install)
- If not authenticated: Run `gcloud auth login`
- If no billing account access: Guide user to check IAM permissions
- If BigQuery dataset not found: Guide user to set up billing export, fall back to API
- If no data for the target date: Inform user about billing data delay, try previous day

## Scheduling Daily Reports

Suggest the user set up a daily schedule:

```
/schedule "Run /server-bill-monitor every day at 9am to generate yesterday's billing report"
```

Or use the helper script with cron:

```bash
# Add to crontab for daily 9am reports
0 9 * * * /path/to/gcp_billing_query.sh --project MY_PROJECT --output /path/to/reports/
```
