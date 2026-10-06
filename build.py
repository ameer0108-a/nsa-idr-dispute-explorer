"""
Builds the DuckDB database and the CSV exports for Power BI.

    python build.py

Runs the SQL files in sql/ in order against data/nsa_idr.duckdb, then prints a
short summary. Needs the CMS line-item files in data/raw first
(see scripts/download_cms_data.py).

Takes a couple of minutes on a normal laptop for all four 2025 quarters.
"""

import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
DB_PATH = ROOT / "data" / "nsa_idr.duckdb"
SQL_FILES = [
    "01_load.sql",
    "02_staging.sql",
    "03_data_quality.sql",
    "04_reporting_views.sql",
    "05_export.sql",
]


def main():
    raw_files = sorted((ROOT / "data" / "raw").glob("puf_*_*.csv*"))
    if not raw_files:
        sys.exit("No files in data/raw. Run: python scripts/download_cms_data.py")
    print(f"Found {len(raw_files)} raw files")

    if not (ROOT / "data" / "reference" / "cms_closure_reasons.csv").exists():
        print("Reference CSVs missing, building them from the CMS supplemental tables")
        import runpy
        runpy.run_path(str(ROOT / "scripts" / "extract_cms_aggregates.py"))

    (ROOT / "data" / "exports").mkdir(parents=True, exist_ok=True)

    # Paths in the SQL are relative to the project folder.
    import os
    os.chdir(ROOT)

    con = duckdb.connect(str(DB_PATH))
    # Keeps memory use reasonable on a laptop. DuckDB spills to disk past the limit.
    con.execute("SET memory_limit = '3GB'")
    con.execute("SET preserve_insertion_order = false")
    for name in SQL_FILES:
        t = time.time()
        con.execute((ROOT / "sql" / name).read_text(encoding="utf-8"))
        print(f"  {name:<26} {time.time() - t:6.1f}s")

    print()
    print("Row counts")
    for table in ["raw_line_items", "stg_line_items", "dq_audit", "fct_line_items", "fct_disputes"]:
        n = con.execute(f"select count(*) from {table}").fetchone()[0]
        print(f"  {table:<18} {n:>12,}")

    print()
    print("Data quality")
    rows = con.execute("""
        select check_id, check_name, severity, rows_flagged, share_of_rows
        from v_dq_summary order by check_id
    """).fetchall()
    for r in rows:
        print(f"  {r[0]:<5} {r[1]:<48} {r[2]:<7} {r[3]:>9,}  {r[4]:7.3%}")

    print()
    print("Reconciliation to CMS published payment determinations (raw line-item files)")
    rows = con.execute("""
        select period, dispute_category, cms_published, puf_raw, raw_pct_difference
        from v_reconciliation
        where metric_sort = 1
        order by period_sort, dispute_category
    """).fetchall()
    for r in rows:
        print(f"  {r[0]:<16} {r[1]:<27} CMS {r[2]:>9,}  PUF {r[3]:>9,}  diff {r[4]:+.4%}")

    con.close()
    print()
    print(f"Done. Database: {DB_PATH}")
    print(f"Exports for Power BI: {ROOT / 'data' / 'exports'}")


if __name__ == "__main__":
    main()
