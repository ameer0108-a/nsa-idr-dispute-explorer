# No Surprises Act Dispute Data Explorer

SQL (DuckDB) and Power BI project built on the CMS Federal IDR public use files for all of 2025.

The No Surprises Act sends out-of-network billing disputes between providers and health plans to "baseball style" arbitration: each side submits an offer and a certified IDR entity picks one. CMS publishes every closed payment determination at the line-item level each quarter. I wanted to see who wins, by how much compared to the QPA (the qualifying payment amount, basically the plan's median in-network rate), and how much of the process the public line-item files actually show.

## What's in here

- A DuckDB model built from all four 2025 quarters: 5,783,034 line items across 2,227,266 disputes.
- 9 data quality checks. Every row that fails one is logged to an audit table (1.9% of rows). The 0.9% that fail a reject-level check are kept out of reporting.
- A reconciliation of dispute counts to the totals CMS publishes in its supplemental tables. The full year matches within 20 disputes (0.001%), and the biggest gap in any single quarter is 0.008%.
- 12 SQL views that feed a three-page Power BI report.
- An eligibility trend rebuilt from CMS aggregate tables. The line-item files leave out disputes that were found ineligible, so they can't show eligibility at all.

## Main findings (2025 unless noted)

- Providers won 86.7% of the disputes that reached a decision.
- The median winning offer was 3.97 times the QPA, and 92% of winning offers were above the QPA.
- The spread by service is wide. Neurology and neuromonitoring codes had a median winning offer of 24.4 times the QPA, surgery 14.0 times, and emergency department visits 3.2 times.
- Disputes are concentrated. Texas accounts for 39% of disputes and 44% of line items, and the top two filers by email domain (halomd.com and teamhealth.com) filed about 31% of all disputes.
- Decisions got faster during the year. The median went from 41 business days from filing in Q1 to 23 in Q4, and the share decided by default fell from 23% to 13%.
- Ineligible disputes fell from 69% of closed disputes (April to September 2022) to 18% in 2025. Only payment determinations appear in the line-item files, which in 2025 was about 80% of closed disputes.
- Practice size is reported on the provider's offer form. When it's missing, the provider almost always lost (1.8% win rate), because a missing size usually means the provider never submitted an offer.

## Folder layout

```
build.py                      runs the SQL in order and writes the exports
sql/
  01_load.sql                 raw CSVs and reference tables
  02_staging.sql              typed, renamed line items plus the CPT to specialty map
  03_data_quality.sql         the 9 checks, dq_audit, fct_line_items, fct_disputes
  04_reporting_views.sql      the 12 views the report uses
  05_export.sql               writes each view to data/exports as CSV
scripts/
  download_cms_data.py        pulls the 2025 line-item CSVs from CMS into data/raw
  extract_cms_aggregates.py   turns the CMS supplemental tables into flat CSVs
data/
  raw/                        CMS line-item files (not in the repo, about 470 MB gzipped)
  reference/                  CMS aggregate tables, CPT ranges, state list, CMS source docs
  exports/                    the 12 view outputs Power BI reads
powerbi/
  NSA_IDR_Dispute_Explorer.pbip   open this in Power BI Desktop
docs/
  interview_walkthrough.md    how I'd present this, plus likely questions
  data_quality_checks.md      what each check looks for and how many rows it caught
```

## How to run it

### Just look at the dashboard

The exports are already in `data/exports`, so you can skip the rebuild.

1. Install Power BI Desktop (free, Microsoft Store).
2. Open `powerbi/NSA_IDR_Dispute_Explorer.pbip`.
3. If the visuals are blank, click **Refresh** on the Home ribbon.
4. If you moved the project folder, go to Home > Transform data > Edit parameters and point **ExportsFolder** at the new `data\exports\` folder (keep the trailing backslash). Then refresh.

### Rebuild everything from the CMS source files

You need Python 3.10 or newer.

```
pip install duckdb openpyxl
python scripts/download_cms_data.py
python build.py
```

The download script only grabs the two line-item CSVs out of each quarterly zip instead of downloading whole zips, which cuts the download roughly in half. It still moves about 2.3 GB, so it takes a while on a slow connection. `build.py` takes a few minutes and prints row counts, the data quality summary, and the reconciliation when it finishes. Then refresh Power BI.

The CMS supplemental tables and the 2022 reports are already in `data/reference/cms_source`. If CMS republishes them, rerun `python scripts/extract_cms_aggregates.py`.

## Model

```
raw_line_items     every row from the 8 CSVs, all text, nothing dropped
stg_line_items     typed, placeholders (N/R, N/A, +) turned into nulls, ratios kept as ratios
dq_failures        one row per (line item, check) failure
dq_audit           every line item that failed something, with the list of checks
fct_line_items     staging minus reject-level failures, with state and service group attached
fct_disputes       one row per dispute per quarterly file
```

The views roll everything up with `GROUP BY CUBE` so each one already has rows for each quarter, the full year, each dispute type, and all types combined. That matters because the dashboard shows medians, and you can't average quarterly medians into a yearly one. The Power BI measures use the Period and Dispute type slicers to pick the right pre-computed row.

## Things worth knowing about the data

- The "% of QPA" fields in the CMS files are ratios. 4.48 means the offer was 4.48 times the QPA.
- `+` means the QPA wasn't reported, `N/R` means not reported, and `N/A` means not applicable (no offer, or a component line inside a bundle). These all become nulls in staging.
- CMS republishes disputes that were reopened and corrected in the quarter the correction happened. That's why 5,604 DLIs show up twice. The check keeps the later copy.
- The separate "QPA and Offers" file in each zip has dollar amounts but no dispute or line ID, and a lot of its values are suppressed. It can't be joined to anything, so I left it out.
- Representatives are grouped by email domain because that's the best organization-level field CMS provides. A domain like halomd.com is a billing firm filing for many practices, not a single provider.

## Sources

- CMS, Federal IDR public use files and supplemental tables: https://www.cms.gov/nosurprises/policies-and-resources/reports
- CMS, Federal IDR PUF general information and data dictionary (copies in `data/reference/cms_source`)
- CMS, Initial Report on the Federal IDR Process, April 15 to September 30, 2022, and the Partial Report for October to December 2022
