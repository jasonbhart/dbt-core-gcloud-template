#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v bq >/dev/null || { echo "bq not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

# Helpers
info(){ echo "[info] $*"; }
require_env(){
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "Missing env: $v"
      exit 1
    fi
  done
  return 0
}

ensure_api(){ local api="$1"; info "Ensuring API enabled: $api"; gcloud services enable "$api" --project "$PROJECT_ID" >/dev/null; }
ensure_sa(){ local id="$1" dn="$2"; local email="${id}@${PROJECT_ID}.iam.gserviceaccount.com"; if gcloud iam service-accounts describe "$email" --project "$PROJECT_ID" >/dev/null 2>&1; then info "SA exists: $email"; else info "Creating SA: $email"; gcloud iam service-accounts create "$id" --display-name="$dn" --project "$PROJECT_ID"; fi; }
ensure_ar_repo(){ if gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then info "AR repo exists: $AR_REPO"; else info "Creating AR repo: $AR_REPO"; gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" --description="dbt containers" --project "$PROJECT_ID"; fi }
ensure_bucket(){
  local name="${DOCS_BUCKET_NAME}"
  local uri="gs://${name}"
  # First, try to describe. If it exists and we have access, we're done.
  local err_file
  err_file="$(mktemp)"
  if gcloud storage buckets describe "$uri" --project "$PROJECT_ID" >/dev/null 2>"$err_file"; then
    info "Bucket exists: $uri"
    rm -f "$err_file"
    return 0
  fi
  # If describe failed with 403, it's very likely the name is already taken by another project.
  local err_msg
  err_msg="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
  if [[ "$err_msg" == *"HttpError 403"* || "$err_msg" == *"Permission denied"* || "$err_msg" == *"AccessDenied"* || "$err_msg" == *"does not have storage.buckets.get"* ]]; then
    echo "[error] Bucket name '${name}' appears to be in use (403 on describe)." >&2
    echo "        GCS bucket names are global. Please set DOCS_BUCKET_NAME to a unique value" >&2
    echo "        (e.g., '${PROJECT_ID}-dbt-docs' or 'dbt-docs-${PROJECT_ID}') and re-run." >&2
    exit 1
  fi
  # Otherwise, attempt to create and handle a possible 409/name-taken error with a friendly message.
  info "Creating bucket: $uri"
  local create_out rc
  create_out="$(gcloud storage buckets create "$uri" --location="$REGION" --project "$PROJECT_ID" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ "$create_out" == *"409"* || "$create_out" == *"already exists"* || "$create_out" == *"not available"* || "$create_out" == *"already owns this bucket"* ]]; then
      echo "[error] Bucket name '${name}' is already taken globally." >&2
      echo "        Please choose a unique DOCS_BUCKET_NAME (e.g., '${PROJECT_ID}-dbt-docs')." >&2
    else
      echo "[error] Failed to create bucket ${uri}:" >&2
      echo "        ${create_out}" >&2
    fi
    exit 1
  fi
}
ensure_dataset(){ local ds="$1" desc="$2"; if bq --location="$BQ_LOCATION" show --format=none "${PROJECT_ID}:${ds}" >/dev/null 2>&1; then info "Dataset exists: ${ds}"; else info "Creating dataset: ${ds}"; bq --location="$BQ_LOCATION" mk -d --description "$desc" "${PROJECT_ID}:${ds}"; fi }

ensure_project_binding(){ local role="$1" member="$2"; local policy tmp; tmp="$(mktemp)"; gcloud projects get-iam-policy "$PROJECT_ID" --format=json >"$tmp"; if jq -e --arg r "$role" --arg m "$member" '.bindings[]? | select(.role==$r) | .members[]? | select(.==$m)' "$tmp" >/dev/null; then info "Project IAM binding exists: $role -> $member"; else info "Adding project IAM binding: $role -> $member"; gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$member" --role="$role" --quiet >/dev/null; fi; rm -f "$tmp"; }

add_dataset_binding () {
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
    info "Updating dataset IAM: ${dataset} ${role} += ${member}"
    bq set-iam-policy "${PROJECT_ID}:${dataset}" "${tmp2}" >/dev/null
  else
    info "Dataset IAM already set: ${dataset} ${role} has ${member}"
  fi
  rm -f "${tmp}" "${tmp2}"
}

require_env PROJECT_ID PROJECT_NUMBER REGION BQ_LOCATION AR_REPO PROD_DATASET INT_DATASET DOCS_BUCKET_NAME CI_SA_ID PROD_SA_ID SCHEDULER_SA_ID

CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

info "Enabling required APIs"
ensure_api run.googleapis.com
ensure_api cloudscheduler.googleapis.com
ensure_api artifactregistry.googleapis.com
ensure_api bigquery.googleapis.com
ensure_api iam.googleapis.com
ensure_api iamcredentials.googleapis.com
ensure_api sts.googleapis.com
ensure_api logging.googleapis.com
ensure_api monitoring.googleapis.com

info "Ensuring service accounts"
ensure_sa "${CI_SA_ID}" "dbt CI SA"
ensure_sa "${PROD_SA_ID}" "dbt Prod SA"
ensure_sa "${SCHEDULER_SA_ID}" "Scheduler Invoker SA"
if [[ -n "${DOCS_VIEWER_SA_ID:-}" ]]; then
  ensure_sa "${DOCS_VIEWER_SA_ID}" "Docs Viewer SA"
fi

info "Ensuring Artifact Registry repo"
ensure_ar_repo

info "Ensuring docs bucket"
ensure_bucket

info "Ensuring BigQuery datasets"
ensure_dataset "${PROD_DATASET}" "dbt prod dataset"
ensure_dataset "${INT_DATASET}" "dbt integration dataset"

info "Ensuring project-level IAM"
ensure_project_binding roles/bigquery.jobUser "serviceAccount:${CI_SA_EMAIL}"
ensure_project_binding roles/bigquery.jobUser "serviceAccount:${PROD_SA_EMAIL}"
ensure_project_binding roles/artifactregistry.writer "serviceAccount:${CI_SA_EMAIL}"
ensure_project_binding roles/logging.logWriter "serviceAccount:${PROD_SA_EMAIL}"

# Optional: grant BigQuery Job User to a developer Google Group for per-dev work
if [[ -n "${DEV_GROUP_EMAIL:-}" ]]; then
  info "Ensuring project-level IAM for dev group: roles/bigquery.jobUser -> group:${DEV_GROUP_EMAIL}"
  ensure_project_binding roles/bigquery.jobUser "group:${DEV_GROUP_EMAIL}"
fi

info "Ensuring dataset-level IAM"
add_dataset_binding "${INT_DATASET}"  "roles/bigquery.dataEditor" "serviceAccount:${CI_SA_EMAIL}"
add_dataset_binding "${PROD_DATASET}" "roles/bigquery.dataViewer" "serviceAccount:${CI_SA_EMAIL}"
add_dataset_binding "${PROD_DATASET}" "roles/bigquery.dataEditor" "serviceAccount:${PROD_SA_EMAIL}"

info "Ensuring bucket IAM for docs"
if ! gcloud storage buckets get-iam-policy "gs://${DOCS_BUCKET_NAME}" --format=json | jq -e --arg m "serviceAccount:${PROD_SA_EMAIL}" '.bindings[]? | select(.role=="roles/storage.objectAdmin") | .members[]? | select(.==$m)' >/dev/null; then
  gcloud storage buckets add-iam-policy-binding "gs://${DOCS_BUCKET_NAME}" \
    --member="serviceAccount:${PROD_SA_EMAIL}" \
    --role="roles/storage.objectAdmin" \
    --project "${PROJECT_ID}" --quiet
  info "Added storage.objectAdmin on bucket to ${PROD_SA_EMAIL}"
else
  info "Bucket IAM already set for ${PROD_SA_EMAIL}"
fi

# Allow docs viewer SA to read docs (if defined)
if [[ -n "${DOCS_VIEWER_SA_ID:-}" ]]; then
  viewer_email="${DOCS_VIEWER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! gcloud storage buckets get-iam-policy "gs://${DOCS_BUCKET_NAME}" --format=json | jq -e --arg m "serviceAccount:${viewer_email}" '.bindings[]? | select(.role=="roles/storage.objectViewer") | .members[]? | select(.==$m)' >/dev/null; then
    gcloud storage buckets add-iam-policy-binding "gs://${DOCS_BUCKET_NAME}" \
      --member="serviceAccount:${viewer_email}" \
      --role="roles/storage.objectViewer" \
      --project "${PROJECT_ID}" --quiet
    info "Added storage.objectViewer on bucket to ${viewer_email}"
  else
    info "Bucket IAM already set for docs viewer SA"
  fi
fi

info "Bootstrap complete."
