# Read in the JSON from colonoscopy reports for the 'unlinked' analysis
library(jsonlite)
library(ggplot2)
library(VINCI)
library(DBI)

rm(list=ls())

setwd("<PATH>")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Pull in table to add PatientICN and date
all_coloReports <- DBI::dbGetQuery(conn, paste0('select distinct PatientICN, EntryDateTime, TIUDocumentSID
                                                 from <SCHEMA>.putative_ibd_coloReports_2025_04_02'))

outFiles <- list.files("./colonoscopyReports/pos/mistralRaw/", pattern="output", full.names = T)
mistralRaw <- unlist(sapply(outFiles, readLines)); names(mistralRaw) <- NULL

cat(gsub("\\n", "\n", mistralRaw[10], fixed=T))

readJSON2df <- function(x){
  json_match <- paste0("[", gsub("\\n", "\n",stringr::str_extract(x, "\\{.*\\}"), fixed=T), "]")
  id <- unlist(strsplit(x, split = "\t", fixed = T))[2]
  data <- fromJSON(json_match)
  data$TIUDocumentSID <- id
  return(data)
}

mistralTmp <- do.call(rbind, lapply(mistralRaw, readJSON2df))
mistral.df <- merge(mistralTmp, all_coloReports, by = "TIUDocumentSID", all.x=T)
table(is.na(mistral.df$EntryDateTime))

write.csv(mistral.df, "./colonoscopyReports/pos/results/mistral_results_2025_04_22.csv", row.names=F)
