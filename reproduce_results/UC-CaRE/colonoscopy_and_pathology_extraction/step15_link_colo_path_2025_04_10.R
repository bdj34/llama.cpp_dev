# Create a set of linked colonoscopy and pathology reports
# And create inputs for unlinked analysis

library(VINCI)
library(DBI)
library(jsonlite)

rm(list=ls())

setwd("<PATH>")

# Convert from SQL text to LLM friendly text
fix_text_keep_newLines <- function(input){
  tmp <- stringr::str_replace_all(input, "\r\n", "\n")
  tmp <- stringr::str_replace_all(tmp, "\r", "\n")
  return(tmp)
}

# Read in the dysplasia classifier stuff
llama_dysClass <- read.csv(".gpu/dysplasiaClassifier/results/llama70_results_2025_04_10.csv")
llama_dysClass$SurgicalPathologySID <- paste0(llama_dysClass$SurgicalPathologySID)
llama_dysClass <- llama_dysClass[!is.na(llama_dysClass$PatientID),]
llama_dysClass <- llama_dysClass[!is.na(llama_dysClass$sample_ID),]

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Pull in the potential colonoscopy Report notes
all <- DBI::dbGetQuery(conn, paste0('select distinct coh.NoteID, coh.PatientID, notes.ReportText, notes.EntryDateTime
                    from <SCHEMA>.putative_ibd_coloReports_2025_04_02 as coh
                    join <SCHEMA>.NoteTable as notes
                    on notes.NoteID = coh.NoteID'))
phiPos <- read.csv("./yesNo/results/phi_output_YN_positive_2025_04_10.csv")
coloReports <- all[all$NoteID %in% phiPos$NoteID,]

# For each unique patient, loop to get their "colonoscopy reports" near relevant dysplasia classifier results
unique_ptIDs <- unique(llama_dysClass$PatientID)
colsKeep_llm <- c("sample_ID", "description", "location", "indication")
between_text <- "\n\n## JSON information about lesion(s) of interest:\n"

out.df <- llama_dysClass[0,]; out.df$coloReportText_forLLM = character()
out.df$coloReportTIUDocSIDs = character()

for(i in 1:length(unique_ptIDs)){
  dys.df <- llama_dysClass[llama_dysClass$PatientID == unique_ptIDs[i],]
  colo.df <- coloReports[coloReports$PatientID == unique_ptIDs[i],]
  uniqDates <- unique(as.Date(dys.df$SpecimenTakenDateTime))

  for(j in 1:length(uniqDates)){
    thisDys <- dys.df[as.Date(dys.df$SpecimenTakenDateTime)==uniqDates[j],]
    thisColo <- colo.df[abs(difftime(uniqDates[j],
                              as.Date(colo.df$EntryDateTime), units = "days")) <= 30,]

    # If 1 or 2 matching colonoscopy reports, use both and concatenate
    if(nrow(thisColo) != 0 & nrow(thisColo) < 3){
      forLLM <- paste0(paste0(thisColo$ReportText, collapse = "<<<<<<<<<<\n\n>>>>>>>>>>"),
                                       between_text, toJSON(thisDys[,colsKeep_llm]))
      thisDys$coloReportText_forLLM <- forLLM
      thisDys$coloReportTIUDocSIDs <- paste0(thisColo$NoteID, collapse = ", ")
      out.df <- rbind(out.df, thisDys)

    # If more than 2, cut down to 2 maximum
    }else if(nrow(thisColo) > 3){

      # Filter to those where entry date time is same day or after specimen date time
      filterColo <- thisColo[difftime(as.Date(thisColo$EntryDateTime), uniqDates[j], units = "days") >= 0,]

      # If 1 or 2 remain, concatenate
      if(nrow(filterColo) != 0 & nrow(filterColo) < 3){
        forLLM <- paste0(paste0(filterColo$ReportText, collapse = "<<<<<<<<<<\n\n>>>>>>>>>>"),
                                  between_text, toJSON(thisDys[,colsKeep_llm]))

      }else if(nrow(filterColo) != 0){ # Take two closest dates
        x <- difftime(as.Date(filterColo$EntryDateTime), uniqDates[j], units = "days")
        indexKeep <- order(x)[1:2]
        forLLM <- paste0(paste0(filterColo$ReportText[indexKeep], collapse = "<<<<<<<<<<\n\n>>>>>>>>>>"),
                                  between_text, toJSON(thisDys[,colsKeep_llm]))

      }else{ # If none remain, go back to intial matches and pull closest 2 dates
        x <- difftime(as.Date(thisColo$EntryDateTime), uniqDates[j], units = "days")
        indexKeep <- order(x)[1:2]
        forLLM <- paste0(paste0(thisColo$ReportText[indexKeep], collapse = "<<<<<<<<<<\n\n>>>>>>>>>>"),
                                  between_text, toJSON(thisDys[,colsKeep_llm]))
      }

      thisDys$coloReportText_forLLM <- forLLM
      thisDys$coloReportTIUDocSIDs <- paste0(thisColo$NoteID, collapse = ", ")
      out.df <- rbind(out.df, thisDys)
    }
  }
}

out.df$coloReportText_forLLM <- fix_text_keep_newLines(out.df$coloReportText_forLLM)
DBI::dbWriteTable(conn, "linked_path_colo_reports_IBD_2025_04_10", out.df)
write.csv(out.df, "./linked/inputs/linked_path_colo_reports_IBD_2025_04_10.csv", row.names=F)
