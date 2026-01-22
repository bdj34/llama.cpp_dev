library(VINCI)
library(DBI)
library(pbapply)

rm(list=ls())

setwd("<PATH>/nlp_v2/IBD_dx")

source("./colonoscopy/process_colonoscopy_fn.R") # See 'step4B'

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Get all IBD patients (with PatientID)
base <- DBI::dbGetQuery(conn, "select * from <SCHEMA>.baseTable_with_llms")

cpt <- DBI::dbGetQuery(conn, paste0("select cpt.* from 
                    <SCHEMA>.colonoscopy_CPT_allPts_2025_01_13 cpt
                    join <SCHEMA>.baseTable_with_llms as base
                    on base.PatientID = cpt.PatientID"))

all(cpt$PatientID %in% base$PatientID)

# Read in, process, save, mistrals
mistralRaw <- readLines("./colonoscopy/mistralRaw/output.txt")
mistral.df <- process_colonoscopy(mistralRaw)
write.csv(mistral.df, "./colonoscopy/singleModelResults/mistral_results_2025_03_11.csv", row.names=F)

# Read in, process, save, phis
phiRaw <- readLines("./colonoscopy/phiRaw/output.txt")
phi.df <- process_colonoscopy(phiRaw)
write.csv(phi.df, "./colonoscopy/singleModelResults/phi_results_2025_03_11.csv", row.names=F)

# Read in, process, save, gemmas
gemmaRaw <- readLines("./colonoscopy/gemmaRaw/output.txt")
gemma.df <- process_colonoscopy(gemmaRaw)
write.csv(gemma.df, "./colonoscopy/singleModelResults/gemma_results_2025_03_11.csv", row.names=F)

# Add model names and prefix with A, B, C, for later sorting
phi.df$llm <- "B_phi4-14B"
gemma.df$llm <- "C_gemma2SPPO-9B"
mistral.df$llm <- "A_Mistral-24B"

# rbind
all_llms <- do.call(rbind, list(phi.df, gemma.df, mistral.df))
all_llms <- all_llms[all_llms$PatientID %in% base$PatientID,]
all_llms$PatientID <- paste0(all_llms$PatientID)
pos_llms <- all_llms[all_llms$ColonoscopyYN,]
pos <- pos_llms[!duplicated(pos_llms),]
pos$llm_date <- as.Date(paste0(pos$Year, "-", match(pos$Month, month.name), "-15"), format="%Y-%m-%d")
table(is.na(pos$llm_date))

pos$cpt_date <- as.Date("")
uniqICN <- unique(pos$PatientID)

# Match with closest cpt if < 60 days difference
pos_list <- pblapply(uniqICN, function(x){
  posTmp <- pos[pos$PatientID==x,]
  cptTmp <- cpt[cpt$PatientID==x,]
  
  for(j in 1:nrow(posTmp)){
    dateDifferences <- difftime(as.Date(posTmp$llm_date[j]), as.Date(cptTmp$ProcDate), units="days")
    diffUse <- dateDifferences[abs(dateDifferences) <= 60]
    if(length(diffUse[!is.na(diffUse)]) > 0){
      minDiff <- min(abs(diffUse))
      posTmp$cpt_date[j] <- cptTmp$ProcDate[which(abs(difftime(as.Date(cptTmp$ProcDate), as.Date(posTmp$llm_date[j]), units="days"))==minDiff)[1]]
    }
  }
  return(posTmp)
})

out <- as.data.frame(data.table::rbindlist(pos_list))

out$supporting_evidence <- "none"
out$supporting_evidence[!is.na(out$cpt_date)] <- "CPT"

# Order and de-duplicate
matched <- out[!is.na(out$cpt_date),]
matched_ordered <- matched[order(matched$llm),]
matched_dedup <- matched_ordered[!duplicated(paste0(matched_ordered$PatientID, matched_ordered$cpt_date)),]

unmatched <- out[is.na(out$cpt_date),]
unmatched <- unmatched[!is.na(unmatched$Year),]

# Separate into three different tables
mistral_unmatched <- unmatched[unmatched$llm == "A_Mistral-24B",]
gemma_unmatched <- unmatched[unmatched$llm == "C_gemma2SPPO-9B",]
phi_unmatched <- unmatched[unmatched$llm == "B_phi4-14B",]

colnames(mistral_unmatched) <- paste0(colnames(mistral_unmatched), ".mistral")
colnames(gemma_unmatched) <- paste0(colnames(gemma_unmatched), ".gemma")
colnames(phi_unmatched) <- paste0(colnames(phi_unmatched), ".phi")

mistral_unmatched$mergeOn <- paste(mistral_unmatched$PatientID.mistral, mistral_unmatched$Year.mistral)
gemma_unmatched$mergeOn <- paste(gemma_unmatched$PatientID.gemma, gemma_unmatched$Year.gemma)
phi_unmatched$mergeOn <- paste(phi_unmatched$PatientID.phi, phi_unmatched$Year.phi)

mistral_gemma <- merge(mistral_unmatched, gemma_unmatched, by = "mergeOn", all.x=T)
merged <- merge(mistral_gemma, phi_unmatched, by = "mergeOn", all.x=T)

# Remove rows with only mistral entries (denote which rows have support from which models)
cut_merged <- merged[!is.na(merged$Year.gemma) | !is.na(merged$Year.phi),]
cut_merged$supporting_evidence.mistral[!is.na(cut_merged$Year.gemma) & !is.na(cut_merged$Year.phi)] <- "both gemma-2-9B and phi-4-14B"
cut_merged$supporting_evidence.mistral[!is.na(cut_merged$Year.gemma) & is.na(cut_merged$Year.phi)] <- "gemma-2-9B only"
cut_merged$supporting_evidence.mistral[is.na(cut_merged$Year.gemma) & !is.na(cut_merged$Year.phi)] <- "phi-4-14B only"

# Only keep mistral columns
restrictCols <- colnames(cut_merged)[grepl("mistral", colnames(cut_merged))]
unmatched_keep <- cut_merged[,restrictCols]
colnames(unmatched_keep) <- gsub(".mistral", "", colnames(unmatched_keep), fixed=T)

# Order by month being known (known dates ordered first is not NA)
ordered <- unmatched_keep[order(unmatched_keep$llm_date, na.last=T),]
# dedup <- ordered[!duplicated(paste0(ordered$PatientID, ordered$llm_date)) |
#                    !((duplicated(paste0(ordered$PatientID, ordered$Year))) & ordered$Month == "Unknown"),]
dedup1 <- ordered[!duplicated(paste0(ordered$PatientID, ordered$llm_date)),]
dedup <- dedup1[!(duplicated(paste0(dedup1$PatientID, dedup1$Year)) & dedup1$Month == "Unknown"),]

all <- rbind(dedup, matched_dedup)

# Set 2025 dates to Feb instead of July because we ran in March/April (midpoint is Feb)
all$llm_date[is.na(all$llm_date) & all$Year=="2025"] <- as.Date("2025-02-01")
all$llm_date[is.na(all$llm_date)] <- as.Date(paste0(all$Year[is.na(all$llm_date)], "-07-01"))

# Note: there will be additional CPT that aren't in this!
write.csv(all, "./colonoscopy/results/results_ibd_colonoscopy_timing_2025_04_23.csv", row.names=F)
dbWriteTable(conn, "results_ibd_colonoscopy_timing_2025_04_23", all)
