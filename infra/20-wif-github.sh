#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

POOL_ID="github-pool"
PROVIDER_ID="github-provider"

CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

require_env(){ for v in "$@"; do [[ -z "${!v:-}" ]] && { echo "Missing env: $v"; exit 1; }; done; }
require_env PROJECT_ID PROJECT_NUMBER GITHUB_REPO CI_SA_ID

echo "== Ensure Workload Identity Pool =="
if gcloud iam workload-identity-pools describe "${POOL_ID}" --location=global --project "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Pool exists: ${POOL_ID}"
else
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project "${PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions pool"
fi

echo "== Ensure OIDC provider for GitHub with repo scoping =="
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" --location=global --workload-identity-pool="${POOL_ID}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  # Update mapping/condition to match desired state (safe if unchanged)
  gcloud iam workload-identity-pools providers update-oidc "${PROVIDER_ID}" \
    --project "${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.aud=assertion.aud,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'" >/dev/null
  echo "Provider exists and updated: ${PROVIDER_ID}"
else
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project "${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.aud=assertion.aud,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
fi

echo "== Ensure repo can impersonate CI service account =="
WIF_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
TMP_JSON="$(mktemp)"
gcloud iam service-accounts get-iam-policy "${CI_SA_EMAIL}" --format=json >"$TMP_JSON"
if jq -e --arg member "principalSet://iam.googleapis.com/${WIF_RESOURCE}/attribute.repository/${GITHUB_REPO}" '.bindings[]? | select(.role=="roles/iam.workloadIdentityUser") | .members[]? | select(.==$member)' "$TMP_JSON" >/dev/null; then
  echo "WorkloadIdentityUser binding already exists."
else
  gcloud iam service-accounts add-iam-policy-binding "${CI_SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/${WIF_RESOURCE}/attribute.repository/${GITHUB_REPO}"
fi
rm -f "$TMP_JSON"

echo "== Output values for GitHub workflows =="
echo "workload_identity_provider=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
echo "service_account=${CI_SA_EMAIL}"

echo "WIF configured."
