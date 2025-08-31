#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

DOCS_BUCKET="${DOCS_BUCKET_NAME:?Set DOCS_BUCKET_NAME in infra/.env}"
PUBLIC=${PUBLIC:-false}

echo "Configuring website settings on gs://${DOCS_BUCKET} (index.html)"
gcloud storage buckets update "gs://${DOCS_BUCKET}" \
  --web-main-page-suffix=index.html \
  --project "${PROJECT_ID}"

if [[ "${PUBLIC}" == "true" ]]; then
  echo "Granting public read (roles/storage.objectViewer) to allUsers"
  gcloud storage buckets add-iam-policy-binding "gs://${DOCS_BUCKET}" \
    --member=allUsers \
    --role=roles/storage.objectViewer \
    --project "${PROJECT_ID}" --quiet || true
  echo
  echo "Public URL: https://storage.googleapis.com/${DOCS_BUCKET}/index.html"
else
  echo "Bucket remains private. To access docs, either:"
  echo " - Open index.html via Cloud Console (Storage > Buckets > ${DOCS_BUCKET} > index.html)"
  echo " - Or serve privately via Cloud Run/Load Balancer (recommended for internal access)."
fi

echo "Done."

