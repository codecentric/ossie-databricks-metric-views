# Results

What was tested, what came out, and how sure we are. Every row points to the file in this repository that shows it.

**Tested against**

- Apache Ossie at commit `698272a` (8 October 2026). The first run used `891f007` (6 October); the outputs were identical.
- Java Databricks converter `0.1.0-SNAPSHOT`, built from that commit with Maven, run on JDK 27. The Snowflake and Cube converters are the Python packages from the same commit. Ossie model version `0.2.0.dev0`.
- Databricks deployment on 7 October 2026: Azure Databricks, serverless SQL warehouse, CLI v1.10.0.
- DuckDB 1.4.4.

**Status labels**

| Label | Meaning |
|---|---|
| Verified by run | Produced by a script in this repository; the output is committed |
| Observed | Seen once in a session; no script or output in this repository |
| Converter message | The converter reports it; not checked in the target tool |
| Deduction | Follows from the committed outputs; not run in the target tool |

## A. Databricks: round trip and deployment

| # | Test | Result | Evidence | Status |
|---|---|---|---|---|
| A1 | Metric View to Ossie to Metric View (Java converter) | The parsed documents are equal. The files differ only in formatting: the Java converter writes every string double-quoted | `expected/roundtrip_result.txt`, `expected/orders_mv.yaml` vs `expected/orders_rt.yaml` | Verified by run |
| A2 | Validate the Ossie model with the repository's validator | Passed | `expected/validation_result.txt` | Verified by run |
| A3 | Features without a native Ossie field | Kept as JSON strings under `custom_extensions` with `vendor_name: DATABRICKS`: the filter (model level), format and display name (metric), window (metric), `rely` hint (relationship) | `expected/orders_ossie.yaml` | Verified by run |
| A4 | Export notices | One notice: the key declarations were used to set the join's `rely` hint | `expected/export_notices.txt` | Verified by run |
| A5 | Deploy the exported Metric View unchanged (YAML version 1.1 with `window`, `format`, `filter`, `rely`) | Accepted | `expected_databricks/01_create.json` | Verified by run, once |
| A6 | Query the deployed view | 7,500,000 orders, total revenue 1,133,439,215,246.25, and a dimension from the joined customer table returned 3 rows | `expected_databricks/02_measures.json`, `03_joined_dimension.json` | Verified by run, once |
| A7 | Window measure `revenue_trailing_7d` against a hand-written window query | Equal on all 10 compared rows; `NULL` on the first day (no earlier day) | `expected_databricks/04_window_vs_plain.json`, `05_manual_window.json` | Verified by run, once |
| A8 | Does the sample filter `o_orderstatus <> 'X'` remove rows? | No. The view counts 7,500,000 orders, the same as a `SELECT COUNT(*)` on the source table (that count was read in the session and is not saved), so the filter says nothing about the effect of a filter | `expected_databricks/02_measures.json` | Verified by run, once |

The window measure sums the 7 days before the current day and excludes the current day. These are the values for the first ten days, next to what a plain daily sum would show:

| order_date | `revenue_trailing_7d` (Databricks) | Plain daily total | Daily total is too low by |
|---|---|---|---|
| 1992-01-01 | NULL | 473,331,645.16 | - |
| 1992-01-02 | 473,331,645.16 | 469,591,815.87 | 1.0x |
| 1992-01-03 | 942,923,461.03 | 473,322,334.28 | 2.0x |
| 1992-01-04 | 1,416,245,795.31 | 484,471,441.56 | 2.9x |
| 1992-01-05 | 1,900,717,236.87 | 477,282,487.03 | 4.0x |
| 1992-01-06 | 2,377,999,723.90 | 461,257,031.03 | 5.2x |
| 1992-01-07 | 2,839,256,754.93 | 478,072,557.82 | 5.9x |
| 1992-01-08 | 3,317,329,312.75 | 477,486,461.82 | 6.9x |
| 1992-01-09 | 3,321,484,129.41 | 478,022,079.38 | 6.9x |
| 1992-01-10 | 3,329,914,392.92 | 463,690,636.01 | 7.2x |

The two queries behind the comparison (the second is what a definition without the window amounts to):

```sql
-- Windowed: sum of the daily totals of the 7 days before the current day
SELECT o_orderdate AS order_date,
       SUM(SUM(o_totalprice)) OVER (
         ORDER BY CAST(o_orderdate AS TIMESTAMP)
         RANGE BETWEEN INTERVAL 7 DAYS PRECEDING AND INTERVAL 1 DAYS PRECEDING
       ) AS revenue_trailing_7d
FROM samples.tpch.orders GROUP BY o_orderdate;

-- Flattened: only the aggregate remains
SELECT o_orderdate AS order_date, SUM(o_totalprice) AS revenue_trailing_7d
FROM samples.tpch.orders GROUP BY o_orderdate;
```

## B. Ossie to other tools

The Ossie model comes from A1. All expressions in it are written in the `DATABRICKS` dialect only.

| # | Test | Result | Evidence | Status |
|---|---|---|---|---|
| B1 | Snowflake converter on the model | All 6 fields and metrics skipped (no Snowflake-compatible expression; it accepts `SNOWFLAKE`, `ANSI_SQL`, `OSSIE_SQL_2026`). Kept: tables, the relationship, the unique key. The custom extensions of the relationship and of the model were dropped, with a notice | `expected/snowflake_log.txt`, `expected/sf.yaml` | Verified by run |
| B2 | Same, after adding an `ANSI_SQL` expression next to each `DATABRICKS` one (`scripts/add_ansi_dialect.py`; `order_month` left Databricks-only, because `DATE_TRUNC('MONTH', ...)` is not portable ANSI SQL) | 3 metrics and 2 of 3 fields kept (written as Snowflake `facts`); only `order_month` skipped | `expected/snowflake_ansi_log.txt`, `expected/sf_ansi.yaml`, `expected/orders_ossie_ansi.yaml` | Verified by run |
| B3 | The window metric in the B2 output | `revenue_trailing_7d` is `SUM(o_totalprice)`, identical to `total_revenue`. The only trace is a generic notice that the metric's custom extensions were dropped | `expected/sf_ansi.yaml`, `expected/snowflake_ansi_log.txt` | Verified by run |
| B4 | Cube converter on the model | 15 conversion issues: 11 approximated, 3 parked in `meta`, 1 dropped (no primary key for the cube that declares a join) | `expected/cube_log.txt` | Verified by run |
| B5 | The window metric in the Cube output | A plain `sum` of `o_totalprice` without `rolling_window`. The view filter is not applied. Neither is mentioned among the 15 issues | `expected/cube_out/model/cubes/sales.yml` | Verified by run |
| B6 | Where the Databricks window, format and filter went in the Cube output | Kept as opaque JSON in `meta` blocks, like the unique keys and the join hint. Cube does not interpret them | `expected/cube_out/model/` | Verified by run |
| B7 | Would the Cube model compile? | The converter says it would not, until the cube declares a primary key | `expected/cube_log.txt` | Converter message |
| B8 | What a flattened metric returns in Snowflake or Cube | The daily total, too low by 1.0x to 7.2x over the first ten days (table in section A) | B3, B5 and section A | Deduction |

**Why the window is lost.** In a Metric View, the aggregate (`expr: SUM(o_totalprice)`) and the window (`window: ... range: trailing 7 day`) are separate fields of one measure. An Ossie metric has only `name`, `expression` (one per dialect), `description`, `datatype`, `ai_context` and `custom_extensions`. At the pinned commit, the word "window" does not occur in `core-spec/spec.md`, `ossie-schema.json` or `spec.yaml`; a newer version was not checked. The importer therefore keeps `SUM(o_totalprice)` as the expression and stores the window as a vendor payload, which the other converters treat as foreign. Cube itself offers rolling windows (`rolling_window` with `trailing` and `leading`, according to its documentation), so for Cube the gap is in the converter, not in the target format. Whether Snowflake can express such a window was not checked.

## C. Portability to another engine

| # | Test | Result | Evidence | Status |
|---|---|---|---|---|
| C1 | Run the model's expressions verbatim on DuckDB (the engine MotherDuck is built on): `DATE_TRUNC('MONTH', ...)`, `SUM`, `COUNT(*)` | All run unchanged | `portability/duckdb_result.txt` | Verified by run |
| C2 | Windowed against flattened measure on DuckDB (tiny inline table) | Same behavior as on Databricks: windowed 201, 406, 615 ... 1,547 on the tenth day, flattened 201 ... 237. The script checks the windowed column against an independent computation | `portability/duckdb_result.txt` | Verified by run |

## D. Tooling observations

| # | Observation | Evidence | Status |
|---|---|---|---|
| D1 | `databricks experimental aitools tools query` (CLI v1.10.0) strips the leading whitespace of the lines of a multi-line statement. A Metric View is YAML inside `$$ ... $$`, so the indentation is lost and Databricks reports `Failed to parse YAML ... expected <block end>, but found '-'`. Three variants of the same content (as exported, SQL read from a file, re-indented) failed identically. The REST Statement Execution API keeps the text unchanged and the same file deployed (A5) | `scripts/dbx_sql.py`; no output of the failed attempts is kept | Observed |
| D2 | The Java converter needs Java 21 or newer; with Java 17 it fails with `UnsupportedClassVersionError` (class file version 65) | `scripts/run.sh` checks the version | Observed |
| D3 | The Python and the Java importer produced equivalent Ossie models for the same Metric View (parsed equal; the Java file only quotes every string). A one-off check on the first commit; the Python importer is not part of the scripts here | none | Observed |
| D4 | A run on the newer commit `698272a` gave the same outputs as the first run on `891f007` | the reference outputs were produced on `891f007` and still match | Verified by run |
| D5 | A run from a fresh clone of this repository matched the reference outputs | none (a one-off run) | Observed |

## E. Not tested

- **MotherDuck itself.** Only DuckDB was run (C1, C2).
- **BigQuery.** Test queries were prepared from the BigQuery documentation but have not been run, so there are no results.
- **Loading the Snowflake and Cube outputs into those tools.** B7 and B8 rest on the generated files and the converters' own messages.
- **A repeat of the Databricks deployment** (A5 to A7) after 7 October 2026, on another warehouse or with another Ossie version.
- **Anything beyond this model.** One small model, one converter version, development-stage software. The findings are illustrative, not a benchmark.
- **Newer Apache Ossie versions.** As of 9 November 2026 the converters live in a separate repository, `apache/ossie-converters`; results may differ there. See the README.
