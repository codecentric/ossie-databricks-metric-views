#!/usr/bin/env bash
# Optional: deploy the Metric View exported by the Java converter to a real Databricks workspace,
# query it, and drop it again.
#
# Usage:
#   ./scripts/databricks_test.sh <databricks-profile> <catalog.schema> [warehouse-id]
# Example:
#   ./scripts/databricks_test.sh my-profile main.scratch
#
# Requires: Databricks CLI >= 0.292 with a valid profile, a SQL warehouse, SELECT on
# samples.tpch.orders / samples.tpch.customer, and CREATE TABLE + USE SCHEMA on <catalog.schema>.
# Metric views need Databricks Runtime 17.2+ (YAML 1.1) and 17.3+ for synonyms/display_name/format.
#
# The view is named ossie_orders_mv_test and is dropped on exit, also if a step fails.
# Statements are sent through the REST Statement Execution API (scripts/dbx_sql.py) because
# `databricks experimental aitools tools query` strips the indentation of multi-line statements,
# which breaks the YAML inside the Metric View definition.
set -uo pipefail

PROFILE="${1:?usage: $0 <databricks-profile> <catalog.schema> [warehouse-id]}"
SCHEMA="${2:?usage: $0 <databricks-profile> <catalog.schema> [warehouse-id]}"
WAREHOUSE="${3:-$(databricks experimental aitools tools get-default-warehouse --profile "$PROFILE")}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="$ROOT/expected/orders_rt.yaml"   # the file the Java converter exported from the Ossie model
VIEW="$SCHEMA.ossie_orders_mv_test"
OUT="$ROOT/databricks_out"
mkdir -p "$OUT"

sql() { printf '%s' "$1" | python3 "$ROOT/scripts/dbx_sql.py" "$PROFILE" "$WAREHOUSE"; }
cleanup() { echo "== Cleanup: drop $VIEW"; sql "DROP VIEW IF EXISTS $VIEW" > /dev/null 2>&1; }
trap cleanup EXIT

echo "== 1. Deploy the exported Metric View (YAML version 1.1) as $VIEW (warehouse $WAREHOUSE)"
sql "CREATE OR REPLACE VIEW $VIEW WITH METRICS LANGUAGE YAML AS \$\$
$(cat "$YAML")
\$\$" | tee "$OUT/01_create.json" || { echo "Deployment failed: see the message above."; exit 1; }

echo "== 2. Query the measures"
sql "SELECT MEASURE(total_revenue) AS total_revenue, MEASURE(order_count) AS order_count FROM $VIEW" \
  | tee "$OUT/02_measures.json"

echo "== 3. Dimension from the joined table"
sql "SELECT customer_name, MEASURE(total_revenue) AS total_revenue FROM $VIEW GROUP BY customer_name ORDER BY total_revenue DESC LIMIT 3" \
  | tee "$OUT/03_joined_dimension.json"

echo "== 4. Window measure vs plain sum, first 10 days of the dataset (the semantics dbt/Cube/Snowflake lose)"
sql "SELECT order_date, MEASURE(total_revenue) AS total_revenue, MEASURE(revenue_trailing_7d) AS revenue_trailing_7d
     FROM $VIEW GROUP BY order_date ORDER BY order_date LIMIT 10" \
  | tee "$OUT/04_window_vs_plain.json"

echo "== 5. Hand-written window query for comparison (7 days before the current day, same 10 days)"
sql "SELECT o_orderdate AS order_date, SUM(o_totalprice) AS total_revenue,
            SUM(SUM(o_totalprice)) OVER (ORDER BY CAST(o_orderdate AS TIMESTAMP)
              RANGE BETWEEN INTERVAL 7 DAYS PRECEDING AND INTERVAL 1 DAYS PRECEDING) AS trailing_7d_excl_current
     FROM samples.tpch.orders WHERE o_orderstatus <> 'X' GROUP BY o_orderdate ORDER BY o_orderdate LIMIT 10" \
  | tee "$OUT/05_manual_window.json"

echo "== Done. Raw results are in $OUT (the view is dropped now)."
