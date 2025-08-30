#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

require_env(){ for v in "$@"; do [[ -z "${!v:-}" ]] && { echo "Missing env: $v"; exit 1; }; done; }
require_env PROJECT_ID REGION AR_REPO IMAGE_NAME IMAGE_TAG PROD_SA_ID PROD_DATASET BQ_LOCATION

PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "Deploying Cloud Run Job 'dbt-prod-run' with image: ${IMAGE_URI}"

gcloud run jobs deploy dbt-prod-run \
  --image="${IMAGE_URI}" \
  --region="${REGION}" \
  --service-account="${PROD_SA_EMAIL}" \
  --max-retries=1 \
  --task-timeout=3600s \
  --set-env-vars="DBT_TARGET=prod,DBT_GCP_PROJECT_PROD=${PROJECT_ID},DBT_BQ_DATASET_PROD=${PROD_DATASET},DBT_BQ_LOCATION=${BQ_LOCATION}" \
  --project "${PROJECT_ID}"

echo "Cloud Run Job deployed."
