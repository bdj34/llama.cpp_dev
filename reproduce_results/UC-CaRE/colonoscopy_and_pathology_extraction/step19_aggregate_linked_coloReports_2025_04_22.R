# Read in the JSON from colonoscopy reports for the linked analysis
library(jsonlite)
library(ggplot2)
library(VINCI)
library(DBI)

rm(list=ls())

setwd("<PATH>")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Pull in table to add PatientICN and date. Fix multiple TIU Doc SIDs
linked_coloReports <- DBI::dbGetQuery(conn, paste0('select distinct PathologyReportIDs, coloReportNoteIDs as NoteID
                                                 from <SCHEMA>.linked_path_colo_reports_IBD_2025_04_10'))
linked_coloReports$NoteID <- paste0(linked_coloReports$NoteID)

outFiles <- list.files("./colonoscopyReports/linked/mistralRaw/", pattern="output", full.names = T)
mistralRaw <- unlist(sapply(outFiles, readLines)); names(mistralRaw) <- NULL

cat(gsub("\\n", "\n", mistralRaw[20], fixed=T))

dataAll <- NULL; broken_json_ids <- c()
colsKeep <- c("sample_ID", "size", "location", "morphology", 
              "completeness_of_resection", "random_bx", "PathologyReportIDs")
for(i in 1:length(mistralRaw)){
  json_match <- gsub("\\n", "\n",stringr::str_extract(mistralRaw[i], "\\[.*\\{.*\\}.*\\]"), fixed=T)
  id <- unlist(strsplit(mistralRaw[i], split = "\t", fixed = T))[2]
  
  if(validate(json_match)){
    data <- fromJSON(json_match)
    data$PathologyReportIDs <- id
    data <- data[,colsKeep]
    
    if(is.null(dataAll)){
      dataAll <- data
    }else{
      dataAll <- rbind(dataAll, data)
    }
  }else{
    broken_json_ids <- c(broken_json_ids, id)
  }
}

out <- merge(dataAll, linked_coloReports, by = "PathologyReportIDs", all.x=T)

write.csv(out, "./colonoscopyReports/linked/results/linked_colo_results_2025_04_23.csv", row.names=F)

