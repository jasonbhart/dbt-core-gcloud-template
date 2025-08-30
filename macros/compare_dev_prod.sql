{% macro dev_prod_diff(table_name, dev_project=None, prod_project=None, dev_dataset_prefix='analytics_', dev_dataset=None, prod_dataset=None, limit=100, execute_query=True) %}
  {#
    Compare a dev table (derived from DBT_USER) vs prod using EXCEPT DISTINCT and counts.
    Usage:
      dbt run-operation dev_prod_diff --args '{"table_name":"fct_example"}'
    Optional args:
      dev_project, prod_project, dev_dataset_prefix, prod_dataset, execute_query (bool)
  #}

  {% set user = env_var('DBT_USER') %}
  {% if not user %}
    {{ exceptions.raise_compiler_error("DBT_USER is not set. Export DBT_USER to derive the dev dataset.") }}
  {% endif %}

  {% set _dev_project = dev_project or target.project %}
  {% set _prod_project = prod_project or env_var('DBT_GCP_PROJECT_PROD') or target.project %}
  {% set _dev_dataset = dev_dataset or (dev_dataset_prefix ~ user) %}
  {% set _prod_dataset = prod_dataset or env_var('DBT_BQ_DATASET_PROD', 'analytics_prod') %}

  {# counts #}
  {% set counts_sql %}
    SELECT
      (SELECT COUNT(*) FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`) AS prod_count,
      (SELECT COUNT(*) FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`)  AS dev_count
  {% endset %}

  {% set diff_counts_sql %}
    WITH prod AS (
      SELECT * FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`
    ),
    dev AS (
      SELECT * FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
    )
    SELECT
      (SELECT COUNT(*) FROM (SELECT * FROM dev EXCEPT DISTINCT SELECT * FROM prod)) AS dev_not_in_prod,
      (SELECT COUNT(*) FROM (SELECT * FROM prod EXCEPT DISTINCT SELECT * FROM dev)) AS prod_not_in_dev
  {% endset %}

  {% set diffs_sql %}
    WITH prod AS (
      SELECT * FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`
    ),
    dev AS (
      SELECT * FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
    )
    SELECT 'in_dev_not_in_prod' AS diff_type, * FROM dev
    EXCEPT DISTINCT
    SELECT 'in_dev_not_in_prod' AS diff_type, * FROM prod
    UNION ALL
    SELECT 'in_prod_not_in_dev' AS diff_type, * FROM prod
    EXCEPT DISTINCT
    SELECT 'in_prod_not_in_dev' AS diff_type, * FROM dev
    {% if limit|int > 0 %}
    LIMIT {{ limit|int }}
    {% endif %}
  {% endset %}

  {% if execute_query %}
    {% do log('Comparing ' ~ _dev_project ~ '.' ~ _dev_dataset ~ '.' ~ table_name ~ ' vs ' ~ _prod_project ~ '.' ~ _prod_dataset ~ '.' ~ table_name, info=True) %}
    {% set counts = run_query(counts_sql) %}
    {% set diff_counts = run_query(diff_counts_sql) %}
    {% set prod_count = counts.columns[0].values()[0] %}
    {% set dev_count = counts.columns[1].values()[0] %}
    {% set dev_not_in_prod = diff_counts.columns[0].values()[0] %}
    {% set prod_not_in_dev = diff_counts.columns[1].values()[0] %}
    {% set summary = 'SUMMARY|' ~ 'table=' ~ table_name ~ '|dev=' ~ dev_count ~ '|prod=' ~ prod_count ~ '|dev_not_in_prod=' ~ dev_not_in_prod ~ '|prod_not_in_dev=' ~ prod_not_in_dev %}
    {% do log(summary, info=True) %}
    {% do log('Showing up to ' ~ (limit|int) ~ ' diff rows (set limit arg to control).', info=True) %}
    {% set sample = run_query(diffs_sql) %}
    {% do log(sample, info=True) %}
  {% else %}
    {% do log('-- Counts', info=True) %}
    {% do log(counts_sql, info=True) %}
    {% do log('-- Diff counts', info=True) %}
    {% do log(diff_counts_sql, info=True) %}
    {% do log('-- Diff sample', info=True) %}
    {% do log(diffs_sql, info=True) %}
  {% endif %}

{% endmacro %}

{% macro dev_prod_diff_for_model(model_name, dev_project=None, prod_project=None, dev_dataset_prefix='analytics_', dev_dataset=None, prod_dataset=None, limit=100, execute_query=True) %}
  {# Resolve the relation for the model in the current target to get its identifier #}
  {% set rel = ref(model_name) %}
  {% set identifier = rel.identifier %}
  {% set _dev_project = dev_project or rel.database or target.project %}
  {% do dev_prod_diff(identifier, dev_project=_dev_project, prod_project=prod_project, dev_dataset_prefix=dev_dataset_prefix, dev_dataset=dev_dataset, prod_dataset=prod_dataset, limit=limit, execute_query=execute_query) %}
{% endmacro %}
