#!/usr/bin/env bash
set -euo pipefail

echo "Starting container at $(date -Is)"
echo "DBT_TARGET=${DBT_TARGET:-prod}"

if [[ "${RUN_PRE_HOOK:-false}" == "true" ]]; then
  echo "Running pre_run.py ..."
  python hooks/pre_run.py
fi

dbt deps

DBT_BUILD_ARGS="${DBT_BUILD_ARGS:-}"
echo "dbt build --target ${DBT_TARGET} ${DBT_BUILD_ARGS}"
dbt build --target "${DBT_TARGET}" ${DBT_BUILD_ARGS}

if [[ "${GENERATE_DOCS:-false}" == "true" ]]; then
  dbt docs generate --static
  echo "Docs generated at ./target/index.html"
  if [[ -n "${DOCS_BUCKET_NAME:-}" ]]; then
    echo "Uploading docs to gs://${DOCS_BUCKET_NAME}/index.html"
    python - << 'PY'
import os
from google.cloud import storage

bucket_name = os.environ["DOCS_BUCKET_NAME"]
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
  echo "Uploading manifest.json and run_results.json to gs://${DBT_ARTIFACTS_BUCKET}/prod/"
  python - << 'PY'
import os
from google.cloud import storage

bucket_name = os.environ["DBT_ARTIFACTS_BUCKET"]
client = storage.Client()
bucket = client.bucket(bucket_name)
for name in ("manifest.json", "run_results.json"):
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
