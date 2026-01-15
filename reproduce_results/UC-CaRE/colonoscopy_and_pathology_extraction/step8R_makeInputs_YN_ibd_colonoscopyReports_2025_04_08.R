# Make inputs for LLM to determine if a note is a colonoscopy report
# Step 8 can be done using python or R (see 'step8Py_...')
library(VINCI)
library(DBI)
library(stringdist)

# Remove vars
rm(list = ls())

# Set working directory
setwd("<PATH>")

# Convert from SQL text to LLM friendly text
fix_text <- function(input){
  tmp <- stringr::str_replace_all(input, "\r\n", "\n")
  tmp <- stringr::str_replace_all(tmp, "\r", "\n")
  gsub("\n", "\\n", tmp, fixed = T)
}

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Pull in the notes
all <- DBI::dbGetQuery(conn, paste0('select distinct coh.NoteID, coh.PatientID, notes.ReportText, notes.EntryDateTime 
                    from <SCHEMA>.putative_ibd_coloReports_2025_04_02 as coh
                    join <SCHEMA>.NoteTable as notes
          on notes.NoteID = coh.NoteID'))

all$ReportText <- fix_text(all$ReportText)

# Make sure note ID is in string format (vs. numeric)
all$NoteID <- paste0(all$NoteID)

# Append yes/no question
all$ReportText_for_llm <- paste0(all$ReportText, "\\n>>>\\n\\nIs the text above a colonoscopy report?")

writeLines(all$ReportText_for_llm, "./yesNo/input/input.txt", useBytes=T)
writeLines(all$NoteID, "./yesNo/input/NoteIDs.txt", useBytes=T)




