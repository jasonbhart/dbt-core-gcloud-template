#!/usr/bin/env bash
set -euo pipefail

# Required env: DBT_GCP_PROJECT_CI, DBT_BQ_DATASET

bq rm -r -f -d "${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" || true
echo "Dropped dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}"

