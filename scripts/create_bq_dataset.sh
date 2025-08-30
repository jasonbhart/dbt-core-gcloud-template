#!/usr/bin/env bash
set -euo pipefail

# Required env: DBT_GCP_PROJECT_CI, DBT_BQ_LOCATION, DBT_BQ_DATASET

gcloud config set project "${DBT_GCP_PROJECT_CI}"
bq --location="${DBT_BQ_LOCATION}" mk -d "${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" || true
echo "Created dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}"

