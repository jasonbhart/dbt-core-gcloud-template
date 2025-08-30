{% macro generate_schema_name(custom_schema_name, node) -%}
  {%- set base = target.schema -%}
  {%- set user_suffix = env_var('DBT_USER', '') -%}
  {%- if user_suffix and target.name == 'dev' -%}
    {{ base }}_{{ user_suffix | lower }}
  {%- else -%}
    {{ base if custom_schema_name is none else custom_schema_name }}
  {%- endif -%}
{%- endmacro %}

