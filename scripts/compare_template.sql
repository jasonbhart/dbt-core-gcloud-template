-- Compare your dev table to prod to understand impact
-- Set these variables in BigQuery UI or substitute directly
DECLARE dev_project STRING DEFAULT 'my-dev-project';
DECLARE dev_dataset STRING DEFAULT 'analytics_yourname';
DECLARE prod_project STRING DEFAULT 'my-prod-project';
DECLARE prod_dataset STRING DEFAULT 'analytics';
DECLARE table_name  STRING DEFAULT 'fct_example';

-- Row count comparison
SELECT
  (SELECT COUNT(*) FROM `${prod_project}.${prod_dataset}.${table_name}`) AS prod_count,
  (SELECT COUNT(*) FROM `${dev_project}.${dev_dataset}.${table_name}`)  AS dev_count;

-- Differences (EXCEPT DISTINCT)
WITH prod AS (
  SELECT * FROM `${prod_project}.${prod_dataset}.${table_name}`
),
dev AS (
  SELECT * FROM `${dev_project}.${dev_dataset}.${table_name}`
)
SELECT 'in_dev_not_in_prod' AS diff_type, * FROM dev
EXCEPT DISTINCT
SELECT 'in_dev_not_in_prod' AS diff_type, * FROM prod
UNION ALL
SELECT 'in_prod_not_in_dev' AS diff_type, * FROM prod
EXCEPT DISTINCT
SELECT 'in_prod_not_in_dev' AS diff_type, * FROM dev;

