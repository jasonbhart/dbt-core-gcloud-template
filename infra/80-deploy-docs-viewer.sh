#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

require_env(){ for v in "$@"; do [[ -z "${!v:-}" ]] && { echo "Missing env: $v"; exit 1; }; done; }
require_env PROJECT_ID REGION AR_REPO DOCS_BUCKET_NAME DOCS_VIEWER_SERVICE DOCS_VIEWER_SA_ID

SERVICE="$DOCS_VIEWER_SERVICE"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE}:${IMAGE_TAG:-latest}"
VIEWER_SA_EMAIL="${DOCS_VIEWER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Building and pushing image: ${IMAGE_URI}"
cd ..
docker build -t "$IMAGE_URI" ./dbt-docs-viewer
docker push "$IMAGE_URI"
cd - >/dev/null

echo "Deploying Cloud Run service: ${SERVICE}"
gcloud run deploy "$SERVICE" \
  --image "$IMAGE_URI" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --service-account "$VIEWER_SA_EMAIL" \
  --set-env-vars "DOCS_BUCKET_NAME=${DOCS_BUCKET_NAME}" \
  --min-instances=0 \
  --max-instances=2 \
  --project "$PROJECT_ID"

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')
echo "Service URL: $URL"
echo "Grant access with: ./81-grant-dbt-docs-viewer-access.sh <principal>   # e.g., group:[email protected]"

