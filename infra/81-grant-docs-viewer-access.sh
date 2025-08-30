#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PRINCIPAL="${1:-${DOCS_VIEWER_ALLOWED_PRINCIPAL:-}}"
if [[ -z "$PRINCIPAL" ]]; then
  echo "Usage: $0 <principal>    # e.g., group:[email protected] or user:[email protected]"
  exit 1
fi

SERVICE="${DOCS_VIEWER_SERVICE:?Set DOCS_VIEWER_SERVICE in infra/.env}"

echo "Granting roles/run.invoker on service ${SERVICE} to ${PRINCIPAL}"
gcloud run services add-iam-policy-binding "$SERVICE" \
  --region "${REGION}" \
  --member "$PRINCIPAL" \
  --role roles/run.invoker \
  --project "${PROJECT_ID}"

echo "Done."

