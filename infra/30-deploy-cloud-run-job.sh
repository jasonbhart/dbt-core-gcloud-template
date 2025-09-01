#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

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

info(){ echo "[info] $*"; }

require_env PROJECT_ID REGION AR_REPO IMAGE_NAME IMAGE_TAG PROD_SA_ID PROD_DATASET BQ_LOCATION

PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}"
IMAGE_URI="${IMAGE_PATH}:${IMAGE_TAG}"

# Resolve artifacts/docs buckets and docs generation toggle
ARTIFACTS_BUCKET="${DBT_ARTIFACTS_BUCKET:-${DOCS_BUCKET_NAME:-}}"
GENERATE_DOCS_FLAG="${GENERATE_DOCS:-true}"
RUN_FRESHNESS_FLAG="${RUN_FRESHNESS:-true}"

# Ensure required CLIs are present
command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
HAVE_DOCKER=1
if ! command -v docker >/dev/null 2>&1; then
  HAVE_DOCKER=0
fi

ensure_ar_repo(){
  if gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
    info "Artifact Registry repo exists: ${AR_REPO} (${REGION})"
  else
    info "Creating Artifact Registry repo: ${AR_REPO} (${REGION})"
    gcloud artifacts repositories create "$AR_REPO" \
      --repository-format=docker \
      --location="$REGION" \
      --description="dbt containers" \
      --project "$PROJECT_ID"
  fi
}

image_tag_exists(){
  # Returns 0 if the specific tag exists, 1 otherwise
  local tag_exists
  tag_exists=$(gcloud artifacts docker tags list "$IMAGE_PATH" \
    --filter="TAG=${IMAGE_TAG}" \
    --format="value(TAG)" \
    --project "$PROJECT_ID" 2>/dev/null || true)
  [[ -n "$tag_exists" ]]
}

ensure_image(){
  if image_tag_exists; then
    info "Image tag exists: ${IMAGE_URI}"
    return 0
  fi
  info "Image tag not found; building and pushing: ${IMAGE_URI}"
  if [[ "$HAVE_DOCKER" -eq 1 ]]; then
    # Ensure Docker is authenticated for Artifact Registry
    gcloud auth configure-docker "${REGION}-docker.pkg.dev" -q >/dev/null
    # Build from repo root
    pushd "$(dirname "$PWD")" >/dev/null
    docker build -t "$IMAGE_URI" .
    docker push "$IMAGE_URI"
    popd >/dev/null
  else
    info "docker not found; using Cloud Build to build and push"
    # Ensure Cloud Build API is enabled
    gcloud services enable cloudbuild.googleapis.com --project "$PROJECT_ID" >/dev/null
    # Submit build from repo root
    pushd "$(dirname "$PWD")" >/dev/null
    gcloud builds submit --region="$REGION" --tag "$IMAGE_URI" --project "$PROJECT_ID"
    popd >/dev/null
  fi
}

ensure_ar_repo
ensure_image

env_kvs=(
  "DBT_TARGET=prod"
  "DBT_GCP_PROJECT_PROD=${PROJECT_ID}"
  "DBT_BQ_DATASET_PROD=${PROD_DATASET}"
  "DBT_BQ_LOCATION=${BQ_LOCATION}"
  "GENERATE_DOCS=${GENERATE_DOCS_FLAG}"
  "RUN_FRESHNESS=${RUN_FRESHNESS_FLAG}"
)
if [[ -n "${ARTIFACTS_BUCKET}" ]]; then
  env_kvs+=("DBT_ARTIFACTS_BUCKET=${ARTIFACTS_BUCKET}")
fi
if [[ -n "${DOCS_BUCKET_NAME:-}" ]]; then
  env_kvs+=("DOCS_BUCKET_NAME=${DOCS_BUCKET_NAME}")
fi
if [[ -n "${FRESHNESS_SELECT:-}" ]]; then
  env_kvs+=("FRESHNESS_SELECT=${FRESHNESS_SELECT}")
fi
ENV_VARS="$(IFS=,; echo "${env_kvs[*]}")"

info "Deploying Cloud Run Job 'dbt-prod-run' with image: ${IMAGE_URI}"
gcloud run jobs deploy dbt-prod-run \
  --image="${IMAGE_URI}" \
  --region="${REGION}" \
  --service-account="${PROD_SA_EMAIL}" \
  --tasks=1 \
  --parallelism=1 \
  --max-retries=1 \
  --task-timeout=3600s \
  --set-env-vars="${ENV_VARS}" \
  --project "${PROJECT_ID}"

info "Cloud Run Job deployed."

info "Tip: verify SA/envs with:  gcloud run jobs describe dbt-prod-run --region ${REGION} --project ${PROJECT_ID}"
