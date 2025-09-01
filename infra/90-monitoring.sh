#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PROJECT_ID=${PROJECT_ID:?}
REGION=${REGION:?}
SCHED_REGION=${SCHED_REGION:-$REGION}
JOB_NAME=${JOB_NAME:-dbt-prod-run}
SCHED_JOB_NAME=${SCHED_JOB_NAME:-dbt-prod-nightly}
CHANNELS=${NOTIFICATION_CHANNELS:-}

# Pick monitoring policies command (beta preferred, else alpha)
pick_policies_cmd() {
  if gcloud beta monitoring policies --help >/dev/null 2>&1; then
    echo "gcloud beta monitoring policies"
  elif gcloud alpha monitoring policies --help >/dev/null 2>&1; then
    echo "gcloud alpha monitoring policies"
  else
    echo ""; return 1
  fi
}

POL_CMD=$(pick_policies_cmd) || { echo "gcloud monitoring policies command not available (alpha/beta)." >&2; exit 2; }

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
  local display="$1" metric="$2" resource_type="$3" alignment="$4" per_series="$5" comparison="$6" threshold="$7" duration="$8"
  cat <<JSON
{
  "displayName": "$display",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "$display condition",
      "conditionThreshold": {
        "filter": "metric.type=\"logging.googleapis.com/user/${metric}\" resource.type=\"${resource_type}\"",
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
  if $POL_CMD list --format="value(displayName)" --project "$PROJECT_ID" | grep -Fx "$name" >/dev/null 2>&1; then
    echo "Policy exists: $name"
  else
    echo "Creating policy: $name"
    if [[ -n "$CHANNELS" ]]; then
      $POL_CMD create --policy-from-file="$file" --notification-channels="$CHANNELS" --project "$PROJECT_ID"
    else
      $POL_CMD create --policy-from-file="$file" --project "$PROJECT_ID"
    fi
  fi
}

# Metrics
ensure_log_metric "cloud_run_job_errors" \
  "resource.type=\"cloud_run_job\" severity>=ERROR resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\"" \
  "Errors from Cloud Run Job ${JOB_NAME} (severity>=ERROR)"

# Capture common failure text even if severity is not elevated
ensure_log_metric "cloud_run_job_failures" \
  "resource.type=\"cloud_run_job\" resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\" (textPayload:(\"Container called exit\" OR \"Execution failed\" OR \"exited with status\") OR jsonPayload.message:(\"Container called exit\" OR \"Execution failed\" OR \"exited with status\"))" \
  "Cloud Run Job ${JOB_NAME} failures (text/json message match)"

ensure_log_metric "cloud_scheduler_job_errors" \
  "resource.type=\"cloud_scheduler_job\" severity>=ERROR resource.labels.location=\"${SCHED_REGION}\" resource.labels.job_id=\"${SCHED_JOB_NAME}\"" \
  "Errors from Cloud Scheduler job ${SCHED_JOB_NAME}"

ensure_log_metric "bigquery_job_errors" \
  "resource.type=\"bigquery_project\" severity>=ERROR" \
  "BigQuery job errors in project"

TMP=$(mktemp)

# Policies (count > 0 over 5m). Use DELTA to count new events in window.
metric_policy_json "Cloud Run Job Errors (${JOB_NAME})" "cloud_run_job_errors" "cloud_run_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Run Job Errors (${JOB_NAME})" "$TMP"

metric_policy_json "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "cloud_scheduler_job_errors" "cloud_scheduler_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "$TMP"

metric_policy_json "BigQuery Job Errors" "bigquery_job_errors" "bigquery_project" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "BigQuery Job Errors" "$TMP"

# Also alert on text-matched job failures
metric_policy_json "Cloud Run Job Failures (${JOB_NAME})" "cloud_run_job_failures" "cloud_run_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Run Job Failures (${JOB_NAME})" "$TMP"

rm -f "$TMP"
echo "Monitoring alerts ensured."
