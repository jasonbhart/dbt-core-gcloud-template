{{ config(enabled=false) }}

with s as (
  select * from {{ source('raw', 'example') }}
)
select
  id,
  cast(created_at as timestamp) as created_at_ts,
  value
from s

