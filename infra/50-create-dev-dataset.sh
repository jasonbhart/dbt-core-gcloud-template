#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <developer_email> [dataset_name]"
  exit 1
fi

DEV_EMAIL="$1"
DEFAULT_DS="dbt_${DEV_EMAIL%@*}_dev"
DEV_DS="${2:-$DEFAULT_DS}"

# Ensure dataset exists
if bq --location="${BQ_LOCATION}" show --format=none "${PROJECT_ID}:${DEV_DS}" >/dev/null 2>&1; then
  echo "Dataset exists: ${DEV_DS}"
else
  echo "Creating dataset: ${DEV_DS}"
  bq --location="${BQ_LOCATION}" mk -d --description "Dev dataset for ${DEV_EMAIL}" "${PROJECT_ID}:${DEV_DS}"
fi

add_ds () {
  local dataset="$1" role="$2" member="$3"
  local tmp="$(mktemp)"
  if ! bq get-iam-policy --format=prettyjson "${PROJECT_ID}:${dataset}" > "${tmp}" 2>/dev/null; then
    echo '{"bindings":[],"version":1}' > "${tmp}"
  fi
  local tmp2="${tmp}.new"
  jq --arg role "${role}" --arg member "${member}" '
    .bindings |= (. // []) |
    if any(.bindings[]?; .role==$role) then
      .bindings |= map(if .role==$role then (.members += [$member] | .members |= unique) else . end)
    else
      .bindings += [{"role": $role, "members": [$member]}]
    end
  ' "${tmp}" > "${tmp2}"
  if ! diff -q "${tmp}" "${tmp2}" >/dev/null 2>&1; then
    bq set-iam-policy "${PROJECT_ID}:${dataset}" "${tmp2}" >/dev/null
    echo "Updated dataset IAM: ${role} += ${member}"
  else
    echo "Dataset IAM already set: ${role} has ${member}"
  fi
  rm -f "${tmp}" "${tmp2}"
}

add_ds "${DEV_DS}" "roles/bigquery.dataEditor" "user:${DEV_EMAIL}"

CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
add_ds "${DEV_DS}" "roles/bigquery.dataViewer" "serviceAccount:${CI_SA_EMAIL}"
add_ds "${DEV_DS}" "roles/bigquery.dataViewer" "serviceAccount:${PROD_SA_EMAIL}"

echo "Created/updated dev dataset ${DEV_DS} for ${DEV_EMAIL}."
