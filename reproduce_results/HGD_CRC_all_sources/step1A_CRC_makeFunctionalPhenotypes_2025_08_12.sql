use <DATABASE>;


-- Matched cohort
drop table if exists #cohort
select t1.* into #cohort
from 
(select PatientID, IBDC from <SCHEMA>.baseTable_with_llms
UNION ALL
select PatientID, 0 as IBDC from <SCHEMA>.baseTable_nonIBD_matched) as t1;

--get CRC from free text
drop table if exists #CRCFREE
SELECT distinct A.PatientID, A.free_text_crc_llm_date as dx_date_crcLLMFree, A.count_crc_pos_outOf5 as confidenceOutOf5_crcLLMFree,
A.consensus_confidence_llm_crc_year as year_confidence_crcLLMFree, A.consensus_month as month_crcLLMFree, A.consensus_year as year_crcLLMFree, A.mCRC as metastatic_crcLLMFree
into #CRCFREE
from <SCHEMA>.ibd_and_nonIBD_crc_free_text_results_2025_04_23 as A
INNER JOIN #cohort as B
on A.PatientID = B.PatientID


-- get cases from path reports
drop table if exists #HGD_CRCPATH
SELECT distinct pathReports.PatientID, pathReports.SpecimenTakenDateTime as crc_dx_date_PATH, pathReports.[T_stage.path] as T_stage_PATH, 
pathReports.[N_stage.path] as N_stage_PATH, pathReports.[location.path] as crc_location_PATH, [lesion_type.path] as lesion_type_PATH
into #HGD_CRCPATH
from <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_04_23 as pathReports
join #cohort as base
on pathReports.PatientID = base.PatientID
where ([lesion_type.path] in ('invasive adenocarcinoma', 'adenocarcinoma', 'intramucosal adenocarcinoma',
	'high grade dysplasia', 'adenocarcinoma in-situ')
OR	[dysplasia_grade.path] in ('adenocarcinoma', 'high grade dysplasia')
)
AND [location.path] not in ('appendix', 'unknown') AND [location.path] is not null

-- Identify the invasive CRC
drop table if exists #CRCPATH
select * into #CRCPATH
from #HGD_CRCPATH
	WHERE
	(T_stage_PATH in ('T1', 'T2', 'T3', 'T4', 'T4a', 'T4b')
	OR N_stage_PATH in ('N1', 'N1a', 'N1b', 'N1c', 'N2', 'N2a', 'N2b')
	OR lesion_type_PATH = 'invasive adenocarcinoma'
	OR (lesion_type_PATH = 'adenocarcinoma' AND T_stage_PATH != 'Tis')) 

-- get cases from Oncology domain
drop table if exists #CRCOD
SELECT distinct OD.PatientID, OD.CRCDxDate as oncDomain_crc_dx_date, OD.SeerSummaryStage2000 as oncDomain_SeerSummaryStage2000, OD.StageGroupingajcc as oncDomain_StageGroupingajcc, OD.PrimarysiteX as oncDomain_PrimarysiteX
into #CRCOD
from <SCHEMA>.OncDomain_advNeo_CRC_Full_2025_08_12 as OD
join #cohort as base
on OD.PatientID = base.PatientID
where invasiveCRC = 1

-- get dates from ICD (to be used if another source is positive)
drop table if exists #CRCICD
SELECT distinct icd.PatientID, MIN(icd.DxDate) as first_crc_ICD_date
into #CRCICD
from <SCHEMA>.vinci_icd_sop_crc_2025_02_27 as icd
join #cohort as base
on icd.PatientID = base.PatientID
group by icd.PatientID

-- get cases from ICD (3+ distinct dates)
drop table if exists #CRCICD_3PLUS
SELECT distinct icd.PatientID, icd_3Plus='true'
into #CRCICD_3PLUS
from <SCHEMA>.vinci_icd_sop_crc_2025_02_27 as icd
join #cohort as base
on icd.PatientID = base.PatientID
group by icd.PatientID
HAVING COUNT(Distinct CAST(icd.DxDate as DATE)) >= 3

-- Combine everything together
drop table if exists #CRC
select distinct base.PatientID, base.IBDC,
CAST(dx_date_crcLLMFree as DATE) as dx_date_crcLLMFree, confidenceOutOf5_crcLLMFree, year_confidence_crcLLMFree, month_crcLLMFree, year_crcLLMFree, metastatic_crcLLMFree,
CAST(crc_dx_date_PATH as DATE) as crc_dx_date_PATH, T_stage_PATH, N_stage_PATH, crc_location_PATH,
CAST(oncDomain_crc_dx_date as DATE) as oncDomain_crc_dx_date, oncDomain_SeerSummaryStage2000, oncDomain_StageGroupingajcc, oncDomain_PrimarysiteX, 
CAST(first_crc_ICD_date as DATE) first_crc_ICD_date, icd_3Plus
into #CRC
from #cohort as base
left join #CRCFREE as t1
on base.PatientID = t1.PatientID
left join #CRCPATH as t2
on base.PatientID = t2.PatientID
left join #CRCOD as t3
on base.PatientID = t3.PatientID
left join #CRCICD as t4
on base.PatientID = t4.PatientID
left join #CRCICD_3PLUS as t5
on base.PatientID = t5.PatientID

-- Aggregate to get frst CRC date
drop table if exists #CRC_agg
select CAST(LEAST(crc_dx_date_PATH, oncDomain_crc_dx_date) as DATE) as aggregate_crc_dx_date,
t1.*
into #CRC_agg
from #CRC as t1

-- If no date from Onc domain or path, use free text date. Also use if over 180 days before and not low confidence
UPDATE #CRC_agg
SET aggregate_crc_dx_date = dx_date_crcLLMFree
	WHERE
	(aggregate_crc_dx_date is null AND dx_date_crcLLMFree is not null)
	OR
	(aggregate_crc_dx_date is not null AND dx_date_crcLLMFree is not null AND year_confidence_crcLLMFree != 'Low' AND DATEDIFF(DAY, dx_date_crcLLMFree, aggregate_crc_dx_date) > 180 )

-- Use first HGD_CRC ICD code date in certain cases where we believe it's a true case
-- 1. CRC free text says the pt has CRC but doesn't have a date
-- 2. We have an aggregate date from OD, Path or free text, but ICDO date is before current aggregate date
-- 3. We don't have a current aggregate date but ICD 3+ is TRUE
UPDATE #CRC_agg
SET aggregate_crc_dx_date = first_crc_ICD_date
	WHERE
	(aggregate_crc_dx_date IS NULL AND confidenceOutOf5_crcLLMFree is not null) 
	OR 
	(first_crc_ICD_date < aggregate_crc_dx_date AND aggregate_crc_dx_date is not null)
	OR
	(icd_3Plus = 'true' AND aggregate_crc_dx_date is null)

-- Save table (CONTAINS DUPLICATE PATIENTS)
drop table if exists <SCHEMA>.finalPheno_crc_2025_08_12
select * into <SCHEMA>.finalPheno_crc_2025_08_12
from #CRC_agg
create clustered columnstore index cci on <SCHEMA>.finalPheno_crc_2025_08_12

-- Save first CRC table (NOTE: includes those without CRC dates which llm says are CRC-positive by free text)
drop table if exists <SCHEMA>.funcPheno_crc_firstDate_2025_08_12
select distinct PatientID, MIN(aggregate_crc_dx_date) as first_crc_dx_date, MAX(IBDC) as IBDC
into <SCHEMA>.funcPheno_crc_firstDate_2025_08_12
from #CRC_agg
where aggregate_crc_dx_date is not null OR confidenceOutOf5_crcLLMFree is not null
group by PatientID
create clustered columnstore index cci on <SCHEMA>.funcPheno_crc_firstDate_2025_08_12


