#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PROJECT_ID=${PROJECT_ID:?}

EMAILS_ARG=""
# Defaults: do both to be fool‑proof
UPDATE_ENV=1
EXPORT_ENV=1

usage() {
  cat >&2 <<USAGE
Usage: $0 [--email addr1,addr2] [--no-update-env] [--no-export-env]

Creates or reuses Cloud Monitoring email notification channels, then:
 - Updates infra/.env (NOTIFICATION_CHANNELS=...) [default]
 - Exports NOTIFICATION_CHANNELS for your shell (if sourced) or writes infra/.notification_channels.env [default]

Options:
  --email addr1,addr2   Comma-separated emails for channels; otherwise uses DEV_GROUP_EMAIL or active gcloud account
  --no-update-env       Do not write infra/.env
  --no-export-env       Do not export/write .notification_channels.env

Tip: To export into current shell, run: source $0
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      EMAILS_ARG="$2"; shift ;;
    --update-env)
      UPDATE_ENV=1 ;;
    --export-env)
      EXPORT_ENV=1 ;;
    --no-update-env)
      UPDATE_ENV=0 ;;
    --no-export-env)
      EXPORT_ENV=0 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage; exit 2 ;;
  esac
  shift
done

info(){ echo "[info] $*"; }

# Pick monitoring channel command (beta preferred, then alpha)
pick_channels_cmd() {
  if gcloud beta monitoring channels --help >/dev/null 2>&1; then
    echo "gcloud beta monitoring channels"
  elif gcloud alpha monitoring channels --help >/dev/null 2>&1; then
    echo "gcloud alpha monitoring channels"
  else
    echo ""; return 1
  fi
}

CH_CMD=$(pick_channels_cmd) || { echo "gcloud monitoring channels command not available (alpha/beta)." >&2; exit 2; }

# Ensure API
info "Ensuring Monitoring API enabled"
gcloud services enable monitoring.googleapis.com --project "$PROJECT_ID" >/dev/null

# Resolve email list
emails=()
if [[ -n "$EMAILS_ARG" ]]; then
  IFS=',' read -r -a emails <<<"$EMAILS_ARG"
elif [[ -n "${DEV_GROUP_EMAIL:-}" ]]; then
  emails=("$DEV_GROUP_EMAIL")
else
  acct=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE')
  if [[ -z "$acct" ]]; then
    echo "No active gcloud account. Run: gcloud auth login" >&2
    exit 2
  fi
  emails=("$acct")
  echo "[warn] NOTIFICATION_CHANNELS not set and no --email; using active account: $acct" >&2
fi

# Fetch existing channels (JSON)
existing_json=$( $CH_CMD list --format=json --project "$PROJECT_ID" 2>/dev/null || echo '[]' )

channel_names=()
for addr in "${emails[@]}"; do
  addr_trim=$(echo "$addr" | awk '{$1=$1;print}')
  [[ -z "$addr_trim" ]] && continue
  # Try to find existing email channel
  existing_name=$(printf '%s' "$existing_json" | jq -r --arg a "$addr_trim" '.[] | select(.type=="email" and .labels.email_address==$a) | .name' | head -n1)
  if [[ -n "$existing_name" ]]; then
    info "Found existing notification channel for $addr_trim: $existing_name"
    channel_names+=("$existing_name")
    continue
  fi
  info "Creating notification channel for $addr_trim"
  # Create and capture resource name
  new_name=$( $CH_CMD create \
    --type=email \
    --display-name="dbt Alerts: ${addr_trim}" \
    --channel-labels="email_address=${addr_trim}" \
    --project "$PROJECT_ID" \
    --format='value(name)' )
  if [[ -z "$new_name" ]]; then
    echo "[error] Failed to create notification channel for $addr_trim" >&2
    exit 1
  fi
  channel_names+=("$new_name")
done

if (( ${#channel_names[@]} == 0 )); then
  echo "No channels resolved or created." >&2
  exit 1
fi

# Compose CSV of channel resource names
csv=$(IFS=','; echo "${channel_names[*]}")
echo "Notification channel IDs: $csv"

if (( UPDATE_ENV == 1 )); then
  info "Updating infra/.env NOTIFICATION_CHANNELS"
  tmpfile=$(mktemp)
  awk -v val="$csv" '
    BEGIN{updated=0}
    /^NOTIFICATION_CHANNELS=/ { print "NOTIFICATION_CHANNELS=" val; updated=1; next }
    { print }
    END{ if(updated==0) print "NOTIFICATION_CHANNELS=" val }
  ' ./.env > "$tmpfile"
  mv "$tmpfile" ./.env
  echo "Updated NOTIFICATION_CHANNELS in infra/.env"
fi

if (( EXPORT_ENV == 1 )); then
  # If sourced, export into current shell; otherwise write a helper file
  if [[ "${BASH_SOURCE[0]-$0}" != "$0" ]]; then
    export NOTIFICATION_CHANNELS="$csv"
    echo "[info] Exported NOTIFICATION_CHANNELS in current shell"
  else
    out_file=".notification_channels.env"
    printf 'export NOTIFICATION_CHANNELS=%s\n' "$csv" > "$out_file"
    echo "Wrote $out_file. Run: source $out_file to export in your shell."
  fi
fi

echo "Done."
