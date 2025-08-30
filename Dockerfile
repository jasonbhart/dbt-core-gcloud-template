FROM ghcr.io/dbt-labs/dbt-bigquery:1.9.latest

WORKDIR /app
ENV DBT_PROFILES_DIR=/app/profiles

COPY dbt_project.yml packages.yml profiles/ macros/ models/ hooks/ scripts/ ./
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

ENV DBT_TARGET=prod

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]

