#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v bq >/dev/null || { echo "bq not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

# Helpers
info(){ echo "[info] $*"; }
warn(){ echo "[warn] $*"; }
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
# Optional API enablement that won't fail the script if unavailable in the org/region
ensure_api_optional(){
  local api="$1" out rc
  info "Ensuring API enabled (optional): $api"
  out=$(gcloud services enable "$api" --project "$PROJECT_ID" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Optional API enable failed for ${api}. Continuing."
    if [[ "${DEBUG:-0}" == "1" ]]; then
      echo "[debug] services.enable error for ${api}: ${out}" >&2
    fi
  fi
}
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
  if ! bq --project_id="${PROJECT_ID}" get-iam-policy --format=prettyjson "${PROJECT_ID}:${dataset}" > "${tmp}" 2>/dev/null; then
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
    # Try IAM first (newer surface). Using 'if' avoids exiting under 'set -e' on nonzero.
    if bq --project_id="${PROJECT_ID}" set-iam-policy "${PROJECT_ID}:${dataset}" "${tmp2}" >/dev/null 2>&1; then
      info "Dataset IAM updated: ${dataset} (${role})"
    else
      warn "Failed to set IAM on dataset ${PROJECT_ID}:${dataset} via IAM API. Attempting legacy ACL fallback."
      # Fallback mapping: dataViewer->READER, dataEditor->WRITER
      local acl_role="" ent_key="" ent_val=""
      case "$role" in
        roles/bigquery.dataViewer) acl_role="READER" ;;
        roles/bigquery.dataEditor) acl_role="WRITER" ;;
        *) acl_role="" ;;
      esac
      if [[ -n "$acl_role" ]]; then
        if [[ "$member" == serviceAccount:* || "$member" == user:* ]]; then
          ent_key="userByEmail"; ent_val="${member#*:}"
        elif [[ "$member" == group:* ]]; then
          ent_key="groupByEmail"; ent_val="${member#group:}"
        else
          ent_key=""; ent_val=""
        fi
        if [[ -n "$ent_key" && -n "$ent_val" ]]; then
          local ds_tmp ds_new
          ds_tmp="$(mktemp)"; ds_new="$(mktemp)"
          if bq --project_id="${PROJECT_ID}" show --format=prettyjson "${dataset}" >"$ds_tmp" 2>/dev/null; then
            jq --arg role "$acl_role" --arg key "$ent_key" --arg val "$ent_val" '
              .access = ((.access // []) + [{($key): $val, role: $role}])
              | .access |= unique_by(.role, (.userByEmail // ""), (.groupByEmail // ""), (.specialGroup // ""))
            ' "$ds_tmp" > "$ds_new"
            if ! diff -q "$ds_tmp" "$ds_new" >/dev/null 2>&1; then
              if bq --project_id="${PROJECT_ID}" update --source "$ds_new" "${dataset}" >/dev/null 2>&1; then
                info "Dataset ACL fallback updated: ${dataset} ${acl_role} += ${ent_val}"
              else
                warn "ACL fallback failed to update dataset ${PROJECT_ID}:${dataset}."
              fi
            else
              info "Dataset ACL already had ${acl_role} for ${ent_val}"
            fi
          else
            warn "Failed to fetch dataset ${PROJECT_ID}:${dataset} for ACL fallback."
          fi
          rm -f "$ds_tmp" "$ds_new"
        else
          warn "Unsupported member for ACL fallback: ${member}"
        fi
      else
        warn "No ACL fallback mapping for role ${role}; skipping."
      fi
    fi
  else
    info "Dataset IAM already set: ${dataset} ${role} has ${member}"
  fi
  rm -f "${tmp}" "${tmp2}"
}

# Harden dataset ACLs so that only the specified writer_email has WRITER; all others get no write.
# Keeps projectOwners and projectReaders; removes projectWriters and any other WRITER entries.
harden_dataset_acl_writer_only() {
  local dataset="$1" writer_email="$2"
  local ds_tmp ds_new
  ds_tmp="$(mktemp)"; ds_new="$(mktemp)"
  if ! bq --project_id="${PROJECT_ID}" show --format=prettyjson "${dataset}" >"$ds_tmp" 2>/dev/null; then
    warn "Failed to fetch dataset ${PROJECT_ID}:${dataset} for ACL hardening"
    rm -f "$ds_tmp" "$ds_new"
    return 0
  fi
  jq --arg writer "$writer_email" '
    .access = (
      (.access // [])
      # Drop projectWriters entry entirely
      | map(select(.specialGroup != "projectWriters"))
      # Drop any WRITER that is not the designated writer
      | map(select(.role != "WRITER" or (.userByEmail == $writer)))
      # Ensure designated writer entry exists
      | ((. + [{"role":"WRITER","userByEmail": $writer}])
        | unique_by(.role, (.userByEmail // ""), (.groupByEmail // ""), (.specialGroup // "")))
    )
  ' "$ds_tmp" > "$ds_new"
  if ! diff -q "$ds_tmp" "$ds_new" >/dev/null 2>&1; then
    if bq --project_id="${PROJECT_ID}" update --source "$ds_new" "${dataset}" >/dev/null 2>&1; then
      info "Hardened ACLs: ${dataset} writer only -> ${writer_email}"
    else
      warn "Failed to harden ACLs on ${PROJECT_ID}:${dataset}"
    fi
  else
    info "ACLs already hardened for ${dataset}"
  fi
  rm -f "$ds_tmp" "$ds_new"
}

# Ensure a member has a role on a GCS bucket via get-modify-set flow (idempotent)
ensure_bucket_binding () {
  local bucket="$1" role="$2" member="$3"
  local tmp="$(mktemp)"
  if ! gcloud storage buckets get-iam-policy "gs://${bucket}" --format=json --project "${PROJECT_ID}" > "${tmp}" 2>/dev/null; then
    echo '{"bindings":[],"version":3}' > "${tmp}"
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
    info "Updating bucket IAM: gs://${bucket} ${role} += ${member}"
    gcloud storage buckets set-iam-policy "gs://${bucket}" "${tmp2}" --project "${PROJECT_ID}" >/dev/null
  else
    info "Bucket IAM already set: gs://${bucket} ${role} has ${member}"
  fi
  rm -f "${tmp}" "${tmp2}"
}

require_env PROJECT_ID PROJECT_NUMBER REGION BQ_LOCATION AR_REPO PROD_DATASET DOCS_BUCKET_NAME CI_SA_ID PROD_SA_ID SCHEDULER_SA_ID

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
ensure_api bigquerystorage.googleapis.com
ensure_api_optional notebooks.googleapis.com
ensure_api_optional dataform.googleapis.com

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
if [[ -n "${INT_DATASET:-}" ]]; then
  ensure_dataset "${INT_DATASET}" "dbt integration dataset"
else
  info "INT_DATASET not set; skipping integration dataset creation"
fi

info "Ensuring project-level IAM"
ensure_project_binding roles/bigquery.jobUser "serviceAccount:${CI_SA_EMAIL}"
ensure_project_binding roles/bigquery.jobUser "serviceAccount:${PROD_SA_EMAIL}"
# Allow CI to create datasets for ephemeral PR runs
ensure_project_binding roles/bigquery.user "serviceAccount:${CI_SA_EMAIL}"
# Allow both CI and PROD service accounts to push to Artifact Registry
ensure_project_binding roles/artifactregistry.writer "serviceAccount:${CI_SA_EMAIL}"
ensure_project_binding roles/artifactregistry.writer "serviceAccount:${PROD_SA_EMAIL}"
ensure_project_binding roles/logging.logWriter "serviceAccount:${PROD_SA_EMAIL}"

# Allow the PROD SA (used by GitHub Actions) to manage Cloud Run Jobs and Cloud Scheduler jobs
ensure_project_binding roles/run.developer "serviceAccount:${PROD_SA_EMAIL}"
# Cloud Scheduler has only admin/viewer predefined roles; admin needed to create/update jobs
ensure_project_binding roles/cloudscheduler.admin "serviceAccount:${PROD_SA_EMAIL}"

# Permit the deployer identity to set the runtime service account when deploying the job
# (required by Cloud Run to use --service-account). Here we allow the PROD SA to act as itself.
TMP_SA_POLICY="$(mktemp)"
gcloud iam service-accounts get-iam-policy "${PROD_SA_EMAIL}" --format=json --project "${PROJECT_ID}" >"${TMP_SA_POLICY}"
if ! jq -e --arg m "serviceAccount:${PROD_SA_EMAIL}" '.bindings[]? | select(.role=="roles/iam.serviceAccountUser") | .members[]? | select(.==$m)' "${TMP_SA_POLICY}" >/dev/null; then
  info "Granting roles/iam.serviceAccountUser on ${PROD_SA_EMAIL} to itself (for --service-account)"
  gcloud iam service-accounts add-iam-policy-binding "${PROD_SA_EMAIL}" \
    --member "serviceAccount:${PROD_SA_EMAIL}" \
    --role roles/iam.serviceAccountUser \
    --project "${PROJECT_ID}" >/dev/null
else
  info "Service account user binding already present on ${PROD_SA_EMAIL}"
fi
rm -f "${TMP_SA_POLICY}"

# Optionally allow the human operator to set the runtime service account during deploys
# Determine operator principal from either OPERATOR_EMAIL or active gcloud account
if [[ "${OPERATOR_GRANT_ACTAS:-true}" == "true" ]]; then
  operator_email="${OPERATOR_EMAIL:-}"
  if [[ -z "$operator_email" ]]; then
    operator_email=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE' 2>/dev/null || true)
  fi
  if [[ -n "$operator_email" ]]; then
    if [[ "$operator_email" == *"gserviceaccount.com"* ]]; then
      operator_member="serviceAccount:${operator_email}"
    else
      operator_member="user:${operator_email}"
    fi
    OP_SA_POLICY_TMP="$(mktemp)"
    gcloud iam service-accounts get-iam-policy "${PROD_SA_EMAIL}" --format=json --project "${PROJECT_ID}" >"${OP_SA_POLICY_TMP}"
    if ! jq -e --arg m "$operator_member" '.bindings[]? | select(.role=="roles/iam.serviceAccountUser") | .members[]? | select(.==$m)' "${OP_SA_POLICY_TMP}" >/dev/null; then
      info "Granting roles/iam.serviceAccountUser on ${PROD_SA_EMAIL} to ${operator_member} (for local deploys)"
      gcloud iam service-accounts add-iam-policy-binding "${PROD_SA_EMAIL}" \
        --member "$operator_member" \
        --role roles/iam.serviceAccountUser \
        --project "${PROJECT_ID}" >/dev/null
    else
      info "Operator already has Service Account User on ${PROD_SA_EMAIL}: ${operator_member}"
    fi
    rm -f "${OP_SA_POLICY_TMP}"
  else
    info "No operator email resolved; skipping operator actAs grant"
  fi
fi

# Allow Cloud Scheduler service agent to mint tokens for the Scheduler SA when invoking the job
SCHEDULER_SA_POLICY_TMP="$(mktemp)"
gcloud iam service-accounts get-iam-policy "${SCHED_SA_EMAIL}" --format=json --project "${PROJECT_ID}" >"${SCHEDULER_SA_POLICY_TMP}"
SCHED_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
if ! jq -e --arg m "serviceAccount:${SCHED_AGENT}" '.bindings[]? | select(.role=="roles/iam.serviceAccountTokenCreator") | .members[]? | select(.==$m)' "${SCHEDULER_SA_POLICY_TMP}" >/dev/null; then
  info "Granting roles/iam.serviceAccountTokenCreator on ${SCHED_SA_EMAIL} to ${SCHED_AGENT} (Cloud Scheduler service agent)"
  gcloud iam service-accounts add-iam-policy-binding "${SCHED_SA_EMAIL}" \
    --member "serviceAccount:${SCHED_AGENT}" \
    --role roles/iam.serviceAccountTokenCreator \
    --project "${PROJECT_ID}" >/dev/null
else
  info "Scheduler service agent already has TokenCreator on ${SCHED_SA_EMAIL}"
fi
rm -f "${SCHEDULER_SA_POLICY_TMP}"

# Allow the deployer (PROD SA) to configure Scheduler with --oauth-service-account-email
# This requires iam.serviceAccounts.actAs on the Scheduler SA
SCHEDULER_SA_POLICY_TMP2="$(mktemp)"
gcloud iam service-accounts get-iam-policy "${SCHED_SA_EMAIL}" --format=json --project "${PROJECT_ID}" >"${SCHEDULER_SA_POLICY_TMP2}"
if ! jq -e --arg m "serviceAccount:${PROD_SA_EMAIL}" '.bindings[]? | select(.role=="roles/iam.serviceAccountUser") | .members[]? | select(.==$m)' "${SCHEDULER_SA_POLICY_TMP2}" >/dev/null; then
  info "Granting roles/iam.serviceAccountUser on ${SCHED_SA_EMAIL} to ${PROD_SA_EMAIL} (for Scheduler OAuth config)"
  gcloud iam service-accounts add-iam-policy-binding "${SCHED_SA_EMAIL}" \
    --member "serviceAccount:${PROD_SA_EMAIL}" \
    --role roles/iam.serviceAccountUser \
    --project "${PROJECT_ID}" >/dev/null
else
  info "Deployer already has Service Account User on ${SCHED_SA_EMAIL}"
fi
rm -f "${SCHEDULER_SA_POLICY_TMP2}"

# Optional: grant BigQuery Job User to a developer Google Group for per-dev work
if [[ -n "${DEV_GROUP_EMAIL:-}" ]]; then
  info "Ensuring project-level IAM for dev group: roles/bigquery.jobUser -> group:${DEV_GROUP_EMAIL}"
  ensure_project_binding roles/bigquery.jobUser "group:${DEV_GROUP_EMAIL}"
fi

# Additional project-level roles for dbt users (service accounts, devs, operator)
add_project_binding_soft(){
  local role="$1" member="$2" out rc
  out=$(gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$member" --role="$role" --quiet 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Could not add $role to $member (project $PROJECT_ID)"
    if [[ "${DEBUG:-0}" == "1" ]]; then
      echo "[debug] gcloud error: ${out}" >&2
    fi
  else
    info "Ensured $role -> $member"
  fi
}

DBT_USER_ROLES=(
  roles/bigquery.user
  roles/bigquery.readSessionUser
  roles/bigquery.jobUser
  roles/notebooks.runtimeUser
  roles/dataform.codeCreator
  roles/colab.enterpriseUser
)

# Optionally include project-level Data Editor when prod is not read-only
if [[ "${PROD_READ_ONLY:-true}" != "true" ]]; then
  DBT_USER_ROLES+=(roles/bigquery.dataEditor)
fi

info "Ensuring project-level roles for dbt service accounts"
for role in "${DBT_USER_ROLES[@]}"; do
  add_project_binding_soft "$role" "serviceAccount:${CI_SA_EMAIL}"
  add_project_binding_soft "$role" "serviceAccount:${PROD_SA_EMAIL}"
done

# Operator (human) principal
operator_email_resolved="${OPERATOR_EMAIL:-}"
if [[ -z "$operator_email_resolved" ]]; then
  operator_email_resolved=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE' 2>/dev/null || true)
fi
if [[ -n "$operator_email_resolved" ]]; then
  if [[ "$operator_email_resolved" == *"gserviceaccount.com"* ]]; then
    operator_member="serviceAccount:${operator_email_resolved}"
  else
    operator_member="user:${operator_email_resolved}"
  fi
  info "Ensuring project-level roles for operator: ${operator_member}"
  for role in "${DBT_USER_ROLES[@]}"; do
    add_project_binding_soft "$role" "$operator_member"
  done
else
  info "No operator principal resolved; skipping operator project role grants (set OPERATOR_EMAIL to force)"
fi

# Devs: group and/or per-email from devs.txt
if [[ -n "${DEV_GROUP_EMAIL:-}" ]]; then
  info "Ensuring project-level roles for dev group: group:${DEV_GROUP_EMAIL}"
  for role in "${DBT_USER_ROLES[@]}"; do
    add_project_binding_soft "$role" "group:${DEV_GROUP_EMAIL}"
  done
else
  info "No DEV_GROUP_EMAIL set; skipping dev-group project role grants"
fi

DEVS_FILE="./devs.txt"
if [[ -f "$DEVS_FILE" ]]; then
  info "Ensuring project-level roles for devs listed in ${DEVS_FILE}"
  while IFS= read -r line; do
    line_trimmed="${line%%#*}"
    line_trimmed="${line_trimmed%%*$'\r'}"
    line_trimmed="$(echo "$line_trimmed" | awk '{$1=$1;print}')"
    [[ -z "$line_trimmed" ]] && continue
    email="${line_trimmed%%,*}"
    [[ -z "$email" ]] && continue
    member="user:${email}"
    for role in "${DBT_USER_ROLES[@]}"; do
      add_project_binding_soft "$role" "$member"
    done
  done < "$DEVS_FILE"
else
  info "No devs.txt found; skipping per-dev project role grants"
fi

info "Ensuring dataset-level IAM"
if [[ "${MANAGE_DATASET_IAM:-true}" == "true" ]]; then
if [[ -n "${INT_DATASET:-}" ]]; then
  # CI should be able to write; others query-only
  add_dataset_binding "${INT_DATASET}"  "roles/bigquery.dataViewer" "serviceAccount:${CI_SA_EMAIL}"
  if [[ "${INT_HARDEN_ACL:-true}" == "true" ]]; then
    harden_dataset_acl_writer_only "${INT_DATASET}" "${CI_SA_EMAIL}"
  else
    info "INT_HARDEN_ACL=false; skipping ACL harden on ${INT_DATASET}"
  fi
else
  info "INT_DATASET not set; skipping integration dataset IAM"
fi
add_dataset_binding "${PROD_DATASET}" "roles/bigquery.dataViewer" "serviceAccount:${CI_SA_EMAIL}"
if [[ "${PROD_HARDEN_ACL:-true}" == "true" ]]; then
  harden_dataset_acl_writer_only "${PROD_DATASET}" "${PROD_SA_EMAIL}"
else
  info "PROD_HARDEN_ACL=false; skipping ACL harden on ${PROD_DATASET}"
fi
  info "Dataset IAM step finished"
else
  info "MANAGE_DATASET_IAM=false; skipping dataset IAM bindings"
fi

info "Ensuring bucket IAM for docs"
ensure_bucket_binding "${DOCS_BUCKET_NAME}" "roles/storage.objectAdmin" "serviceAccount:${PROD_SA_EMAIL}"

# If a separate artifacts bucket is defined and differs from DOCS_BUCKET_NAME, grant IAM there too
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" && "${DBT_ARTIFACTS_BUCKET}" != "${DOCS_BUCKET_NAME}" ]]; then
  info "Ensuring bucket IAM for artifacts bucket (${DBT_ARTIFACTS_BUCKET})"
  ensure_bucket_binding "${DBT_ARTIFACTS_BUCKET}" "roles/storage.objectAdmin" "serviceAccount:${PROD_SA_EMAIL}"
fi

# Allow docs viewer SA to read docs (if defined)
if [[ -n "${DOCS_VIEWER_SA_ID:-}" ]]; then
  viewer_email="${DOCS_VIEWER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! gcloud storage buckets get-iam-policy "gs://${DOCS_BUCKET_NAME}" --format=json --project "${PROJECT_ID}" | jq -e --arg m "serviceAccount:${viewer_email}" '.bindings[]? | select(.role=="roles/storage.objectViewer") | .members[]? | select(.==$m)' >/dev/null; then
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
