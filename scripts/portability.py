"""Expression portability test on DuckDB (optional; needs: pip install pyyaml duckdb).

Runs the expressions of the Ossie model, copied verbatim, on DuckDB (the engine MotherDuck is built
on), and shows what the trailing 7-day measure returns with and without its window.
Usage: python scripts/portability.py expected/orders_ossie.yaml

Data: a tiny self-contained orders table (10 days, 2 orders per day) so every result can be
checked by hand. Nothing here needs a warehouse or a network connection.
"""
import sys

import duckdb
import yaml

MODEL = sys.argv[1]
with open(MODEL, encoding="utf-8") as handle:
    model = yaml.safe_load(handle)

expr = {}
for dataset in model["datasets"]:
    for field in dataset["fields"]:
        expr[field["name"]] = field["expression"]["dialects"][0]["expression"]
for metric in model["metrics"]:
    expr[metric["name"]] = metric["expression"]["dialects"][0]["expression"]

con = duckdb.connect()
con.sql("""
CREATE TABLE orders AS
SELECT DATE '1992-01-01' + (i // 2)::INT AS o_orderdate, 100.0 + i AS o_totalprice
FROM range(20) t(i)""")

print("== DuckDB: expressions copied verbatim from the Ossie model")
for name, e in expr.items():
    if name == "customer_name":   # needs the customer table, which this test does not create
        continue
    try:
        rows = con.sql(f"SELECT {e} AS v FROM orders").fetchall()
        extra = f" (first of {len(rows)} rows)" if len(rows) > 1 else ""
        print(f"  OK    {name:20s} {e:38s} -> {rows[0][0]!r}{extra}")
    except Exception as ex:
        print(f"  FAIL  {name:20s} {e:38s} -> {str(ex).splitlines()[0][:90]}")

print("\n== Window measure: correct (windowed) vs flattened to a plain sum")
rows = con.sql("""
SELECT o_orderdate AS order_date,
       SUM(SUM(o_totalprice)) OVER (ORDER BY CAST(o_orderdate AS TIMESTAMP)
         RANGE BETWEEN INTERVAL 7 DAYS PRECEDING AND INTERVAL 1 DAYS PRECEDING) AS windowed,
       SUM(o_totalprice) AS flattened
FROM orders GROUP BY o_orderdate ORDER BY o_orderdate""").fetchall()
print(f"  {'order_date':12s} {'windowed':>10s} {'flattened':>10s}")
for day, windowed, flattened in rows:
    shown = "NULL" if windowed is None else format(float(windowed), ".1f")
    print(f"  {str(day):12s} {shown:>10s} {float(flattened):>10.1f}")

# Independent check: the window is the sum of the daily totals of the 7 days before each day,
# excluding that day. NULL when there is no earlier day.
daily = [float(flattened) for _, _, flattened in rows]
expected = [None if i == 0 else sum(daily[max(0, i - 7):i]) for i in range(len(daily))]
actual = [None if windowed is None else float(windowed) for _, windowed, _ in rows]
assert actual == expected, f"window result differs from the hand computation:\n{actual}\n{expected}"
print("\nCheck passed: the windowed column equals the hand-computed sum of the 7 previous days.")
