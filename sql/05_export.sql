-- 05_export.sql
-- Write the 12 reporting views to CSV for Power BI.
-- Power BI reads these files, so the report works without a DuckDB driver installed.
-- (If you'd rather connect live, the DuckDB ODBC driver can read the same views.)

copy (select * from v_quarterly_summary order by period_sort, dispute_category)
    to 'data/exports/v_quarterly_summary.csv' (header, delimiter ',');

copy (select * from v_offer_ratio_distribution order by period_sort, dispute_category, ratio_bucket_sort, winning_side)
    to 'data/exports/v_offer_ratio_distribution.csv' (header, delimiter ',');

copy (select * from v_outcomes_by_plan_type order by period_sort, dispute_category, disputes desc)
    to 'data/exports/v_outcomes_by_plan_type.csv' (header, delimiter ',');

copy (select * from v_outcomes_by_service_group order by period_sort, dispute_category, line_items desc)
    to 'data/exports/v_outcomes_by_service_group.csv' (header, delimiter ',');

copy (select * from v_outcomes_by_state order by period_sort, dispute_category, line_items desc)
    to 'data/exports/v_outcomes_by_state.csv' (header, delimiter ',');

copy (select * from v_outcomes_by_practice_size order by period_sort, practice_size_sort)
    to 'data/exports/v_outcomes_by_practice_size.csv' (header, delimiter ',');

copy (select * from v_top_initiating_representatives order by period_sort, dispute_category, rank_in_slice)
    to 'data/exports/v_top_initiating_representatives.csv' (header, delimiter ',');

copy (select * from v_top_plan_representatives order by period_sort, dispute_category, rank_in_slice)
    to 'data/exports/v_top_plan_representatives.csv' (header, delimiter ',');

copy (select * from v_determination_timing order by period_sort, dispute_category, days_bucket_sort, decision_path)
    to 'data/exports/v_determination_timing.csv' (header, delimiter ',');

copy (select * from v_eligibility_trend order by period_sort, dispute_category)
    to 'data/exports/v_eligibility_trend.csv' (header, delimiter ',');

copy (select * from v_reconciliation order by period_sort, dispute_category, metric_sort)
    to 'data/exports/v_reconciliation.csv' (header, delimiter ',');

copy (select * from v_dq_summary order by check_id)
    to 'data/exports/v_dq_summary.csv' (header, delimiter ',');
