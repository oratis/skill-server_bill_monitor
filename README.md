# server-bill-monitor

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that generates daily Google Cloud Platform billing reports. It queries your GCP billing data via BigQuery and summarizes costs by service, highlights trends, and flags anomalies.

## Features

- **Daily cost breakdown** by GCP service (Compute Engine, Cloud Storage, BigQuery, etc.)
- **Day-over-day comparison** with percentage change indicators
- **Credits tracking** (sustained use discounts, committed use discounts, free tier)
- **Anomaly detection** — flags services with >20% cost increase
- **Multiple output formats** — Markdown, JSON, or ASCII table
- **Auto-detection** of BigQuery billing export dataset and billing account
- **Schedulable** — pair with Claude Code's `/schedule` for daily automated reports

## Prerequisites

1. **Google Cloud SDK** (`gcloud` + `bq`) installed and authenticated
2. **BigQuery Billing Export** enabled in your GCP project
3. **jq** installed for JSON processing
4. IAM role: `roles/billing.viewer` and `roles/bigquery.dataViewer`

### Setting up BigQuery Billing Export

If you haven't set up billing export yet:

1. Go to [GCP Console → Billing → Billing export](https://console.cloud.google.com/billing/export)
2. Select the **BigQuery Export** tab
3. Choose or create a dataset (e.g., `billing_export`)
4. Enable **Standard usage cost** export
5. Wait 24-48 hours for initial data to populate

## Installation

### Option 1: Clone into Claude Code skills directory

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/server-bill-monitor.git

# Copy skill to Claude Code skills directory
cp -r server-bill-monitor/skills/server-bill-monitor ~/.claude/skills/
```

### Option 2: Install as a plugin

Add to your Claude Code settings (`.claude/settings.json`):

```json
{
  "plugins": [
    {
      "path": "/path/to/server-bill-monitor"
    }
  ]
}
```

### Option 3: Use directly with the helper script

```bash
git clone https://github.com/YOUR_USERNAME/server-bill-monitor.git
cd server-bill-monitor
./skills/server-bill-monitor/scripts/gcp_billing_query.sh --project my-project
```

## Usage

### In Claude Code (as a skill)

Simply ask Claude about your cloud billing:

```
> What's my GCP bill for today?

> Show me yesterday's cloud costs broken down by service

> Generate a billing report for 2025-03-15

> How much am I spending on Compute Engine?
```

Or invoke directly with the slash command:

```
> /server-bill-monitor

> /server-bill-monitor --project my-project --date 2025-03-15

> /server-bill-monitor --format json
```

### Standalone Script

```bash
# Basic usage (auto-detects project, uses yesterday's date)
./scripts/gcp_billing_query.sh

# Specify project and date
./scripts/gcp_billing_query.sh --project my-gcp-project --date 2025-03-15

# JSON output saved to file
./scripts/gcp_billing_query.sh --format json --output ./reports/

# Table format for terminal
./scripts/gcp_billing_query.sh --format table

# Specify BigQuery dataset explicitly
./scripts/gcp_billing_query.sh --dataset billing_export --billing-account 012345-6789AB-CDEF01

# Without day-over-day comparison
./scripts/gcp_billing_query.sh --no-compare
```

### Schedule Daily Reports

#### With Claude Code `/schedule`

```
> /schedule "Run /server-bill-monitor every day at 9am"
```

#### With cron

```bash
# Edit crontab
crontab -e

# Add daily 9am report
0 9 * * * /path/to/gcp_billing_query.sh --project my-project --output /path/to/reports/ 2>&1
```

## Example Output

### Markdown Report

```markdown
# GCP Daily Billing Report

**Project:** `my-project`
**Date:** 2025-03-15
**Billing Account:** `012345-6789AB-CDEF01`
**Generated:** 2025-03-16 09:00:15 UTC

## Cost Breakdown by Service

| Service                | Cost (USD)  | Credits  | Net Cost | vs Previous Day      |
|------------------------|-------------|----------|----------|----------------------|
| Compute Engine         | $45.23      | $-5.00   | $40.23   | +$3.21 (↑ 9%)       |
| Cloud Storage          | $12.87      | $0.00    | $12.87   | -$1.02 (↓ 7%)       |
| BigQuery               | $8.45       | $-2.00   | $6.45    | $0.00 (—)           |
| Cloud SQL              | $6.12       | $0.00    | $6.12    | +$4.10 (↑ 203%)     |
| Networking             | $3.21       | $0.00    | $3.21    | +$0.15 (↑ 5%)       |

## Summary

- **Total Cost:** $75.88 USD
- **Total Credits:** $-7.00 USD
- **Net Cost:** $68.88 USD
- **Previous Day Net:** $62.44 USD
- **Day-over-Day Change:** $6.44 USD

## Top Cost Drivers

1. **Compute Engine** — $45.23 (60% of total)
2. **Cloud Storage** — $12.87 (17% of total)
3. **BigQuery** — $8.45 (11% of total)

## Alerts

⚠️ **Cloud SQL** cost increased by 203% ($2.02 → $6.12)
```

### JSON Output

```json
{
  "report": {
    "project": "my-project",
    "date": "2025-03-15",
    "billing_account": "012345-6789AB-CDEF01",
    "services": [
      {
        "service": "Compute Engine",
        "cost": 45.23,
        "credits": -5.00,
        "net_cost": 40.23,
        "currency": "USD"
      }
    ],
    "total_cost": 75.88,
    "total_credits": -7.00
  }
}
```

## Arguments Reference

| Argument | Description | Default |
|----------|-------------|---------|
| `--project PROJECT_ID` | GCP project ID | Current `gcloud` config |
| `--dataset DATASET` | BigQuery billing export dataset | Auto-detected |
| `--billing-account ID` | Billing account ID | Auto-detected from project |
| `--date YYYY-MM-DD` | Target date for the report | Yesterday |
| `--output DIR` | Save report to directory | Display only |
| `--format md\|json\|table` | Output format | `md` |
| `--compare` | Include previous day comparison | Enabled |
| `--no-compare` | Disable day comparison | — |

## Troubleshooting

### "No billing data found"

- GCP billing data has a **12-48 hour delay**. Try a date 2 days ago.
- Verify BigQuery export is enabled and the dataset has data:
  ```bash
  bq ls YOUR_PROJECT:billing_dataset
  ```

### "Cannot determine billing account"

- Check you have `roles/billing.viewer`:
  ```bash
  gcloud billing accounts list
  ```

### "No BigQuery billing export dataset found"

- Set up billing export first (see [Prerequisites](#prerequisites))
- Or specify the dataset manually: `--dataset my_billing_dataset`

### "gcloud is not installed"

- Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install
- Then authenticate: `gcloud auth login`

## Project Structure

```
server-bill-monitor/
├── README.md
├── LICENSE
└── skills/
    └── server-bill-monitor/
        ├── SKILL.md              # Claude Code skill definition
        └── scripts/
            └── gcp_billing_query.sh  # Standalone helper script
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.
