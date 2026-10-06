-- 01_load.sql
-- Load the CMS line-item files and the small reference tables.
--
-- The PUF CSVs come in as all text on purpose. CMS mixes numbers with placeholder
-- symbols (N/R, N/A, +), so letting DuckDB guess types would either fail or quietly
-- turn those into nulls before I get a chance to count them. Typing happens in 02.
--
-- Expected file names in data/raw (scripts/download_cms_data.py creates these):
--   puf_2025q1_emerg.csv.gz   OON emergency and non-emergency line items
--   puf_2025q1_air.csv.gz     OON air ambulance line items
--   ...same pattern for q2, q3, q4. Plain .csv works too.
-- Q3 and Q4 have three extra columns (Date of Initiation, Service Code Modifier(s),
-- Certified IDR Entity), which is why union_by_name is on.

create or replace table raw_line_items as
select
    * exclude (filename),
    replace(filename, '\', '/') as source_file
from read_csv(
    'data/raw/puf_*_*.csv*',
    union_by_name = true,
    all_varchar = true,
    filename = true,
    header = true,
    quote = '"',
    escape = '"'
);

-- Reference tables -------------------------------------------------------------

-- CMS aggregate tables (supplemental Tables 1, 5, 12 plus the 2022 reports).
-- Built by scripts/extract_cms_aggregates.py.
create or replace table ref_cms_closure_reasons as
select * from read_csv('data/reference/cms_closure_reasons.csv', header = true);

create or replace table ref_cms_payment_outcomes as
select * from read_csv('data/reference/cms_payment_outcomes.csv', header = true);

create or replace table ref_cms_disputes_initiated as
select * from read_csv('data/reference/cms_disputes_initiated.csv', header = true);

-- CPT code ranges by specialty, based on the ranges CMS uses in supplemental Table 14.
create or replace table ref_cpt_specialty_ranges as
select * from read_csv('data/reference/cpt_specialty_ranges.csv', header = true, all_varchar = true);

create or replace table ref_us_states as
select * from read_csv('data/reference/us_states.csv', header = true, all_varchar = true);
