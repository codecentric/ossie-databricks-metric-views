#!/usr/bin/env bash
# Reproduces the experiment from the article: Databricks Metric View -> Apache Ossie
# -> Metric View (Java converter), then Ossie -> Snowflake / Cube / dbt (Python converters).
#
# Usage: ./scripts/run.sh            (from anywhere; paths are resolved relative to the repo)
# Requires: git, Maven, a JDK 21+ (set JAVA_HOME), Python 3.11+, network access.
set -euo pipefail

OSSIE_REPO="https://github.com/apache/ossie.git"
# Pinned commit (override with OSSIE_COMMIT=<sha or branch> to test another version of Apache Ossie).
OSSIE_COMMIT="${OSSIE_COMMIT:-698272a1973fac137f66a21f8899014ea3208d10}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
OUT="$ROOT/out"

# The Java converter is compiled for Java 21, so a runtime of at least that version is needed.
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}java"
java_major=$("$JAVA_BIN" -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')
if [ "${java_major:-0}" -lt 21 ]; then
  echo "Java 21 or newer is required (found: ${java_major:-none}). Set JAVA_HOME to a JDK 21+." >&2
  exit 1
fi
command -v mvn >/dev/null || { echo "Maven (mvn) is required." >&2; exit 1; }
PYTHON="${PYTHON:-python3}"

rm -rf "$OUT" && mkdir -p "$OUT" "$WORK"

echo "== 1. Fetch Apache Ossie at the pinned commit"
if [ ! -d "$WORK/ossie/.git" ]; then
  git init -q "$WORK/ossie"
  git -C "$WORK/ossie" remote add origin "$OSSIE_REPO"
fi
git -C "$WORK/ossie" fetch -q --depth 1 origin "$OSSIE_COMMIT"
git -C "$WORK/ossie" checkout -q FETCH_HEAD

echo "== 2. Build the Java converter"
(cd "$WORK/ossie/converters/databricks/java" && mvn -q -DskipTests package)
JAR="$(ls "$WORK"/ossie/converters/databricks/java/target/ossie-databricks-converter-*-SNAPSHOT.jar)"
ossie_db() { "$JAVA_BIN" -jar "$JAR" "$@"; }

echo "== 3. Python environment for the validator and the dbt/Cube/Snowflake converters"
# Rebuild the environment on every run so that it always matches the pinned Apache Ossie commit.
rm -rf "$WORK/venv"
"$PYTHON" -m venv "$WORK/venv"
# shellcheck disable=SC1091
source "$WORK/venv/bin/activate"
pip install -q --disable-pip-version-check pyyaml jsonschema sqlglot \
  "$WORK/ossie/python" "$WORK/ossie/converters/dbt" \
  "$WORK/ossie/converters/cube" "$WORK/ossie/converters/snowflake"

cp "$ROOT/input/orders_metric_view.yaml" "$OUT/orders_mv.yaml"
cd "$OUT"

echo "== 4. Metric View -> Ossie -> Metric View (Java)"
ossie_db import orders_mv.yaml --name sales -o orders_ossie.yaml
ossie_db export orders_ossie.yaml -o orders_rt.yaml 2> export_notices.txt
"$PYTHON" "$ROOT/scripts/compare_roundtrip.py" orders_mv.yaml orders_rt.yaml | tee roundtrip_result.txt
"$PYTHON" "$WORK/ossie/validation/validate.py" orders_ossie.yaml | tee validation_result.txt

# The converters below report their findings as warnings and may exit non-zero; the logs are the result.
echo "== 5. Ossie -> Snowflake"
ossie-snowflake -i orders_ossie.yaml -o sf.yaml 2>&1 \
  | sed 's#.*UserWarning: ##' | grep -v 'warnings.warn' > snowflake_log.txt || true

echo "== 6. Ossie -> Cube"
ossie-cube export -i orders_ossie.yaml -o cube_out > cube_log.txt 2>&1 || true

echo "== 7. Ossie -> dbt (MetricFlow)"
ossie-dbt ossie-to-msi -i orders_ossie.yaml -o dbt_manifest.json > dbt_log.txt 2>&1 || true

echo "== 8. Hypothesis: add an ANSI_SQL variant, convert to Snowflake again"
"$PYTHON" "$ROOT/scripts/add_ansi_dialect.py" orders_ossie.yaml orders_ossie_ansi.yaml
ossie-snowflake -i orders_ossie_ansi.yaml -o sf_ansi.yaml 2>&1 \
  | sed 's#.*UserWarning: ##' | grep -v 'warnings.warn' > snowflake_ansi_log.txt || true

echo "== Done. Results are in: $OUT"
if [ -d "$ROOT/expected" ] && [ -n "$(ls -A "$ROOT/expected")" ]; then
  if diff -r "$ROOT/expected" "$OUT" >/dev/null; then
    echo "All outputs match the expected/ directory."
  else
    echo "Differences against expected/ (the converters may have changed):"
    diff -r "$ROOT/expected" "$OUT" | head -40 || true
    exit 2
  fi
fi
