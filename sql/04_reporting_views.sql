-- 04_reporting_views.sql
-- The 12 views behind the Power BI report.
--
-- Most views are pre-aggregated at "period x dispute category x something" with
-- CUBE, so each one already has rows for every quarter, the full year, each
-- dispute category, and all categories together. That way the medians in Power BI
-- are real medians for whatever slice is picked, not an average of quarterly medians.
--
-- Period labels:   '2025 Q1' ... '2025 Q4', '2025 full year'
-- Category labels: 'Emergency / non-emergency', 'Air ambulance', 'All dispute types'
--
-- Ratios are offer / QPA. 1.0 means the offer equaled the QPA.


-- Small helper so every view labels the rollup rows the same way.
create or replace macro period_label(yr, yq) as coalesce(yq, yr || ' full year');
create or replace macro period_type(yq) as case when yq is null then 'Full year' else 'Quarter' end;
create or replace macro period_sort(yr, yq) as yr * 10 + coalesce(cast(right(yq, 1) as integer), 0);
create or replace macro category_label(cat) as coalesce(cat, 'All dispute types');


-- 1. Headline numbers by period and category -----------------------------------
create or replace view v_quarterly_summary as
with d as (
    select
        puf_year, year_quarter, dispute_category,
        count(*) as disputes,
        count(*) filter (where dispute_outcome = 'Provider') as provider_wins,
        count(*) filter (where dispute_outcome = 'Plan') as plan_wins,
        count(*) filter (where dispute_outcome = 'Split') as split_decisions,
        count(*) filter (where is_default_decision) as default_decisions,
        count(*) filter (where dispute_type = 'Batched') as batched_disputes,
        median(business_days_to_determination) as median_business_days,
        sum(idre_compensation) as idre_compensation_total
    from fct_disputes
    group by puf_year, cube(year_quarter, dispute_category)
),
l as (
    select
        puf_year, year_quarter, dispute_category,
        count(*) as line_items,
        count(prevailing_offer_qpa_ratio) as lines_with_qpa_ratio,
        count(*) filter (where line_offer_selected = 'Provider') as lines_provider_selected,
        count(line_offer_selected) as lines_with_selection,
        median(prevailing_offer_qpa_ratio) as median_prevailing_offer_qpa_ratio,
        median(provider_offer_qpa_ratio) as median_provider_offer_qpa_ratio,
        median(plan_offer_qpa_ratio) as median_plan_offer_qpa_ratio,
        count(*) filter (where prevailing_offer_qpa_ratio > 1) as lines_prevailing_above_qpa
    from fct_line_items
    group by puf_year, cube(year_quarter, dispute_category)
)
select
    period_label(d.puf_year, d.year_quarter) as period,
    period_type(d.year_quarter) as period_type,
    period_sort(d.puf_year, d.year_quarter) as period_sort,
    category_label(d.dispute_category) as dispute_category,
    l.line_items,
    d.disputes,
    d.provider_wins,
    d.plan_wins,
    d.split_decisions,
    d.provider_wins / d.disputes as provider_win_rate,
    d.default_decisions,
    d.default_decisions / d.disputes as default_decision_rate,
    d.batched_disputes,
    d.batched_disputes / d.disputes as batched_share,
    d.median_business_days,
    d.idre_compensation_total,
    l.lines_with_qpa_ratio,
    l.lines_provider_selected,
    l.lines_provider_selected / nullif(l.lines_with_selection, 0) as line_provider_selected_rate,
    l.median_prevailing_offer_qpa_ratio,
    l.median_provider_offer_qpa_ratio,
    l.median_plan_offer_qpa_ratio,
    l.lines_prevailing_above_qpa / nullif(l.lines_with_qpa_ratio, 0) as share_prevailing_above_qpa
from d
join l
  on l.puf_year = d.puf_year
 and l.year_quarter is not distinct from d.year_quarter
 and l.dispute_category is not distinct from d.dispute_category;


-- 2. How far above (or below) the QPA the winning offer landed -----------------
create or replace view v_offer_ratio_distribution as
with b as (
    select
        *,
        case
            when prevailing_offer_qpa_ratio < 1 then 'Below QPA'
            when prevailing_offer_qpa_ratio < 2 then '1x to 2x QPA'
            when prevailing_offer_qpa_ratio < 3 then '2x to 3x QPA'
            when prevailing_offer_qpa_ratio < 5 then '3x to 5x QPA'
            when prevailing_offer_qpa_ratio < 10 then '5x to 10x QPA'
            else '10x QPA or more'
        end as ratio_bucket,
        case
            when prevailing_offer_qpa_ratio < 1 then 1
            when prevailing_offer_qpa_ratio < 2 then 2
            when prevailing_offer_qpa_ratio < 3 then 3
            when prevailing_offer_qpa_ratio < 5 then 4
            when prevailing_offer_qpa_ratio < 10 then 5
            else 6
        end as ratio_bucket_sort
    from fct_line_items
    where prevailing_offer_qpa_ratio is not null
)
select
    period_label(puf_year, year_quarter) as period,
    period_type(year_quarter) as period_type,
    period_sort(puf_year, year_quarter) as period_sort,
    category_label(dispute_category) as dispute_category,
    ratio_bucket,
    ratio_bucket_sort,
    line_offer_selected as winning_side,
    count(*) as line_items
from b
group by puf_year, cube(year_quarter, dispute_category), ratio_bucket, ratio_bucket_sort, line_offer_selected;


-- 3. Outcomes by health plan type ------------------------------------------------
create or replace view v_outcomes_by_plan_type as
with d as (
    select
        puf_year, year_quarter, dispute_category, health_plan_type,
        count(*) as disputes,
        count(*) filter (where dispute_outcome = 'Provider') as provider_wins,
        count(*) filter (where is_default_decision) as default_decisions,
        sum(line_items) as line_items
    from fct_disputes
    group by puf_year, cube(year_quarter, dispute_category), health_plan_type
),
l as (
    select
        puf_year, year_quarter, dispute_category, health_plan_type,
        median(prevailing_offer_qpa_ratio) as median_prevailing_offer_qpa_ratio
    from fct_line_items
    group by puf_year, cube(year_quarter, dispute_category), health_plan_type
)
select
    period_label(d.puf_year, d.year_quarter) as period,
    period_type(d.year_quarter) as period_type,
    period_sort(d.puf_year, d.year_quarter) as period_sort,
    category_label(d.dispute_category) as dispute_category,
    d.health_plan_type,
    d.disputes,
    d.line_items,
    d.provider_wins,
    d.provider_wins / d.disputes as provider_win_rate,
    d.default_decisions / d.disputes as default_decision_rate,
    l.median_prevailing_offer_qpa_ratio
from d
join l
  on l.puf_year = d.puf_year
 and l.year_quarter is not distinct from d.year_quarter
 and l.dispute_category is not distinct from d.dispute_category
 and l.health_plan_type = d.health_plan_type;


-- 4. Outcomes by service group and CMS specialty ---------------------------------
-- Two levels in one view: level = 'Group' has one row per service group (medians
-- computed across the whole group), level = 'Specialty' breaks each group out by
-- the CMS specialty ranges. Filter on level so the two never get added together.
create or replace view v_outcomes_by_service_group as
select
    period_label(puf_year, year_quarter) as period,
    period_type(year_quarter) as period_type,
    period_sort(puf_year, year_quarter) as period_sort,
    category_label(dispute_category) as dispute_category,
    case when grouping(cms_specialty) = 1 then 'Group' else 'Specialty' end as level,
    service_group,
    coalesce(cms_specialty, 'All specialties in group') as cms_specialty,
    count(*) as line_items,
    count(distinct source_file || '|' || dispute_number) as disputes,
    count(*) filter (where line_offer_selected = 'Provider') as lines_provider_selected,
    count(*) filter (where line_offer_selected = 'Provider') / nullif(count(line_offer_selected), 0) as line_provider_selected_rate,
    median(prevailing_offer_qpa_ratio) as median_prevailing_offer_qpa_ratio,
    median(provider_offer_qpa_ratio) as median_provider_offer_qpa_ratio,
    median(plan_offer_qpa_ratio) as median_plan_offer_qpa_ratio
from fct_line_items
group by grouping sets (
    (puf_year, year_quarter, dispute_category, service_group, cms_specialty),
    (puf_year, year_quarter, service_group, cms_specialty),
    (puf_year, dispute_category, service_group, cms_specialty),
    (puf_year, service_group, cms_specialty),
    (puf_year, year_quarter, dispute_category, service_group),
    (puf_year, year_quarter, service_group),
    (puf_year, dispute_category, service_group),
    (puf_year, service_group)
);


-- 5. Outcomes by state where the service happened --------------------------------
-- Line-level on purpose: batched disputes can span more than one state.
create or replace view v_outcomes_by_state as
with s as (
    select
        puf_year, year_quarter, dispute_category,
        service_state as state_code,
        service_state_name as state_name,
        count(*) as line_items,
        count(distinct source_file || '|' || dispute_number) as disputes,
        count(*) filter (where line_offer_selected = 'Provider') / nullif(count(line_offer_selected), 0) as line_provider_selected_rate,
        median(prevailing_offer_qpa_ratio) as median_prevailing_offer_qpa_ratio
    from fct_line_items
    group by puf_year, cube(year_quarter, dispute_category), service_state, service_state_name
)
select
    period_label(puf_year, year_quarter) as period,
    period_type(year_quarter) as period_type,
    period_sort(puf_year, year_quarter) as period_sort,
    category_label(dispute_category) as dispute_category,
    state_code,
    state_name,
    line_items,
    disputes,
    line_provider_selected_rate,
    median_prevailing_offer_qpa_ratio,
    -- rank within each period/category slice; Unknown state isn't ranked
    case when state_code <> 'Unknown' then
        row_number() over (
            partition by puf_year, year_quarter, dispute_category, state_code = 'Unknown'
            order by disputes desc, state_code
        )
    end as state_rank
from s;


-- 6. Outcomes by provider practice or facility size ------------------------------
-- Practice size is only collected for emergency / non-emergency disputes.
create or replace view v_outcomes_by_practice_size as
with d as (
    select
        puf_year, year_quarter, practice_size,
        count(*) as disputes,
        count(*) filter (where dispute_outcome = 'Provider') as provider_wins,
        count(*) filter (where is_default_decision) as default_decisions
    from fct_disputes
    where dispute_category = 'Emergency / non-emergency'
    group by puf_year, rollup(year_quarter), practice_size
),
l as (
    select
        puf_year, year_quarter, practice_size,
        count(*) as line_items,
        median(prevailing_offer_qpa_ratio) as median_prevailing_offer_qpa_ratio
    from fct_line_items
    where dispute_category = 'Emergency / non-emergency'
    group by puf_year, rollup(year_quarter), practice_size
)
select
    period_label(d.puf_year, d.year_quarter) as period,
    period_type(d.year_quarter) as period_type,
    period_sort(d.puf_year, d.year_quarter) as period_sort,
    'Emergency / non-emergency' as dispute_category,
    d.practice_size,
    case d.practice_size
        when 'Fewer than 20 Employees' then 1
        when '20-50 Employees' then 2
        when '51-100 Employees' then 3
        when '101-500 Employees' then 4
        when 'Over 500 Employees' then 5
        else 6
    end as practice_size_sort,
    d.disputes,
    l.line_items,
    d.provider_wins / d.disputes as provider_win_rate,
    d.default_decisions / d.disputes as default_decision_rate,
    l.median_prevailing_offer_qpa_ratio
from d
join l
  on l.puf_year = d.puf_year
 and l.year_quarter is not distinct from d.year_quarter
 and l.practice_size = d.practice_size;


-- 7. Who files the most disputes ------------------------------------------------
-- The provider email domain is the best handle CMS gives for the organization that
-- actually files the dispute (often a billing or revenue cycle firm working for many
-- practices). Top 25 per slice, everything else rolled into one row.
create or replace view v_top_initiating_representatives as
with agg as (
    select
        puf_year, year_quarter, dispute_category,
        coalesce(provider_email_domain, 'Not reported') as representative,
        count(*) as disputes,
        sum(line_items) as line_items,
        count(*) filter (where dispute_outcome = 'Provider') as provider_wins
    from fct_disputes
    group by puf_year, cube(year_quarter, dispute_category), coalesce(provider_email_domain, 'Not reported')
),
ranked as (
    select
        *,
        row_number() over (partition by puf_year, year_quarter, dispute_category order by disputes desc, representative) as rank_in_slice,
        sum(disputes) over (partition by puf_year, year_quarter, dispute_category) as slice_disputes
    from agg
)
select
    period_label(puf_year, year_quarter) as period,
    period_type(year_quarter) as period_type,
    period_sort(puf_year, year_quarter) as period_sort,
    category_label(dispute_category) as dispute_category,
    case when rank_in_slice <= 25 then representative else 'All others' end as representative,
    min(rank_in_slice) as rank_in_slice,
    sum(disputes) as disputes,
    sum(line_items) as line_items,
    sum(provider_wins) / sum(disputes) as provider_win_rate,
    sum(disputes) / any_value(slice_disputes) as share_of_disputes
from ranked
group by puf_year, year_quarter, dispute_category, case when rank_in_slice <= 25 then representative else 'All others' end;


-- 8. Who is on the other side (plans and the firms answering for them) -----------
create or replace view v_top_plan_representatives as
with agg as (
    select
        puf_year, year_quarter, dispute_category,
        coalesce(plan_email_domain, 'Not reported') as representative,
        count(*) as disputes,
        sum(line_items) as line_items,
        count(*) filter (where dispute_outcome = 'Provider') as provider_wins
    from fct_disputes
    group by puf_year, cube(year_quarter, dispute_category), coalesce(plan_email_domain, 'Not reported')
),
ranked as (
    select
        *,
        row_number() over (partition by puf_year, year_quarter, dispute_category order by disputes desc, representative) as rank_in_slice,
        sum(disputes) over (partition by puf_year, year_quarter, dispute_category) as slice_disputes
    from agg
)
select
    period_label(puf_year, year_quarter) as period,
    period_type(year_quarter) as period_type,
    period_sort(puf_year, year_quarter) as period_sort,
    category_label(dispute_category) as dispute_category,
    case when rank_in_slice <= 25 then representative else 'All others' end as representative,
    min(rank_in_slice) as rank_in_slice,
    sum(disputes) as disputes,
    sum(line_items) as line_items,
    1 - sum(provider_wins) / sum(disputes) as plan_side_win_rate,
    sum(disputes) / any_value(slice_disputes) as share_of_disputes
from ranked
group by puf_year, year_quarter, dispute_category, case when rank_in_slice <= 25 then representative else 'All others' end;


-- 9. How long disputes take, initiation to determination (business days) ---------
create or replace view v_determination_timing as
with b as (
    select
        *,
        case
            when business_days_to_determination <= 30 then '30 or fewer'
            when business_days_to_determination <= 60 then '31 to 60'
            when business_days_to_determination <= 90 then '61 to 90'
            when business_days_to_determination <= 180 then '91 to 180'
            when business_days_to_determination <= 365 then '181 to 365'
            else 'More than 365'
        end as days_bucket,
        case
            when business_days_to_determination <= 30 then 1
            when business_days_to_determination <= 60 then 2
            when business_days_to_determination <= 90 then 3
            when business_days_to_determination <= 180 then 4
            when business_days_to_determination <= 365 then 5
            else 6
        end as days_bucket_sort
    from fct_disputes
    where business_days_to_determination is not null
)
select
    period_label(puf_year, year_quarter) as period,
    period_type(year_quarter) as period_type,
    period_sort(puf_year, year_quarter) as period_sort,
    category_label(dispute_category) as dispute_category,
    days_bucket,
    days_bucket_sort,
    case when is_default_decision then 'Default decision' else 'Both sides submitted' end as decision_path,
    count(*) as disputes,
    median(business_days_to_determination) as median_business_days
from b
group by puf_year, cube(year_quarter, dispute_category), days_bucket, days_bucket_sort,
         case when is_default_decision then 'Default decision' else 'Both sides submitted' end;


-- 10. Eligibility trend, rebuilt from CMS aggregate tables -----------------------
-- The line-item files only hold disputes that reached a payment determination,
-- so ineligible disputes have to come from the closure tables (2023 Q1 onward)
-- and the two 2022 reports.
create or replace view v_eligibility_trend as
select
    year || ' Q' || quarter as period,
    year,
    quarter,
    year * 10 + quarter as period_sort,
    case dispute_category
        when 'emergency_nonemergency' then 'Emergency / non-emergency'
        when 'air_ambulance' then 'Air ambulance'
        else 'All dispute types'
    end as dispute_category,
    i.disputes_initiated,
    c.total_closed,
    c.payment_determinations,
    c.found_ineligible,
    c.other_closed,
    c.found_ineligible / c.total_closed as ineligible_share,
    c.payment_determinations / c.total_closed as determination_share,
    c.other_closed / c.total_closed as other_share,
    c.source
from ref_cms_closure_reasons c
left join ref_cms_disputes_initiated i using (year, quarter, dispute_category);


-- 11. Reconciliation: line-item files vs CMS published totals --------------------
-- puf_raw is counted before any data quality filtering, which is the right
-- comparison to the CMS tables. puf_clean shows what survives the reject checks.
create or replace view v_reconciliation as
with raw_disputes as (
    select
        cast(regexp_extract(source_file, 'puf_(\d{4})q\d_', 1) as integer) as puf_year,
        cast(regexp_extract(source_file, 'puf_\d{4}q(\d)_', 1) as integer) as puf_quarter,
        case when source_file like '%_air.%' then 'air_ambulance' else 'emergency_nonemergency' end as cat,
        "Dispute Number" as dispute_number,
        any_value("Payment Determination Outcome") as outcome,
        any_value("Default Decision") as default_decision
    from raw_line_items
    group by all
),
raw_counts as (
    select
        puf_year, puf_quarter, cat,
        count(*) as payment_determinations,
        count(*) filter (where outcome = 'In Favor of Provider/Facility/AA Provider') as provider_prevailed,
        count(*) filter (where outcome = 'In Favor of Plan/Issuer') as plan_prevailed,
        count(*) filter (where outcome = 'Split Decision') as split_decisions,
        count(*) filter (where default_decision = 'Yes') as default_decisions
    from raw_disputes
    group by puf_year, cube(puf_quarter, cat)
),
clean_counts as (
    select
        puf_year, puf_quarter,
        case dispute_category when 'Air ambulance' then 'air_ambulance' else 'emergency_nonemergency' end as cat,
        count(*) as payment_determinations,
        count(*) filter (where dispute_outcome = 'Provider') as provider_prevailed,
        count(*) filter (where dispute_outcome = 'Plan') as plan_prevailed,
        count(*) filter (where dispute_outcome = 'Split') as split_decisions,
        count(*) filter (where is_default_decision) as default_decisions
    from fct_disputes
    group by puf_year, cube(puf_quarter, case dispute_category when 'Air ambulance' then 'air_ambulance' else 'emergency_nonemergency' end)
),
cms as (
    select
        year as puf_year, quarter as puf_quarter,
        case when dispute_category = 'total' then null else dispute_category end as cat,
        payment_determinations, provider_prevailed, plan_prevailed, split_decisions,
        one_party_offer_only as default_decisions
    from ref_cms_payment_outcomes
    where year in (select distinct puf_year from raw_counts)
    union all
    -- full-year rows
    select
        year, null,
        case when dispute_category = 'total' then null else dispute_category end,
        sum(payment_determinations), sum(provider_prevailed), sum(plan_prevailed),
        sum(split_decisions), sum(one_party_offer_only)
    from ref_cms_payment_outcomes
    where year in (select distinct puf_year from raw_counts)
    group by year, dispute_category
),
wide as (
    select
        c.puf_year, c.puf_quarter, c.cat,
        c.payment_determinations as cms_pd,  r.payment_determinations as raw_pd,  k.payment_determinations as clean_pd,
        c.provider_prevailed     as cms_prov, r.provider_prevailed     as raw_prov, k.provider_prevailed     as clean_prov,
        c.plan_prevailed         as cms_plan, r.plan_prevailed         as raw_plan, k.plan_prevailed         as clean_plan,
        c.split_decisions        as cms_split, r.split_decisions       as raw_split, k.split_decisions       as clean_split,
        c.default_decisions      as cms_def,  r.default_decisions      as raw_def,  k.default_decisions      as clean_def
    from cms c
    join raw_counts r
      on r.puf_year = c.puf_year
     and r.puf_quarter is not distinct from c.puf_quarter
     and r.cat is not distinct from c.cat
    join clean_counts k
      on k.puf_year = c.puf_year
     and k.puf_quarter is not distinct from c.puf_quarter
     and k.cat is not distinct from c.cat
),
long as (
    select puf_year, puf_quarter, cat, 'Payment determinations (disputes)' as metric, 1 as metric_sort,
           cms_pd as cms_value, raw_pd as raw_value, clean_pd as clean_value from wide
    union all
    select puf_year, puf_quarter, cat, 'Provider prevailed', 2, cms_prov, raw_prov, clean_prov from wide
    union all
    select puf_year, puf_quarter, cat, 'Plan prevailed', 3, cms_plan, raw_plan, clean_plan from wide
    union all
    select puf_year, puf_quarter, cat, 'Split decisions', 4, cms_split, raw_split, clean_split from wide
    union all
    select puf_year, puf_quarter, cat, 'Default decisions (one side only)', 5, cms_def, raw_def, clean_def from wide
)
select
    case when puf_quarter is null then puf_year || ' full year' else puf_year || ' Q' || puf_quarter end as period,
    case when puf_quarter is null then 'Full year' else 'Quarter' end as period_type,
    puf_year * 10 + coalesce(puf_quarter, 0) as period_sort,
    case cat
        when 'emergency_nonemergency' then 'Emergency / non-emergency'
        when 'air_ambulance' then 'Air ambulance'
        else 'All dispute types'
    end as dispute_category,
    metric,
    metric_sort,
    cms_value as cms_published,
    raw_value as puf_raw,
    raw_value - cms_value as raw_difference,
    (raw_value - cms_value) / cms_value as raw_pct_difference,
    clean_value as puf_after_dq,
    clean_value - cms_value as clean_difference,
    (clean_value - cms_value) / cms_value as clean_pct_difference
from long;


-- 12. Data quality summary -------------------------------------------------------
create or replace view v_dq_summary as
with totals as (
    select count(*) as total_rows from stg_line_items
),
per_check as (
    select
        c.check_id,
        c.check_name,
        c.dq_dimension,
        c.severity,
        c.check_description,
        count(f.line_item_key) as rows_flagged
    from dq_check_catalog c
    left join dq_failures f using (check_id)
    group by all
),
any_check as (
    select
        'ALL' as check_id,
        'Failed at least one check' as check_name,
        'All' as dq_dimension,
        'any' as severity,
        'Distinct line items that failed one or more of the nine checks.' as check_description,
        count(*) as rows_flagged
    from dq_audit
    union all
    select
        'REJ', 'Rejected (removed from reporting)', 'All', 'reject',
        'Distinct line items that failed at least one reject-level check and were left out of fct_line_items.',
        count(*) filter (where worst_severity = 'reject')
    from dq_audit
)
select
    p.*,
    p.rows_flagged / t.total_rows as share_of_rows,
    t.total_rows
from (select * from per_check union all select * from any_check) p
cross join totals t;
