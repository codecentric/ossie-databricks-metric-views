#!/usr/bin/env python3
"""Run one SQL statement on a Databricks SQL warehouse through the Statement Execution API.

Why not `databricks experimental aitools tools query`? That command strips the leading
whitespace of every line of a multi-line statement. A Metric View definition is YAML embedded in
the SQL text (between $$ ... $$), so its indentation would be destroyed and the YAML no longer
parses. The REST API passes the statement through unchanged.

Usage: dbx_sql.py PROFILE WAREHOUSE_ID < statement.sql
Prints the result as JSON ({"columns": [...], "rows": [...]}); on failure prints the error to
stderr and exits with status 1.
"""
import json
import subprocess
import sys
import time


def api(profile, method, path, body=None):
    cmd = ["databricks", "api", method, path, "--profile", profile]
    if body is not None:
        cmd += ["--json", json.dumps(body)]
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError((done.stderr or done.stdout).strip())
    return json.loads(done.stdout)


def main():
    profile, warehouse = sys.argv[1:3]
    statement = sys.stdin.read()
    response = api(profile, "post", "/api/2.0/sql/statements",
                   {"warehouse_id": warehouse, "statement": statement, "wait_timeout": "30s"})
    # A stopped warehouse needs time to start: poll until the statement is finished.
    while response["status"]["state"] in ("PENDING", "RUNNING"):
        time.sleep(3)
        response = api(profile, "get", f"/api/2.0/sql/statements/{response['statement_id']}")
    status = response["status"]
    if status["state"] != "SUCCEEDED":
        error = status.get("error", {})
        print(f"{status['state']}: {error.get('error_code', '')} {error.get('message', '')}".strip(),
              file=sys.stderr)
        sys.exit(1)
    columns = [c["name"] for c in response.get("manifest", {}).get("schema", {}).get("columns", [])]
    print(json.dumps({"columns": columns, "rows": response.get("result", {}).get("data_array", [])}))


if __name__ == "__main__":
    main()
