"""
Pulls the quarterly aggregate numbers out of the CMS Federal IDR supplemental
tables (2023 Q1 through 2025 Q4) and writes them to flat CSVs that DuckDB can load.

Why this exists: the line-item PUF files only contain disputes that reached a
payment determination. Anything found ineligible, withdrawn, or settled never
shows up there. So eligibility trends have to come from CMS's own aggregate
tables, not from the line items.

2022 isn't in the supplemental table format. Those numbers come from the two CMS
reports that cover 2022 (initial report for Apr 15 - Sep 30 and the partial report
for Oct - Dec). They're typed in below with the table they came from.

Outputs (data/reference/):
    cms_closure_reasons.csv        Table 5, closed disputes by reason
    cms_payment_outcomes.csv       Table 12, payment determination outcomes
    cms_disputes_initiated.csv     Table 1, disputes initiated

Usage:
    python scripts/extract_cms_aggregates.py
"""

import csv
import re
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "reference" / "cms_source"
OUT = ROOT / "data" / "reference"

CATEGORIES = ["emergency_nonemergency", "air_ambulance", "total"]


def to_num(v):
    """CMS switches between real numbers and text like '46,594' or '42%' between quarters."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return v
    s = str(v).strip().replace(",", "")
    if s in ("", "-", "N/A"):
        return None
    if s.endswith("%"):
        return float(s[:-1]) / 100
    try:
        return float(s) if "." in s else int(s)
    except ValueError:
        return None


def sheet_rows(ws):
    for row in ws.iter_rows(values_only=True):
        vals = [c for c in row if c is not None and str(c).strip() != ""]
        if vals:
            yield vals


def find_table(rows, table_no):
    """Return the rows that sit under 'Table N:' until the next table header."""
    out, on = [], False
    for r in rows:
        first = str(r[0])
        if re.match(rf"Table {table_no}\s*:", first):
            on = True
            continue
        if on and re.match(r"Table \d+\s*:", first):
            break
        if on:
            out.append(r)
    return out


def quarter_from_name(name):
    m = re.search(r"(\d{4})-q(\d)", name)
    return int(m.group(1)), int(m.group(2))


def three_cols(r):
    """Label followed by emergency, air ambulance, total."""
    nums = [to_num(x) for x in r[1:4]]
    return dict(zip(CATEGORIES, nums))


closure, outcomes, initiated = [], [], []

for f in sorted(SRC.glob("federal-idr-supplemental-tables-*.xlsx")):
    year, q = quarter_from_name(f.name)
    wb = openpyxl.load_workbook(f, data_only=True)
    summary = list(sheet_rows(wb["Summary Tables"]))
    pdo = list(sheet_rows(wb["Payment Determination Outcomes"]))

    # Table 5: reasons for closure
    t5 = {str(r[0]).strip(): three_cols(r) for r in find_table(summary, 5) if len(r) >= 4}
    for cat in CATEGORIES:
        closure.append({
            "year": year, "quarter": q, "dispute_category": cat,
            "payment_determinations": t5["Payment Determination Reached"][cat],
            "found_ineligible": t5["Found Ineligible"][cat],
            "other_closed": t5["Other"][cat],
            "total_closed": t5["Total Closed Disputes"][cat],
            "source": f.name + " (Table 5)",
        })

    # Table 1: disputes initiated
    t1 = {str(r[0]).strip(): three_cols(r) for r in find_table(summary, 1) if len(r) >= 4}
    for cat in CATEGORIES:
        initiated.append({
            "year": year, "quarter": q, "dispute_category": cat,
            "disputes_initiated": t1["Total Federal IDR disputes initiated"][cat],
            "source": f.name + " (Table 1)",
        })

    # Table 12: payment determination outcomes. Labels drift a little between
    # quarters, so match on keywords instead of the full sentence.
    t12 = find_table(pdo, 12)
    def pick(keyword):
        for r in t12:
            if keyword.lower() in str(r[0]).lower() and len(r) >= 4:
                return three_cols(r)
        return dict.fromkeys(CATEGORIES)
    tot = pick("Total Payment Determinations")
    prov = pick("Provider, Facility, or Air Ambulance Provider is the Prevailing")
    plan = pick("Health Plan or Issuer is the Prevailing")
    split = pick("Split Decisions")
    one = pick("Only One Party Submitted")
    gtq = pick("Greater than the Qualifying Payment Amount")
    for cat in CATEGORIES:
        outcomes.append({
            "year": year, "quarter": q, "dispute_category": cat,
            "payment_determinations": tot[cat],
            "provider_prevailed": prov[cat],
            "plan_prevailed": plan[cat],
            "split_decisions": split[cat],
            "one_party_offer_only": one[cat],
            "prevailing_offer_above_qpa": gtq[cat],
            "source": f.name + " (Table 12)",
        })

# 2022, typed in from the CMS reports.
# Initial report (Apr 15 - Sep 30, 2022): Table 6 (emergency/non-emergency), Table 13 (air ambulance).
# Partial report (Oct - Dec 2022): Table 2 (all), Table 13 (air ambulance); emergency = all minus air.
INIT = "initial-report-idr-april-15-september-30-2022.pdf"
PART = "partial-report-idr-process-octoberdecember-2022.pdf"
closure_2022 = [
    # (q, category, PD, ineligible, other, total, source)
    (2, "emergency_nonemergency", 282, 1709, 339, 2330, INIT + " (Table 6)"),
    (2, "air_ambulance", 46, 22, 47, 115, INIT + " (Table 13)"),
    (3, "emergency_nonemergency", 3057, 13776, 3031, 19864, INIT + " (Table 6)"),
    (3, "air_ambulance", 191, 388, 219, 798, INIT + " (Table 13)"),
    (4, "emergency_nonemergency", 12015, 9085, 8811, 29911, PART + " (Table 2 minus Table 13)"),
    (4, "air_ambulance", 647, 440, 716, 1803, PART + " (Table 13)"),
]
initiated_2022 = [
    (2, "emergency_nonemergency", 17465, INIT + " (Table 1)"),
    (2, "air_ambulance", 698, INIT + " (Table 1)"),
    (3, "emergency_nonemergency", 69342, INIT + " (Table 1)"),
    (3, "air_ambulance", 2573, INIT + " (Table 1)"),
    (4, "emergency_nonemergency", 103170, PART + " (Table 1)"),
    (4, "air_ambulance", 6864, PART + " (Table 1)"),
]

for q in (2, 3, 4):
    rows = [r for r in closure_2022 if r[0] == q]
    for r in rows:
        closure.append({"year": 2022, "quarter": q, "dispute_category": r[1],
                        "payment_determinations": r[2], "found_ineligible": r[3],
                        "other_closed": r[4], "total_closed": r[5], "source": r[6]})
    closure.append({"year": 2022, "quarter": q, "dispute_category": "total",
                    "payment_determinations": sum(r[2] for r in rows),
                    "found_ineligible": sum(r[3] for r in rows),
                    "other_closed": sum(r[4] for r in rows),
                    "total_closed": sum(r[5] for r in rows),
                    "source": rows[0][6].split(" (")[0] + " (sum of categories)"})
    irows = [r for r in initiated_2022 if r[0] == q]
    for r in irows:
        initiated.append({"year": 2022, "quarter": q, "dispute_category": r[1],
                          "disputes_initiated": r[2], "source": r[3]})
    initiated.append({"year": 2022, "quarter": q, "dispute_category": "total",
                      "disputes_initiated": sum(r[2] for r in irows),
                      "source": irows[0][3]})

# Sanity checks: the parts should add up to the totals CMS printed.
for r in closure:
    parts = r["payment_determinations"] + r["found_ineligible"] + r["other_closed"]
    assert parts == r["total_closed"], f"closure rows don't add up: {r}"


def write(name, rows):
    rows = sorted(rows, key=lambda r: (r["year"], r["quarter"], CATEGORIES.index(r["dispute_category"])))
    with open(OUT / name, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {name}: {len(rows)} rows")


write("cms_closure_reasons.csv", closure)
write("cms_payment_outcomes.csv", outcomes)
write("cms_disputes_initiated.csv", initiated)
