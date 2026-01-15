# Make inputs for the dysplasia classifier, including full path reports AND
# concatenated sections for "pseudo-full" path reports
library(VINCI)
library(DBI)
library(stringdist)

# Remove vars
rm(list = ls())

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Convert carriage returns to newline and then escape newlines ("\n" -> "\\n")
fix_text <- function(input){
  tmp <- stringr::str_replace_all(input, "\r\n", "\n")
  tmp <- stringr::str_replace_all(tmp, "\r", "\n")
  gsub("\n", "\\n", tmp, fixed = T)
}

# Pull full pathology reports
full_pathReports <-  DBI::dbGetQuery(conn, paste0('select * from johnsb2.ibd_fullPathReports_dysplasiaPlus_2025_01_31'))
full_ordered <- full_pathReports[order(full_pathReports$EntryDateTime, decreasing = T),]
full_dedup <- full_ordered[!duplicated(full_ordered$PathologyReportID),]
full <- full_dedup
full$PathologyReportID <- paste0(full$PathologyReportID)
full$llm_text <- fix_text(full$ReportText)

# Pull missing full text notes (with entries in path domain)
missing_pathReports <- DBI::dbGetQuery(conn, paste0('select * from johnsb2.ibd_missing_fullPathReports_2025_31_01'))
missing_ordered <- missing_pathReports[order(missing_pathReports$SpecimenTakenDateTime, decreasing = T),]
uniqueSurgPath <- unique(missing_ordered$PathologyReportID)
out.df <- data.frame("PathologyReportID" = character(), "llm_text" = character())

# Aggregate into a pseudo-report by concatenating sections
for (i in 1:length(uniqueSurgPath)){
  surgPath <- uniqueSurgPath[i]
  entries <- missing_ordered[missing_ordered$PathologyReportID==surgPath,]
  entries <- entries[order(entries$Specimen),]
  text <- paste0(fix_text(entries$Specimen[!is.na(entries$Specimen)]), collapse = "\\n")
  text <- paste0("Specimen:\\n", text)
  
  if(any(!is.na(entries$GrossDescription))){
    gross <-  entries$GrossDescription[which(!is.na(entries$GrossDescription))[1]]
    text <- paste0(text, "\\nGross Description:\\n", fix_text(gross))
  }
  if(any(!is.na(entries$MicroscopicDescription))){
    micro <-  entries$MicroscopicDescription[which(!is.na(entries$MicroscopicDescription))[1]]
    text <- paste0(text, "\\nMicroscopic Description:\\n", fix_text(micro))
  }
  if(any(!is.na(entries$SurgicalPathologyDiagnosis))){
    diagnosis <-  entries$SurgicalPathologyDiagnosis[which(!is.na(entries$SurgicalPathologyDiagnosis))[1]]
    text <- paste0(text, "\\nDiagnosis:\\n", fix_text(diagnosis))
  }
  out.df <- rbind(out.df, data.frame("PathologyReportID" = paste0(surgPath), "llm_text" = text))
}

combined <- rbind(out.df, full[,c("PathologyReportID", "llm_text")])

# Shuffle 
combined <- combined[sample(1:nrow(combined), size = nrow(combined), replace=F),]

# Write to txt files for LLM inference
writeLines(combined$PathologyReportID, "./dysplasiaClassifier/PathologyReportIDs.txt")
writeLines(combined$llm_text, "./dysplasiaClassifier/input.txt")
