#!/usr/bin/env bash
set -euo pipefail

# Required env: DBT_GCP_PROJECT_CI, DBT_BQ_LOCATION, DBT_BQ_DATASET
# Optional env: CI_SA_EMAIL (writer), MAKE_DATASET_READONLY (default true)

bq --project_id="${DBT_GCP_PROJECT_CI}" --location="${DBT_BQ_LOCATION}" mk -d "${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" || true
echo "Created dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}"

# Optionally make the dataset read-only for everyone except CI SA (writer)
MAKE_DATASET_READONLY=${MAKE_DATASET_READONLY:-true}
if [[ "$MAKE_DATASET_READONLY" == "true" ]]; then
  tmpJson=$(mktemp)
  newJson=$(mktemp)
  if bq --project_id="${DBT_GCP_PROJECT_CI}" show --format=prettyjson "${DBT_BQ_DATASET}" >"$tmpJson" 2>/dev/null; then
    # Remove projectWriters, keep projectReaders/Owners, add CI SA as WRITER if provided
    jq --arg ci "${CI_SA_EMAIL:-}" '
      .access = (
        (.access // [])
        | map(select(.specialGroup != "projectWriters"))
        | (if ($ci|length) > 0 then . + [{"userByEmail": $ci, "role":"WRITER"}] else . end)
        | unique_by(.role, (.userByEmail // ""), (.groupByEmail // ""), (.specialGroup // ""))
      )
    ' "$tmpJson" > "$newJson"
    if ! diff -q "$tmpJson" "$newJson" >/dev/null 2>&1; then
      if bq --project_id="${DBT_GCP_PROJECT_CI}" update --source "$newJson" "${DBT_BQ_DATASET}" >/dev/null 2>&1; then
        echo "Hardened dataset ACLs for ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET} (read-only except CI writer)"
      else
        echo "[warn] Failed to update ACLs for ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" >&2
      fi
    fi
  fi
  rm -f "$tmpJson" "$newJson"
fi
