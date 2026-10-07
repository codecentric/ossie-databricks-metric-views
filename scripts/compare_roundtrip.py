#!/usr/bin/env python3
"""Compare two YAML files after parsing, preserving scalar types.

PyYAML follows YAML 1.1, where a bare `on` is a boolean. Metric View joins use
`on` as a key, so booleans are restricted to `true`/`false` here. Exit code 0
means the parsed documents are equal.
"""
import re
import sys

import yaml


class Loader(yaml.SafeLoader):
    pass


Loader.yaml_implicit_resolvers = {
    key: [(tag, rx) for tag, rx in resolvers if tag != "tag:yaml.org,2002:bool"]
    for key, resolvers in Loader.yaml_implicit_resolvers.items()
}
Loader.add_implicit_resolver("tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$"), list("tf"))


def load(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.load(handle, Loader)


if __name__ == "__main__":
    left, right = sys.argv[1:3]
    equal = load(left) == load(right)
    print(f"parsed({left}) == parsed({right})  ->  {equal}")
    sys.exit(0 if equal else 1)
