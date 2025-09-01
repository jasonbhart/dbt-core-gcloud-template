#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

require_env(){
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]] ; then
      echo "Missing env: $v"
      exit 1
    fi
  done
  return 0
}
require_env PROJECT_ID REGION AR_REPO DBT_DOCS_BUCKET DOCS_VIEWER_SERVICE DOCS_VIEWER_SA_ID

SERVICE="$DOCS_VIEWER_SERVICE"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE}:${IMAGE_TAG:-latest}"
VIEWER_SA_EMAIL="${DOCS_VIEWER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Building and pushing image: ${IMAGE_URI}"
cd ..
APP_DIR="${DOCS_VIEWER_DIR:-./docs-viewer}"
if [[ ! -d "$APP_DIR" ]]; then
  echo "Docs viewer app directory not found: $APP_DIR" >&2
  echo "Set DOCS_VIEWER_DIR to the app path, or place the app in ./docs-viewer" >&2
  exit 1
fi
docker build -t "$IMAGE_URI" "$APP_DIR"
docker push "$IMAGE_URI"
cd - >/dev/null

echo "Deploying Cloud Run service: ${SERVICE}"
gcloud run deploy "$SERVICE" \
  --image "$IMAGE_URI" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --service-account "$VIEWER_SA_EMAIL" \
  --set-env-vars "DBT_DOCS_BUCKET=${DBT_DOCS_BUCKET}" \
  --min-instances=0 \
  --max-instances=2 \
  --project "$PROJECT_ID"

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')
echo "Service URL: $URL"
echo "Grant access with: ./81-grant-docs-viewer-access.sh <principal>   # e.g., group:[email protected]"
