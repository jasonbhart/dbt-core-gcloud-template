#!/usr/bin/env bash
set -euo pipefail

echo "Starting container at $(date -Is)"
echo "DBT_TARGET=${DBT_TARGET:-prod}"

# Ensure profiles dir exists; generate a minimal prod profile if missing
export DBT_PROFILES_DIR="${DBT_PROFILES_DIR:-/app/profiles}"
if [[ ! -d "$DBT_PROFILES_DIR" ]]; then
  echo "Profiles dir not found at $DBT_PROFILES_DIR; creating a minimal prod profile"
  mkdir -p "$DBT_PROFILES_DIR"
  PROJECT_VAL="${DBT_GCP_PROJECT_PROD:-}"
  DATASET_VAL="${DBT_BQ_DATASET_PROD:-analytics}"
  LOCATION_VAL="${DBT_BQ_LOCATION:-US}"
  cat > "$DBT_PROFILES_DIR/profiles.yml" <<YAML
dbt_core_gcloud:
  target: "prod"
  outputs:
    prod:
      type: bigquery
      method: oauth
      project: "${PROJECT_VAL}"
      dataset: "${DATASET_VAL}"
      location: "${LOCATION_VAL}"
      threads: 8
      priority: interactive
      labels: {service: dbt, env: "prod"}
YAML
fi

# Freshness toggle: default true in prod, false otherwise (can override via RUN_FRESHNESS)
if [[ -z "${RUN_FRESHNESS:-}" ]]; then
  if [[ "${DBT_TARGET:-prod}" == "prod" ]]; then
    RUN_FRESHNESS=true
  else
    RUN_FRESHNESS=false
  fi
fi

if [[ "${RUN_PRE_HOOK:-false}" == "true" ]]; then
  echo "Running pre_run.py ..."
  python hooks/pre_run.py
fi

# Use JSON logs for easier parsing in Cloud Logging
dbt --log-format json deps

DBT_BUILD_ARGS="${DBT_BUILD_ARGS:-}"
echo "dbt build --target ${DBT_TARGET} ${DBT_BUILD_ARGS}"
dbt --log-format json build --target "${DBT_TARGET}" ${DBT_BUILD_ARGS}

# Optional source freshness
if [[ "${RUN_FRESHNESS}" == "true" ]]; then
  echo "Running dbt source freshness"
  if [[ -n "${FRESHNESS_SELECT:-}" ]]; then
    dbt --log-format json source freshness --select "${FRESHNESS_SELECT}"
  else
    dbt --log-format json source freshness
  fi
fi

# Emit a one-line JSON summary for alerting/observability
python - << 'PY'
import json, os, sys
path = os.path.join('target','run_results.json')
try:
    with open(path) as f:
        doc = json.load(f)
except Exception as e:
    print(json.dumps({"dbt_summary": {"status": "missing_run_results", "error": str(e)}}))
    sys.exit(0)

results = doc.get('results', [])
status_counts = {}
for r in results:
    s = r.get('status', 'unknown')
    status_counts[s] = status_counts.get(s, 0) + 1

summary = {
    "total": len(results),
    "elapsed": doc.get('elapsed_time'),
    "statuses": status_counts,
}

# Backward-compatible booleans
summary["failed"] = status_counts.get('error', 0) + status_counts.get('fail', 0)
summary["successful"] = status_counts.get('success', 0)

print(json.dumps({"dbt_summary": summary}))
PY

if [[ "${GENERATE_DOCS:-false}" == "true" ]]; then
  dbt docs generate --static
  echo "Docs generated at ./target/index.html"
  # Prefer DOCS_BUCKET_NAME; fall back to DBT_ARTIFACTS_BUCKET if not set
  EXPORT_DOCS_BUCKET="${DOCS_BUCKET_NAME:-${DBT_ARTIFACTS_BUCKET:-}}"
  if [[ -n "${EXPORT_DOCS_BUCKET}" ]]; then
    echo "Uploading docs to gs://${DOCS_BUCKET_NAME}/index.html"
    python - << 'PY'
import os
from google.cloud import storage

bucket_name = os.environ.get("DOCS_BUCKET_NAME") or os.environ.get("DBT_ARTIFACTS_BUCKET")
path = os.path.join("target", "index.html")
client = storage.Client()
bucket = client.bucket(bucket_name)
blob = bucket.blob("index.html")
blob.cache_control = "no-cache"
blob.content_type = "text/html"
with open(path, "rb") as f:
    blob.upload_from_file(f, content_type="text/html")
print(f"Uploaded to gs://{bucket_name}/index.html")
PY
  fi
fi

# Upload core artifacts to artifacts bucket for Slim CI deferral
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]]; then
  echo "Uploading manifest.json, run_results.json, and sources.json (if present) to gs://${DBT_ARTIFACTS_BUCKET}/prod/"
  python - << 'PY'
import os
from google.cloud import storage

bucket_name = os.environ["DBT_ARTIFACTS_BUCKET"]
client = storage.Client()
bucket = client.bucket(bucket_name)
for name in ("manifest.json", "run_results.json", "sources.json"):
    p = os.path.join("target", name)
    if os.path.exists(p):
        blob = bucket.blob(f"prod/{name}")
        blob.cache_control = "no-cache"
        blob.content_type = "application/json"
        with open(p, "rb") as f:
            blob.upload_from_file(f, content_type="application/json")
        print(f"Uploaded gs://{bucket_name}/prod/{name}")
    else:
        print(f"Skipping missing {p}")
PY
fi

if [[ "${RUN_POST_HOOK:-false}" == "true" ]]; then
  echo "Running post_run.py ..."
  python hooks/post_run.py
fi

echo "Completed at $(date -Is)"
