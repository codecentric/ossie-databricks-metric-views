#!/usr/bin/env python3
"""Add an ANSI_SQL variant next to every DATABRICKS expression in an Ossie model.

The `order_month` field is skipped on purpose: DATE_TRUNC('MONTH', ...) is not
portable ANSI SQL, so it stays Databricks-only.

Usage: add_ansi_dialect.py INPUT.yaml OUTPUT.yaml
"""
import sys

import yaml

SKIP = {"order_month"}


def add_variant(element):
    expression = element.get("expression")
    if expression and element["name"] not in SKIP:
        dialects = expression["dialects"]
        dialects.append({"dialect": "ANSI_SQL", "expression": dialects[0]["expression"]})


with open(sys.argv[1], encoding="utf-8") as handle:
    model = yaml.safe_load(handle)

for dataset in model["datasets"]:
    for field in dataset.get("fields", []):
        add_variant(field)
for metric in model["metrics"]:
    add_variant(metric)

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    yaml.safe_dump(model, handle, sort_keys=False)
