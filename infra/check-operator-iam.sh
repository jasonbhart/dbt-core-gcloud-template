#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID in infra/.env}"

account=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE')
if [[ -z "$account" ]]; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 2
fi
if [[ "$account" == *"gserviceaccount.com"* ]]; then
  MEMBER="serviceAccount:${account}"
else
  MEMBER="user:${account}"
fi

echo "Checking operator IAM for ${MEMBER} on project ${PROJECT_ID}"

roles=(
  roles/serviceusage.serviceUsageAdmin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountIamAdmin
  roles/iam.workloadIdentityPoolAdmin
  roles/artifactregistry.admin
  roles/storage.admin
  roles/bigquery.admin
  roles/run.admin
  roles/cloudscheduler.admin
)

missing=()

TMP_PROJ_POLICY="$(mktemp)"
gcloud projects get-iam-policy "$PROJECT_ID" --format=json >"$TMP_PROJ_POLICY"

for role in "${roles[@]}"; do
  if jq -e --arg r "$role" --arg m "$MEMBER" '.bindings[]? | select(.role==$r) | .members[]? | select(.==$m)' "$TMP_PROJ_POLICY" >/dev/null; then
    printf "[OK] %s\n" "$role"
  else
    printf "[MISSING] %s\n" "$role"
    missing+=("$role")
  fi
done

# Optional SA-level checks (serviceAccountUser) if SAs are defined
sa_missing=()
if [[ -n "${PROD_SA_ID:-}" ]]; then
  PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
  TMP_SA="$(mktemp)"
  gcloud iam service-accounts get-iam-policy "$PROD_SA_EMAIL" --format=json >"$TMP_SA" || true
  if jq -e --arg m "$MEMBER" '.bindings[]? | select(.role=="roles/iam.serviceAccountUser") | .members[]? | select(.==$m)' "$TMP_SA" >/dev/null; then
    printf "[OK] roles/iam.serviceAccountUser on %s\n" "$PROD_SA_EMAIL"
  else
    printf "[INFO] You may need roles/iam.serviceAccountUser on %s (or project-level equivalent)\n" "$PROD_SA_EMAIL"
    sa_missing+=("roles/iam.serviceAccountUser@$PROD_SA_EMAIL")
  fi
  rm -f "$TMP_SA"
fi

if [[ -n "${SCHEDULER_SA_ID:-}" ]]; then
  SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
  TMP_SA="$(mktemp)"
  gcloud iam service-accounts get-iam-policy "$SCHED_SA_EMAIL" --format=json >"$TMP_SA" || true
  if jq -e --arg m "$MEMBER" '.bindings[]? | select(.role=="roles/iam.serviceAccountUser") | .members[]? | select(.==$m)' "$TMP_SA" >/dev/null; then
    printf "[OK] roles/iam.serviceAccountUser on %s\n" "$SCHED_SA_EMAIL"
  else
    printf "[INFO] You may need roles/iam.serviceAccountUser on %s (only if impersonating it)\n" "$SCHED_SA_EMAIL"
    sa_missing+=("roles/iam.serviceAccountUser@$SCHED_SA_EMAIL")
  fi
  rm -f "$TMP_SA"
fi

rm -f "$TMP_PROJ_POLICY"

echo
if (( ${#missing[@]} )); then
  echo "Missing project roles:" >&2
  printf ' - %s\n' "${missing[@]}" >&2
fi
if (( ${#sa_missing[@]} )); then
  echo "Service account bindings to consider:" >&2
  printf ' - %s\n' "${sa_missing[@]}" >&2
fi

if (( ${#missing[@]} )); then
  exit 1
else
  echo "Operator IAM looks good."
fi

