#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PROJECT_ID=${PROJECT_ID:?}
REGION=${REGION:?}
JOB_NAME=${JOB_NAME:-dbt-prod}
SCHED_JOB_NAME=${SCHED_JOB_NAME:-dbt-prod-nightly}
CHANNELS=${NOTIFICATION_CHANNELS:-}

ensure_log_metric() {
  local name="$1" filter="$2" desc="$3"
  if gcloud logging metrics describe "$name" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Log metric exists: $name"
  else
    echo "Creating log metric: $name"
    gcloud logging metrics create "$name" --description="$desc" --log-filter="$filter" --project "$PROJECT_ID"
  fi
}

metric_policy_json() {
  local display="$1" metric="$2" alignment="$3" per_series="$4" comparison="$5" threshold="$6" duration="$7"
  cat <<JSON
{
  "displayName": "$display",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "$display condition",
      "conditionThreshold": {
        "filter": "metric.type=\"logging.googleapis.com/user/${metric}\" resource.type=\"global\"",
        "aggregations": [
          {"alignmentPeriod": "$alignment", "perSeriesAligner": "$per_series"}
        ],
        "comparison": "$comparison",
        "thresholdValue": $threshold,
        "duration": "$duration"
      }
    }
  ]
}
JSON
}

ensure_policy() {
  local name="$1" file="$2"
  if gcloud monitoring policies list --format="value(displayName)" --project "$PROJECT_ID" | grep -Fx "$name" >/dev/null 2>&1; then
    echo "Policy exists: $name"
  else
    echo "Creating policy: $name"
    if [[ -n "$CHANNELS" ]]; then
      gcloud monitoring policies create --policy-from-file="$file" --notification-channels="$CHANNELS" --project "$PROJECT_ID"
    else
      gcloud monitoring policies create --policy-from-file="$file" --project "$PROJECT_ID"
    fi
  fi
}

# Metrics
ensure_log_metric "cloud_run_job_errors" \
  "resource.type=\"cloud_run_job\" severity>=ERROR resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\"" \
  "Errors from Cloud Run Job ${JOB_NAME}"

ensure_log_metric "cloud_scheduler_job_errors" \
  "resource.type=\"cloud_scheduler_job\" severity>=ERROR resource.labels.location=\"${REGION}\" resource.labels.job_id=\"${SCHED_JOB_NAME}\"" \
  "Errors from Cloud Scheduler job ${SCHED_JOB_NAME}"

ensure_log_metric "bigquery_job_errors" \
  "resource.type=\"bigquery_project\" severity>=ERROR" \
  "BigQuery job errors in project"

TMP=$(mktemp)

# Policies (count > 0 over 5m)
metric_policy_json "Cloud Run Job Errors (${JOB_NAME})" "cloud_run_job_errors" "300s" "ALIGN_RATE" "COMPARISON_GT" 0 "0s" > "$TMP"
ensure_policy "Cloud Run Job Errors (${JOB_NAME})" "$TMP"

metric_policy_json "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "cloud_scheduler_job_errors" "300s" "ALIGN_RATE" "COMPARISON_GT" 0 "0s" > "$TMP"
ensure_policy "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "$TMP"

metric_policy_json "BigQuery Job Errors" "bigquery_job_errors" "300s" "ALIGN_RATE" "COMPARISON_GT" 0 "0s" > "$TMP"
ensure_policy "BigQuery Job Errors" "$TMP"

rm -f "$TMP"
echo "Monitoring alerts ensured."

