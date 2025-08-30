#!/usr/bin/env bash
set -euo pipefail

echo "Starting container at $(date -Is)"
echo "DBT_TARGET=${DBT_TARGET:-prod}"

if [[ "${RUN_PRE_HOOK:-false}" == "true" ]]; then
  echo "Running pre_run.py ..."
  python hooks/pre_run.py
fi

dbt deps

DBT_BUILD_ARGS="${DBT_BUILD_ARGS:-}"
echo "dbt build --target ${DBT_TARGET} ${DBT_BUILD_ARGS}"
dbt build --target "${DBT_TARGET}" ${DBT_BUILD_ARGS}

if [[ "${GENERATE_DOCS:-false}" == "true" ]]; then
  dbt docs generate --static
  echo "Docs available in ./target/index.html"
fi

if [[ "${RUN_POST_HOOK:-false}" == "true" ]]; then
  echo "Running post_run.py ..."
  python hooks/post_run.py
fi

echo "Completed at $(date -Is)"

