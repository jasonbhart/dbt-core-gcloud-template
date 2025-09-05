# Use the official dbt-core image as the base (latest 1.10 patch)
FROM ghcr.io/dbt-labs/dbt-core:1.10.8

# Install the dbt-bigquery adapter
RUN pip install "dbt-bigquery==1.10.1"

WORKDIR /app
ENV DBT_PROFILES_DIR=/app/profiles

# Copy core project files and directories needed at runtime (exclude CI scripts)
COPY dbt_project.yml packages.yml macros/ models/ hooks/ ./
# Copy profiles into the expected directory
COPY profiles/ /app/profiles/
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

ENV DBT_TARGET=prod

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
