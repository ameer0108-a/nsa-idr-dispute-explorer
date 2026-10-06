-- 02_staging.sql
-- One row per dispute line item (DLI), typed and renamed, nothing dropped yet.
--
-- Placeholder handling, per the CMS PUF general information doc:
--   N/R  = not reported by the parties
--   N/A  = not applicable (no offer submitted, or a component line in a bundle)
--   +    = QPA wasn't reported, so the offer can't be expressed as a % of QPA
-- All three become null in the numeric columns. qpa_reported keeps track of the
-- '+' case since that one matters when explaining missing ratios.
--
-- The "% of QPA" columns in the CMS files are really ratios (4.48 means the offer
-- was 4.48 times the QPA, i.e. 448%). I keep them as ratios and name them that way.

create or replace table stg_line_items as
with typed as (
    select
        source_file,
        cast(regexp_extract(source_file, 'puf_(\d{4})q\d_', 1) as integer) as puf_year,
        cast(regexp_extract(source_file, 'puf_\d{4}q(\d)_', 1) as integer) as puf_quarter,
        case regexp_extract(source_file, 'puf_\d{4}q\d_([a-z]+)', 1)
            when 'air' then 'Air ambulance'
            else 'Emergency / non-emergency'
        end as dispute_category,

        trim("Dispute Number") as dispute_number,
        trim("DLI Number") as dli_number,

        "Payment Determination Outcome" as outcome_raw,
        case "Payment Determination Outcome"
            when 'In Favor of Provider/Facility/AA Provider' then 'Provider'
            when 'In Favor of Plan/Issuer' then 'Plan'
            when 'Split Decision' then 'Split'
        end as dispute_outcome,

        case "Offer Selected from Provider or Issuer"
            when 'In Favor of Provider/Facility/AA Provider' then 'Provider'
            when 'In Favor of Plan/Issuer' then 'Plan'
        end as line_offer_selected,

        case "Default Decision" when 'Yes' then true when 'No' then false end as is_default_decision,
        "Type of Dispute" as dispute_type,
        "Dispute Line Item Type" as line_item_type,
        "Initiating Party" as initiating_party,

        nullif("Provider/Facility Group Name", 'N/R') as provider_group_name,
        nullif("Provider/Facility Name", 'N/R') as provider_name,
        lower(nullif("Provider Email Domain", 'N/R')) as provider_email_domain,
        nullif("Provider/Facility NPI Number", 'N/R') as provider_npi,
        coalesce(nullif("Practice/Facility Size", 'N/R'), 'Not reported') as practice_size,
        nullif("Practice/Facility Specialty or Type", 'N/R') as provider_specialty_reported,

        nullif("Health Plan/Issuer Name", 'N/R') as plan_name,
        lower(nullif("Health Plan/Issuer Email Domain", 'N/R')) as plan_email_domain,
        case "Health Plan Type"
            when 'Either partially or fully self-insured private (employment-based) group health plan' then 'Self-insured group'
            when 'Fully insured private group health plan' then 'Fully insured group'
            when 'Individual health insurance issuer' then 'Individual market'
            when 'Federal Employees Health Benefits (FEHB) Carrier' then 'FEHB'
            when 'Non-federal government plan (or state or local government plan)' then 'State or local government'
            when 'Church Plan' then 'Church plan'
            when 'No Plan/Issuer Response' then 'No plan response'
            else coalesce("Health Plan Type", 'Not reported')
        end as health_plan_type,

        try_cast("Length of Time to Make Determination" as integer) as business_days_to_determination,
        try_cast("IDRE Compensation" as double) as idre_compensation,

        nullif("Type of Service Code", 'N/R') as service_code_type,
        upper(trim(nullif(nullif("Service Code", 'N/R'), 'N/A'))) as service_code,
        nullif("Place of Service Code", 'N/R') as place_of_service_code,
        "Item or Service Description" as service_description,
        upper(trim("Location of Service")) as service_state_raw,

        nullif("Air Ambulance Vehicle Type", 'N/R') as air_vehicle_type,
        nullif("Air Ambulance Vehicle Clinical Capacity Level", 'N/R') as air_clinical_capacity,

        "Provider/Facility Offer as % of QPA" <> '+'
            and "Health Plan/Issuer Offer as % of QPA" <> '+' as qpa_reported,
        try_cast("Provider/Facility Offer as % of QPA" as double) as provider_offer_qpa_ratio,
        try_cast("Health Plan/Issuer Offer as % of QPA" as double) as plan_offer_qpa_ratio,
        try_cast("Prevailing Party Offer as % of QPA" as double) as prevailing_offer_qpa_ratio,
        try_cast("QPA as Percent of Median QPA" as double) as qpa_to_regional_median,
        try_cast("Prevailing Offer as Percent of Median Prevailing Offer Amount" as double) as prevailing_to_regional_median,

        -- These three only exist from 2025 Q3 on.
        try_cast("Date of Initiation" as date) as initiation_date,
        nullif("Service Code Modifier(s)", 'N/R') as service_code_modifiers,
        nullif("Certified IDR Entity", 'N/R') as certified_idr_entity
    from raw_line_items
)
select
    row_number() over (order by source_file, dli_number) as line_item_key,
    puf_year || ' Q' || puf_quarter as year_quarter,
    make_date(puf_year, (puf_quarter - 1) * 3 + 1, 1) as quarter_start,
    try_cast(regexp_extract(dispute_number, '(\d+)$', 1) as bigint) as dispute_id,
    try_cast(regexp_extract(dli_number, '(\d+)$', 1) as bigint) as dli_id,
    *
from typed;


-- Service code -> CMS specialty. Some CMS ranges overlap (care management sits
-- inside non-face-to-face, for example), so the narrowest matching range wins.
-- PLA lab codes end in U and only match the U range.
create or replace table stg_service_code_map as
with codes as (
    select distinct service_code, service_code_type
    from stg_line_items
    where service_code is not null
),
ranges as (
    select
        *,
        range_end like '%U' as is_pla_range,
        case when range_end like '%U'
             then cast(left(range_end, 4) as integer) - cast(left(range_start, 4) as integer)
             else cast(range_end as integer) - cast(range_start as integer)
        end as range_width
    from ref_cpt_specialty_ranges
),
matched as (
    select
        c.service_code,
        r.cms_specialty,
        r.service_group,
        row_number() over (partition by c.service_code order by r.range_width) as rn
    from codes c
    join ranges r
      on c.service_code_type = 'CPT'
     and length(c.service_code) = 5
     and c.service_code between r.range_start and r.range_end
     and (c.service_code like '%U') = r.is_pla_range
     and (r.is_pla_range or regexp_matches(c.service_code, '^\d{5}$'))
)
select service_code, cms_specialty, service_group
from matched
where rn = 1;
