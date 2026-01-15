use <DATABASE>;

-- see R script for how this was made: /nlp_v2/IBD_dx/colonoscopyReports/link_colo_path_2025_04_10.R
select * into <SCHEMA>.linked_path_colo_reports_IBD_2025_04_10
from <R_SCHEMA>.[linked_path_colo_reports_IBD_2025_04_10]
create clustered columnstore index cci on <SCHEMA>.linked_path_colo_reports_IBD_2025_04_10

select distinct * from <SCHEMA>.linked_path_colo_reports_IBD_2025_04_10

-- Save as csv for python processing
select distinct PathologyReportIDs, coloReportText_forLLM as InputText
from <SCHEMA>.linked_path_colo_reports_IBD_2025_04_10
-- CSV name: "colo_path_linked.csv"
