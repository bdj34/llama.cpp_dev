# Make a sql table with colectomy-aware CRC and HGD/CRC

library(VINCI)
library(DBI)

rm(list=ls())

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

source("<PATH>/finalPhenotypes/fns/colectomy_aware_hgd_crc_fns.R") # Step 2B

base <-  DBI::dbGetQuery(conn, paste0('select * from <SCHEMA>.base_ibd_and_nonIBD'))

# Use all colectomy and keep only VA
colectomy <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.finalPheno_firstColectomy_2025_06_24"))

hgd_crc_ICDAll <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.vinci_icd_sop_hgd_crc_2025_06_16"))
hgd_crc_ICD <- hgd_crc_ICDAll[hgd_crc_ICDAll$PatientID %in% base$PatientID,]

hgd_crcAll_fromSQL <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.finalPheno_hgd_crc_2025_08_12
                                    where aggregate_hgd_crc_dx_date is not null OR confidenceOutOf5_crcLLMFree is not null"))
hgd_crc_fromSQL <- hgd_crcAll_fromSQL[hgd_crcAll_fromSQL$PatientID %in% base$PatientID,]
hgd_crc <- get_hgd_crc(hgd_crc_fromSQL, colectomy, hgd_crc_ICD)

hgd_crc_withColectomy <- merge(hgd_crc, colectomy[,c("PatientID", "colectomyDate_llm_cpt")],
                               by = "PatientID", all.x=T, all.y=F)
hgd_crc_withIBDC <- merge(hgd_crc, base[,c("PatientID", "IBDC")],
                          by = "PatientID", all.x=T, all.y=F)

# Write to SQL
DBI::dbWriteTable(conn, "colectomy_aware_hgd_crc_2025_09_05", hgd_crc_withIBDC, overwrite=T)


# Now do the same for invasive CRC
crc_ICDAll <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.vinci_icd_sop_crc_2025_02_27"))
crc_ICD <- crc_ICDAll[crc_ICDAll$PatientID %in% base$PatientID,]

crcAll_fromSQL <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.finalPheno_crc_2025_08_12 
                                                   where aggregate_crc_dx_date is not null OR 
                                               confidenceOutOf5_crcLLMFree is not null"))
crc_fromSQL <- crcAll_fromSQL[crcAll_fromSQL$PatientID %in% base$PatientID,]
crc <- get_crc(crc_fromSQL, colectomy, crc_ICD)

crc_withColectomy <- merge(crc, colectomy[,c("PatientID", "colectomyDate_llm_cpt")],
                               by = "PatientID", all.x=T, all.y=F)
crc_withIBDC <- merge(crc, base[,c("PatientID", "IBDC")],
                          by = "PatientID", all.x=T, all.y=F)

# Write to SQL
DBI::dbWriteTable(conn, "colectomy_aware_crc_2025_09_05", crc_withIBDC, overwrite=T)



