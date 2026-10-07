# Apache Ossie and Databricks Metric Views: reproducing the experiment

This repository accompanies the codecentric blog article *Apache Ossie and Databricks Metric Views: What Survives the Round Trip* (link to follow once published).

It converts a small Databricks Unity Catalog Metric View into an [Apache Ossie](https://github.com/apache/ossie) (incubating) semantic model and back, and then hands the Ossie model to the Snowflake, Cube and dbt (MetricFlow) converters to see what is lost on the way.

## What the experiment shows

- **Round trip:** Metric View to Ossie and back to a Metric View yields an equal document. Features without a native Ossie field (view filter, currency format, window measure, join `rely` hint) are carried as `custom_extensions` payloads.
- **Other targets:** the converters differ in how much they keep and how openly they report loss. In the run described in the article, the dbt and Cube outputs turn the trailing-window measure `revenue_trailing_7d` into a plain sum without mentioning it, and the Snowflake converter skips all expressions until an `ANSI_SQL` variant is added.

See the article for the interpretation. The scripts here only produce the evidence.

## Run it

Prerequisites: `git`, Maven, **JDK 21 or newer** (the Java converter is compiled for Java 21), Python 3.11 or newer, network access.

```bash
export JAVA_HOME=/path/to/jdk-21-or-newer   # if your default java is older
./scripts/run.sh
```

The script:

1. fetches `apache/ossie` at the pinned commit `891f007945b5666464a45e2c75c1a0a8be9cd7f7` into `work/`;
2. builds the Java Databricks converter with Maven;
3. creates a Python virtual environment with the Ossie validator and the dbt, Cube and Snowflake converters;
4. converts `input/orders_metric_view.yaml` to Ossie and back, validates the Ossie model, and compares the original with the re-export;
5. converts the Ossie model to Snowflake, Cube and dbt;
6. repeats the Snowflake conversion after adding an `ANSI_SQL` variant to the expressions;
7. compares everything in `out/` with the reference outputs in `expected/`.

Generated files are written to `out/`. The first run takes a few minutes (Maven and pip downloads).

## Layout

| Path | Content |
|------|---------|
| `input/orders_metric_view.yaml` | The sample Metric View over `samples.tpch.orders` with one joined table |
| `scripts/run.sh` | The whole experiment |
| `scripts/compare_roundtrip.py` | Type-preserving comparison of two YAML files |
| `scripts/add_ansi_dialect.py` | Adds `ANSI_SQL` expression variants to an Ossie model |
| `expected/` | Reference outputs from the run described in the article |

## Limits

- The sample Metric View was **not deployed to a Databricks workspace**. Databricks documents window measures as experimental, with examples under YAML version 0.1, while the sample uses version 1.1. Treat the results as a statement about the converters, not about Unity Catalog behaviour.
- The converters are development-stage software (Ossie model version `0.2.0.dev0`). Later versions may behave differently. A difference against `expected/` is therefore an informative result and not necessarily an error.
- One small model, one converter version. The findings are illustrative, not a benchmark.

## Licence

Apache License 2.0, see [LICENSE](LICENSE). Apache Ossie and its converters are separate Apache Software Foundation projects and are fetched at run time, not redistributed here.
