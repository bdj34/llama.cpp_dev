# Aggregate LLM dx year with base table 5

library(VINCI)
library(DBI)
library(ggplot2)

# Remove vars
rm(list = ls())

setwd("<PATH>")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = 'SERVER')

# Get all IBD patients (with PatientSID)
base <- DBI::dbGetQuery(conn, "select * from <SCHEMA>.baseTable_with_llms")

# Get dx years from llms
llm <- read.csv("./ibdYearAll/results/output_llama_gemma_phi_2025_03_11.csv")
llm$llm_ibd_dx_year_conf <- llm$Confidence_consensus
llm$llm_ibd_dx_year <- llm$Year_consensus_numeric
llm$llm_ibd_dx_date_approx <- "NA"
llm$llm_ibd_dx_date_approx[!is.na(llm$llm_ibd_dx_year)] <- 
  paste0(llm$llm_ibd_dx_year[!is.na(llm$llm_ibd_dx_year)], "-07-01")
llm$llm_ibd_dx_date_approx[llm$llm_ibd_dx_date_approx == "NA"] <- NA 
  
base_with_llm <- merge(base, llm[,c("PatientID", "llm_ibd_dx_year_conf", "llm_ibd_dx_year",
                               "llm_ibd_dx_date_approx")], by = "PatientID", all.x=T)

icdBase <- DBI::dbGetQuery(conn, "select distinct base.PatientID, DateOfBirth, DateOfDeath,
                      IBDDxDateICD
                      from <SCHEMA>.Cohort as coh
                      join <SCHEMA>.baseTable as base
                      on coh.PatientID = base.PatientID
                      where base.IBDDxDateICD is not null;")

base_llm <- merge(base_with_llm, icdBase, by = "PatientID", all = F)

# Save base with LLM results
write.csv(base_llm, "./ibdYearAll/results/llm_and_base_2025_03_11.csv", row.names=F)
dbWriteTable(conn, "base_with_llm_years", base_llm)

