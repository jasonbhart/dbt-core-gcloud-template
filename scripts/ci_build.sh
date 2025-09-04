#!/usr/bin/env bash
set -euo pipefail

mkdir -p prod_state
HAS_STATE="false"

echo "=== Slim CI State Detection ==="
echo "DBT_ARTIFACTS_BUCKET: ${DBT_ARTIFACTS_BUCKET:-<unset>}"
echo "Checking for production manifest at: gs://${DBT_ARTIFACTS_BUCKET:-<unset>}/prod/manifest.json"

if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]]; then
  if gsutil ls "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" >/dev/null 2>&1; then
    echo "Production manifest found, downloading..."
    gsutil cp "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" prod_state/manifest.json
    if [[ -f prod_state/manifest.json ]]; then
      manifest_size=$(wc -c < prod_state/manifest.json)
      echo "Successfully downloaded manifest (${manifest_size} bytes)"
      if [[ ${manifest_size} -gt 100 ]]; then
        HAS_STATE="true"
        echo "✓ Slim CI will use state comparison and defer"
      else
        echo "⚠ Downloaded manifest is too small (${manifest_size} bytes), treating as unavailable"
      fi
    else
      echo "⚠ Manifest download failed - file not found after copy"
    fi
  else
    echo "No production manifest found at gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json"
  fi
else
  echo "DBT_ARTIFACTS_BUCKET not set, skipping production manifest download"
fi

dbt deps

echo ""
echo "=== dbt Build Strategy ==="
if [[ "${HAS_STATE}" == "true" ]]; then
  echo "Using Slim CI with state comparison and defer"
  echo "Checking which models dbt detects as changed..."

  # Show what models will be selected (debug output)
  echo "Models selected by state:modified+:"
  dbt ls --select "state:modified+" --state prod_state --resource-type model --output name --target ci || {
    echo "⚠ Error running dbt ls with state selection, falling back to full build"
    echo "Running full build due to state selection error"
    dbt build --target ci
    exit $?
  }

  echo ""
  echo "Starting Slim CI build with defer..."
  dbt build --target ci --select "state:modified+" --defer --state prod_state
else
  echo "No production state available, running full build"
  echo "All models will be built from scratch"
  dbt build --target ci
fi

echo ""
echo "=== Build Complete ==="
