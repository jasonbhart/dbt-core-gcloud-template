#!/usr/bin/env bash
set -euo pipefail

mkdir -p prod_state
HAS_STATE="false"
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]] && gsutil ls "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" >/dev/null 2>&1; then
  gsutil cp "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" prod_state/manifest.json
  HAS_STATE="true"
  echo "Pulled prod manifest for Slim CI defer"
fi

dbt deps
if [[ "${HAS_STATE}" == "true" ]]; then
  dbt build --target ci --select "state:modified+" --defer --state prod_state
else
  dbt build --target ci
fi

