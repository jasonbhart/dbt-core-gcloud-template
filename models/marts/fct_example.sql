{{ config(
  materialized='table',
  partition_by={"field": "created_at_ts", "data_type": "timestamp"},
  cluster_by=['id']
) }}

select
  id,
  value,
  created_at_ts,
  case when value > 100 then 'high' else 'regular' end as bucket
from {{ ref('stg_example') }}
