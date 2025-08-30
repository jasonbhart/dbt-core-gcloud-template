#!/usr/bin/env bash
set -euo pipefail

# Generates simple count + EXCEPT DISTINCT diffs for changed models in a PR.
# Assumes CI already created and built into $DBT_BQ_DATASET in $DBT_GCP_PROJECT_CI.
# Requires dbt to be installed and authenticated to BigQuery.

ARTIFACT_DIR=${ARTIFACT_DIR:-diff_reports}
DIFF_LIMIT=${DIFF_LIMIT:-100}
mkdir -p "$ARTIFACT_DIR"

DEV_PROJECT=${DBT_GCP_PROJECT_CI:?set DBT_GCP_PROJECT_CI}
DEV_DATASET=${DBT_BQ_DATASET:?set DBT_BQ_DATASET}
PROD_PROJECT=${DBT_GCP_PROJECT_PROD:-}

# Pull prod manifest if not already present (optional, CI workflow usually does this earlier)
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" && ! -f prod_state/manifest.json ]]; then
  mkdir -p prod_state
  if gsutil ls "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" >/dev/null 2>&1; then
    gsutil cp "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" prod_state/manifest.json
    echo "Pulled prod manifest for state selection"
  fi
fi

echo "Listing changed models via dbt state selector (fallback to all if none)"
if [[ -f prod_state/manifest.json ]]; then
  mapfile -t MODELS < <(dbt ls --select "state:modified+" --state prod_state --resource-type model --output name || true)
else
  mapfile -t MODELS < <(dbt ls --resource-type model --output name || true)
fi

if (( ${#MODELS[@]} == 0 )); then
  echo "No models to diff."
  exit 0
fi

echo "Diffing ${#MODELS[@]} model(s): ${MODELS[*]}"

for m in "${MODELS[@]}"; do
  safe="${m//\//_}"
  out="${ARTIFACT_DIR}/${safe}.txt"
  echo "== ${m} ==" | tee "$out"
  # Produce and print results. We pass the CI dataset explicitly.
  dbt run-operation dev_prod_diff_for_model \
    --args "{model_name: '${m}', dev_project: '${DEV_PROJECT}', prod_project: '${PROD_PROJECT}', dev_dataset: '${DEV_DATASET}', limit: ${DIFF_LIMIT}}" \
    | tee -a "$out" || true
  echo >> "$out"
done

echo "Wrote diff reports to ${ARTIFACT_DIR}/"

# Build markdown summary from SUMMARY lines
SUMMARY_MD="${ARTIFACT_DIR}/summary.md"
echo "# dbt Data Diff Summary" > "$SUMMARY_MD"
echo >> "$SUMMARY_MD"
echo "| Model | Dev Rows | Prod Rows | Dev-Not-In-Prod | Prod-Not-In-Dev |" >> "$SUMMARY_MD"
echo "|---|---:|---:|---:|---:|" >> "$SUMMARY_MD"

grep -h '^SUMMARY|' ${ARTIFACT_DIR}/*.txt | while IFS='|' read -r _ t dev prod dnp pnd; do
  model="${t#table=}"
  dev_rows="${dev#dev=}"
  prod_rows="${prod#prod=}"
  dnp_rows="${dnp#dev_not_in_prod=}"
  pnd_rows="${pnd#prod_not_in_dev=}"
  echo "| ${model} | ${dev_rows} | ${prod_rows} | ${dnp_rows} | ${pnd_rows} |" >> "$SUMMARY_MD"
done

echo "Summary written to ${SUMMARY_MD}"
