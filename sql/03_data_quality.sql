-- 03_data_quality.sql
-- Nine checks on the staged line items. Every failure is logged to dq_audit with
-- the check that caught it. Two severities:
--   reject  the row is pulled out of fct_line_items (the outcome or the dollar
--           ratios can't be trusted, so it would skew the reporting views)
--   warn    the row stays in, but it's logged so the issue is visible
--
-- Checks that are about the whole dispute (DQ06, DQ07) fail every line in that
-- dispute, since the dispute-level outcome is the thing in question.

create or replace table dq_check_catalog as
select * from (values
    ('DQ01', 'Uniqueness',   'reject', 'Duplicate DLI across quarters',
     'Same DLI number shows up in more than one quarterly file. CMS republishes reopened disputes in the quarter they were corrected, so the latest copy is kept and earlier copies fail.'),
    ('DQ02', 'Completeness', 'reject', 'Missing or malformed IDs',
     'Dispute number is not DISP-<digits> or DLI number is not DLI - <digits>.'),
    ('DQ03', 'Validity',     'reject', 'Unknown determination outcome',
     'Payment determination outcome is blank or not one of the three values CMS defines (provider, plan, split).'),
    ('DQ04', 'Validity',     'warn',   'Service state missing or invalid',
     'Location of service is N/R or not a valid state or territory code. Row is kept and reported under Unknown state.'),
    ('DQ05', 'Validity',     'warn',   'Malformed NPI',
     'An NPI was reported but it is not 10 digits (most of these look like 9-digit tax IDs typed into the NPI field).'),
    ('DQ06', 'Consistency',  'reject', 'Line result contradicts dispute result',
     'Dispute is marked as a provider win or a plan win, but at least one of its line items shows the other side''s offer selected. That should have been a split decision.'),
    ('DQ07', 'Consistency',  'reject', 'Single dispute with several billable lines',
     'Dispute type is Single but it carries more than one single or bundled line item. A single dispute should cover one item or one bundle.'),
    ('DQ08', 'Consistency',  'reject', 'Prevailing offer does not match selected offer',
     'The prevailing offer (as a ratio to QPA) does not equal the offer of the side that was selected, within 0.01.'),
    ('DQ09', 'Plausibility', 'reject', 'Implausible offer ratio',
     'An offer or the prevailing offer is negative, the provider offered $0, or a ratio is above 1,000 times the QPA.')
) t(check_id, dq_dimension, severity, check_name, check_description);


create or replace table dq_failures as

-- DQ01: keep the most recent quarter's copy of a DLI
with dli_copies as (
    select
        line_item_key,
        row_number() over (partition by dli_number order by puf_year desc, puf_quarter desc, line_item_key desc) as copy_rank
    from stg_line_items
    where dli_number is not null
)
select line_item_key, 'DQ01' as check_id from dli_copies where copy_rank > 1

union all
select line_item_key, 'DQ02'
from stg_line_items
where dispute_number is null
   or dli_number is null
   or not regexp_matches(dispute_number, '^DISP-\d+$')
   or not regexp_matches(dli_number, '^DLI - \d+$')

union all
select line_item_key, 'DQ03'
from stg_line_items
where dispute_outcome is null

union all
select s.line_item_key, 'DQ04'
from stg_line_items s
left join ref_us_states st on st.state_code = s.service_state_raw
where st.state_code is null

union all
select line_item_key, 'DQ05'
from stg_line_items
where provider_npi is not null
  and not regexp_matches(provider_npi, '^\d{10}$')

union all
select s.line_item_key, 'DQ06'
from stg_line_items s
join (
    select distinct source_file, dispute_number
    from stg_line_items
    where dispute_outcome in ('Provider', 'Plan')
      and line_offer_selected is not null
      and line_offer_selected <> dispute_outcome
) bad using (source_file, dispute_number)

union all
select s.line_item_key, 'DQ07'
from stg_line_items s
join (
    select source_file, dispute_number
    from stg_line_items
    where dispute_type = 'Single'
    group by all
    having count(*) filter (where line_item_type in ('Single', 'Bundled Item or Service')) > 1
) bad using (source_file, dispute_number)

union all
select line_item_key, 'DQ08'
from stg_line_items
where prevailing_offer_qpa_ratio is not null
  and (
       (line_offer_selected = 'Provider' and provider_offer_qpa_ratio is not null
            and abs(prevailing_offer_qpa_ratio - provider_offer_qpa_ratio) > 0.01)
    or (line_offer_selected = 'Plan' and plan_offer_qpa_ratio is not null
            and abs(prevailing_offer_qpa_ratio - plan_offer_qpa_ratio) > 0.01)
  )

union all
select line_item_key, 'DQ09'
from stg_line_items
where provider_offer_qpa_ratio < 0
   or plan_offer_qpa_ratio < 0
   or prevailing_offer_qpa_ratio < 0
   or provider_offer_qpa_ratio = 0
   or provider_offer_qpa_ratio > 1000
   or plan_offer_qpa_ratio > 1000
   or prevailing_offer_qpa_ratio > 1000;


-- Audit table: one row per failing line item, with every check it failed.
create or replace table dq_audit as
select
    s.*,
    f.failed_checks,
    f.worst_severity
from stg_line_items s
join (
    select
        d.line_item_key,
        string_agg(d.check_id, ', ' order by d.check_id) as failed_checks,
        case when bool_or(c.severity = 'reject') then 'reject' else 'warn' end as worst_severity
    from dq_failures d
    join dq_check_catalog c using (check_id)
    group by d.line_item_key
) f using (line_item_key);


-- Clean fact table: everything except rejects, with service grouping attached.
create or replace table fct_line_items as
select
    s.*,
    coalesce(st.state_code, 'Unknown') as service_state,
    coalesce(st.state_name, 'Unknown') as service_state_name,
    case
        when s.dispute_category = 'Air ambulance' then 'Air ambulance'
        else coalesce(m.cms_specialty,
                      case s.service_code_type
                          when 'DRG' then 'Inpatient facility (DRG)'
                          when 'HCPCS' then 'HCPCS items and services'
                          else 'Other or unmapped code'
                      end)
    end as cms_specialty,
    case
        when s.dispute_category = 'Air ambulance' then 'Air ambulance'
        else coalesce(m.service_group,
                      case s.service_code_type
                          when 'DRG' then 'Inpatient facility (DRG)'
                          when 'HCPCS' then 'HCPCS items and services'
                          else 'Other or unmapped code'
                      end)
    end as service_group,
    a.failed_checks as dq_warnings
from stg_line_items s
left join dq_audit a using (line_item_key)
left join ref_us_states st on st.state_code = s.service_state_raw
left join stg_service_code_map m on m.service_code = s.service_code
where coalesce(a.worst_severity, 'pass') <> 'reject';


-- Dispute-level table. Dispute fields repeat on every line in the CMS files, so
-- any_value is safe for them (checked: they never disagree within a dispute).
create or replace table fct_disputes as
select
    source_file,
    year_quarter,
    puf_year,
    puf_quarter,
    dispute_category,
    dispute_number,
    any_value(dispute_outcome) as dispute_outcome,
    any_value(is_default_decision) as is_default_decision,
    any_value(dispute_type) as dispute_type,
    any_value(initiating_party) as initiating_party,
    any_value(provider_email_domain) as provider_email_domain,
    any_value(provider_group_name) as provider_group_name,
    any_value(plan_email_domain) as plan_email_domain,
    any_value(plan_name) as plan_name,
    any_value(practice_size) as practice_size,
    any_value(health_plan_type) as health_plan_type,
    any_value(business_days_to_determination) as business_days_to_determination,
    any_value(idre_compensation) as idre_compensation,
    case when count(distinct service_state) = 1 then any_value(service_state) else 'Multiple' end as service_state,
    count(*) as line_items,
    median(prevailing_offer_qpa_ratio) as median_prevailing_offer_qpa_ratio
from fct_line_items
group by source_file, year_quarter, puf_year, puf_quarter, dispute_category, dispute_number;
