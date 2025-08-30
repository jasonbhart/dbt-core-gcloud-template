#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/compare.sh fct_example [dev_project] [prod_project]
# Requires DBT_USER to be set to derive dev dataset (analytics_${DBT_USER} by default)

TABLE="${1:-}"
DEV_PROJECT="${2:-}"
PROD_PROJECT="${3:-}"

if [[ -z "$TABLE" ]]; then
  echo "Usage: $0 <table_name> [dev_project] [prod_project]"
  exit 1
fi

ARGS=("table_name: '$TABLE'")
[[ -n "$DEV_PROJECT" ]] && ARGS+=("dev_project: '$DEV_PROJECT'")
[[ -n "$PROD_PROJECT" ]] && ARGS+=("prod_project: '$PROD_PROJECT'")

dbt run-operation dev_prod_diff --args "{ ${ARGS[*]} }"

