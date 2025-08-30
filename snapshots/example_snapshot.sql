{% snapshot example_snapshot %}
  {{ config(
      target_schema=target.schema,
      unique_key='id',
      strategy='timestamp',
      updated_at='created_at_ts'
  ) }}

  select * from {{ ref('fct_example') }}

{% endsnapshot %}

