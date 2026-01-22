# Identify LGD from path reports linked with colonoscopy reports
# for feeding to LLM to ascertain completeness of resection
library(VINCI)
library(DBI)
library(bit64)
library(jsonlite)

rm(list=ls())

setwd("<PATH>/targetedCompleteness/")

source("<PATH>/targetedCompleteness/fns/preprocessing_fns.R")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

fix_text <- function(x){
  # Replace carriage returns with normal "\n"
  reportText <- stringr::str_replace_all(x, "\r\n", "\n")
  reportText <- stringr::str_replace_all(reportText, "\r", "\n")
  
  # Escape new lines so each line in the txt file is one path report section
  # C++ code will convert \\n back to \n
  reportText <- gsub("\n", "\\n", reportText, fixed = T)
  return(reportText)
}

# Get linked colonoscopy and pathology report data
linked_path <- DBI::dbGetQuery(conn, paste0("select * from johnsb2.ibd_and_nonIBD_path_colo_results_2025_05_12"))

# Link each PathologyReportID to the linked NoteID of the colonoscopy reports
uniqPathReportIDs <- unique(linked_path$PathologyReportID)
out.df <- data.frame("PathologyReportID" = character(), "ColonoscopyReportID_linked" = character())
for(i in 1:length(uniqPathReportIDs)){
  tmp <- linked_path[linked_path$PathologyReportID == uniqPathReportIDs[i],]
  ColonoscopyReportIDs <- unique(tmp$ColonoscopyReportIDs.linked[!is.na(tmp$ColonoscopyReportIDs.linked)])
  if(any(is.na(ColonoscopyReportIDs))){stop()}
  
  out.df <- rbind(out.df, data.frame("PathologyReportID" = uniqPathReportIDs[i],
                                     "ColonoscopyReportID_linked" = as.integer64(ColonoscopyReportIDs)))
  if(any(is.na(out.df$ColonoscopyReportID_linked))){stop()}
}

# Write to SQL
DBI::dbWriteTable(conn, "ColonoscopyReportIDs_PathReportIDs_forLLM", out.df, overwrite=T)

# Pull the necessary Notes from SQL
coloReports <- DBI::dbGetQuery(conn, paste0('select distinct coloNotes.PathologyReportID, notes.ColonoscopyReportID, notes.EntryDateTime, notes.ReportText 
                                      from <SCHEMA>.NoteTable as notes
                                      join [<DATABASE>].[<SCHEMA>].[ColonoscopyReportIDs_PathReportIDs_forLLM] as coloNotes
                                      on coloNotes.ColonoscopyReportID_linked = notes.ColonoscopyReportID'))
coloReports$ReportText_for_llm <- fix_text(coloReports$ReportText)

# Add description from llama output from path reports
llama <- read.csv("<PATH>/dysplasiaClassifier/results/llama70_results_2025_04_22.csv")
llama <- llama[!is.na(llama$sample_ID),]

# Set up variable that is PathReportID and sample ID
llama$PathID_and_sample <- paste0(llama$PathologyReportID, "_", llama$sample_ID)
linked_path$PathID_and_sample <- paste0(linked_path$PathologyReportID, "_", linked_path$sample_ID.path)

# Merge on PathReportID and sample ID
linked_path_withDescription <- merge(linked_path, llama[,c("PathID_and_sample", "description")], by = "PathID_and_sample", all.x=T)
linked_path_dedup <- linked_path_withDescription[!duplicated(linked_path_withDescription),]

# Need to get report text from the txt files made by python
inputs_path <- readLines("<PATH>/dysplasiaClassifier/input.txt")
inputs_SID <- readLines("<PATH>/dysplasiaClassifier/PathReportIDs.txt")

pathInputs <- data.frame("PathologyReportID" = inputs_SID,
                         "PathologyReportText" = inputs_path)
stopifnot(all(linked_path$PathologyReportID %in% pathInputs$PathologyReportID))

input_txt <- c(); PathID_and_sample <- c()
colsCheck <- c("indication.unlinked", "colitis_extent.unlinked", 
               "colitis_severity.unlinked", "landmarks_reached.unlinked", "bowel_prep_quality.unlinked", 
               "random_biopsies_taken.unlinked", "number_of_visible_lesions.unlinked", 
               "max_visible_lesion_size.unlinked")
beforeColo <- "<<<<<<<<<<\\n\\n>>>>>>>>>>\\nColonoscopy report:\\n"

# Loop through and create single input for each PathologyReportID
# Skip if nrow(structuredLGD) is 0
for(i in 1:length(uniqPathReportIDs)){
  sid <- uniqPathReportIDs[i]
  icn <- linked_path$PatientICN[which(linked_path$PathologyReportID == sid)[1]]
  pt <- linked_path[which(linked_path$PatientICN == icn),]
  indexLGD_date <- pt$SpecimenTakenDateTime[which(pt$PathologyReportID==sid)[1]]
  
  # Only use LGD
  structuredAll <- linked_path_dedup[which(linked_path_dedup$PathologyReportID==sid),]
  structured <- return_only_lgd(structuredAll)
  structured <- structured[!is.na(structured$ColonoscopyReportID.linked),]
  if(nrow(structured) == 0){next}
  
  path <- pathInputs[pathInputs$PathologyReportID==sid,]
  if(nrow(path)>1){path <- path[which.max(nchar(path$PathologyReportText)),]}
  colo <- coloReports[coloReports$PathologyReportID==sid,]
  
  for(j in 1:nrow(structured)){
    
    # Exclude ones where we are confident that it's a random biopsy
    if(invisible_bools(structured[j,])){
      next
    }
    
    # Identify where there is more than one linked colonoscopy report
    if(grepl(",", structured$ColonoscopyReportID.linked[j], fixed=T)){
      
      # Choose the note where the most colonoscopy information is known, and others if additional info is given
      min_not_stated <- min(rowSums(structured[,colsCheck] == "not stated"), na.rm=F)
      stopifnot(!is.na(min_not_stated))
      bestColos <- which(rowSums(structured[,colsCheck] == "not stated") <= min_not_stated + 1)
      bestColos_sorted <- bestColos[order(rowSums(structured[bestColos,colsCheck] == "not stated"), decreasing = F)]
      
      ColonoscopyReportIDs_linkedKeep <- unique(structured$ColonoscopyReportID.unlinked[head(bestColos_sorted, 3)])
      coloKeepAll <- colo[colo$ColonoscopyReportID %in% ColonoscopyReportIDs_linkedKeep,]
      coloKeep <- coloKeepAll[!duplicated(coloKeepAll$ReportText_for_llm) & nchar(coloKeepAll$ReportText_for_llm) < 30000,]
      
    }else{
      coloKeep <- colo
    }
    
    if(grepl("unknown", structured[j,"sample_ID.path"])){
      forLLM <- paste0("\\nDetermine the resection status of the lesion matching the following description: '", structured[j,"description"], "'.\\n",
                       "\\n>>>>>>>>>>\\nPathology report:\\n",
                       fix_text(path$PathologyReportText),
                       beforeColo,
                       paste0(coloKeep$ReportText_for_llm, collapse = beforeColo),
                       "<<<<<<<<<<\\n\\nWhat is the resection status of the lesion matching the description '", structured[j,"description"], "'?\\n")
    }else{
      forLLM <- paste0("\\nDetermine the resection status of specimen ", structured[j,"sample_ID.path"], " from the following reports.\\n",
                       "\\n>>>>>>>>>>\\nPathology report:\\n",
                       fix_text(path$PathologyReportText),
                       beforeColo,
                       paste0(coloKeep$ReportText_for_llm, collapse = beforeColo),
                       "<<<<<<<<<<\\n\\nWhat is the resection status of specimen ", structured[j,"sample_ID.path"], "?\\n")
    }
    
    
    input_txt <- c(input_txt, forLLM)
    PathID_and_sample <- c(PathID_and_sample, paste0(structured$PathID_and_sample[j], "_", 
                                               paste0(coloKeep$ColonoscopyReportID, collapse = "_")))
  }
  
}

# Print random one to check formatting
cat(gsub("\\n", "\n", input_txt[sample(1:length(input_txt), size = 1)], fixed=T))

# De-duplicate (duplication due to multiple unlinked reports)
duplicated_input_txt <- duplicated(input_txt)

input_txt_dedup <- input_txt[!duplicated_input_txt]
PathID_and_sample_dedup <- PathID_and_sample[!duplicated_input_txt]

input_txt_sorted <- input_txt_dedup[order(nchar(input_txt_dedup))]
PathID_and_sample_sorted <- PathID_and_sample_dedup[order(nchar(input_txt_dedup))]

PathID_and_sample <- PathID_and_sample_sorted
inputs <- input_txt_sorted

# Write to txt files for LLM inference
writeLines(inputs, paste0("<PATH>/targetedCompleteness/inputs/inputs_",
                          Sys.Date(), ".txt"), useBytes=T)
writeLines(PathID_and_sample, paste0("<PATH>/targetedCompleteness/inputs/PathID_and_sample_",
                                  Sys.Date(), ".txt"), useBytes=T)

