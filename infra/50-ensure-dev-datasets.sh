#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

UTIL="$(cd .. && pwd)/scripts/utils/create-dev-dataset.sh"
if [[ ! -x "$UTIL" ]]; then
  echo "Utility not found or not executable: $UTIL" >&2
  exit 1
fi

GRANT_FLAG=""
if [[ "${1:-}" == "--grant-job-user" ]]; then
  GRANT_FLAG="--grant-job-user"
fi

account=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE')
if [[ -z "$account" ]]; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 2
fi

echo "Ensuring dev dataset for operator: ${account}"
"$UTIL" "$account" ${GRANT_FLAG:+$GRANT_FLAG}

DEVS_FILE="./devs.txt"
if [[ -f "$DEVS_FILE" ]]; then
  echo "Processing ${DEVS_FILE}..."
  while IFS= read -r line; do
    # Trim and skip empty or comment lines
    line_trimmed="${line%%#*}"
    line_trimmed="${line_trimmed%%*$'\r'}" # strip CR
    line_trimmed="$(echo "$line_trimmed" | awk '{$1=$1;print}')"
    [[ -z "$line_trimmed" ]] && continue
    email="${line_trimmed%%,*}"
    rest="${line_trimmed#*,}"
    if [[ "$rest" == "$line_trimmed" ]]; then
      dataset=""
    else
      dataset="$rest"
    fi
    if [[ -n "$dataset" ]]; then
      echo "Ensuring dev dataset for ${email} (${dataset})"
      "$UTIL" "$email" "$dataset" ${GRANT_FLAG:+$GRANT_FLAG}
    else
      echo "Ensuring dev dataset for ${email} (default naming)"
      "$UTIL" "$email" ${GRANT_FLAG:+$GRANT_FLAG}
    fi
  done < "$DEVS_FILE"
else
  echo "No devs.txt found at ${DEVS_FILE}. To add more devs later, create it with 'email[,dataset]' per line and re-run."
fi

echo "Developer datasets ensured."

