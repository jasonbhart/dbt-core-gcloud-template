#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

BUCKET="${DBT_ARTIFACTS_BUCKET:-${DBT_DOCS_BUCKET}}"
if [[ -z "$BUCKET" ]]; then
  echo "Set DBT_ARTIFACTS_BUCKET or DBT_DOCS_BUCKET in infra/.env" >&2
  exit 1
fi

TMP=$(mktemp)
cat > "$TMP" <<JSON
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    }
  ]
}
JSON

echo "Applying lifecycle rule (delete objects older than 30 days) to gs://${BUCKET}"
gcloud storage buckets update "gs://${BUCKET}" --lifecycle-file="$TMP"
rm -f "$TMP"
echo "Done."
