# Process dysplasia Classifier output
library(jsonlite)
library(ggplot2)
library(VINCI)
library(DBI)

rm(list=ls())

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Pull in table to add PatientID 
all_pathReports <- DBI::dbGetQuery(conn, paste0('select distinct T1.PatientID, T1.PathologyReportID, T2.NoteID, T1.SpecimenTakenDateTime, T4.EntryDateTime
                                                from <SCHEMA>.path_dys_terms_positive_ALL_2024_12_26 as T1
                                                join <SCHEMA>.baseTable5_llms_2025_01_28 as T3
                                                on T3.PatientID = T1.PatientID
                                                left join <SCHEMA>.<table_linking_pathology_to_full_notes> as T2
                                                on T2.PathologyReportID = T1.PathologyReportID
                                                left join NoteTable as T4
                                                on T4.NoteID = T2.NoteID'))

setwd("<PATH>")

# Read in raw inputs
llamaRaw <- readLines("./raw_output/output.txt")

# Function to parse JSON txt data and create a dataframe
readJSON2df <- function(x){
  json_match <- gsub("\\n", "\n",stringr::str_extract(x, "\\[.*\\{.*\\}.*\\]"), fixed=T)
  id <- unlist(strsplit(x, split = "\t", fixed = T))[2]
  if(!is.na(json_match)){
    data <- fromJSON(json_match)
    data$PathologyReportID <- id
    data$aggregate_or_single <- sapply(data$length, function(x){
      unlist(strsplit(x, split = ", ", fixed = T))[2]
    })
    data$length_units <- "mm"
    data$length_units[grepl("cm", data$length, fixed = T)] <- "cm"
    data$length_min <- sapply(data$length, function(x){
      head(unlist(stringr::str_extract_all(x, "\\d+\\.?\\d*")), 1)
    })
    data$length_max <- sapply(data$length, function(x){
      tail(unlist(stringr::str_extract_all(x, "\\d+\\.?\\d*")), 1)
    })
    data$length_max_cm <- as.numeric(data$length_max)
    data$length_max_cm[data$length_units == "mm"] <- data$length_max_cm[data$length_units == "mm"]/10
    return(data)
  }else{
    return(data.frame("sample_ID" = NA, "number_of_fragments"=NA, "description"= NA,
                      "length"=NA, "specimen_type"=NA, "lesion_type"=NA,
                      "number_of_concerning_lesions" = NA,  "indication" = NA,
                      "location"=NA,  "shape"=NA,"dysplasia_grade"=NA,
                      "length_units" = NA, "length_min" = NA,
                      "length_max" = NA, "length_max_cm" = NA,
                      "aggregate_or_single" = NA,
                      "inflammation_severity"=NA,"inflammation_type"=NA,
                      "T_stage"=NA,"N_stage"=NA,"PathologyReportID" = id))
  }
}

# Run the function for all inputs
llamaTmp <- do.call(rbind, lapply(llamaRaw, readJSON2df))
# Add info from the input table
llama.df <- merge(llamaTmp, all_pathReports, by = "PathologyReportID")
# Order by Note date
llama.df <- llama.df[order(llama.df$EntryDateTime, decreasing = T),]
			
# Save as CSV			
write.csv(llama.df, "./dysplasiaClassifier/results/llama70_results_2025_04_22.csv", row.names=F)

