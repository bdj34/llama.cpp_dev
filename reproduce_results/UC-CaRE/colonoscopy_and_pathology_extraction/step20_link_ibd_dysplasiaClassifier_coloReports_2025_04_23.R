# Read in from dysplasia Classifier output and colonoscopy report (linked and unlinked) outputs.
# Link colo/path data to create a single table
library(jsonlite)
library(ggplot2)
library(VINCI)
library(DBI)
library(pbapply)

rm(list=ls())

setwd("<PATH>")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Read in Llama dysplasia classifier results
llama <- read.csv("./dysplasiaClassifier/results/llama70_results_2025_04_22.csv")
llama <- llama[!is.na(llama$sample_ID),]

# Read in the linked colonoscopy report data
coloReports <- read.csv("../../IBD_dx/colonoscopyReports/linked/results/linked_colo_results_2025_04_23.csv")
coloReports$PathologyReportID <- paste0(coloReports$PathologyReportID)

# Set up variable that is SID and sample ID
llama$sid_and_sample <- paste0(llama$PathologyReportID, "_", llama$sample_ID)
coloReports$sid_and_sample <- paste0(coloReports$PathologyReportID, "_", coloReports$sample_ID)
llama$PathologyReportID <- paste0(llama$PathologyReportID)

# Merge on SurgPathSID and sample ID
llamaMerged <- merge(llama, coloReports, by = "sid_and_sample", all.x=T, suffixes = c(".path", ".linked"))

# Read in the "all" colonoscopy report data
coloAll <- read.csv("../../IBD_dx/colonoscopyReports/pos/results/mistral_results_2025_04_22.csv")
colnames(coloAll) <- paste0(colnames(coloAll), ".unlinked")

# For every path finding, add general colonoscopy details
uniqSID <- unique(llamaMerged$PathologyReportID.path)
linked_list <- pblapply(uniqSID, function(x){
  # Get affected path df
  tmpPath <- llamaMerged[llamaMerged$PathologyReportID.path==x,]
  
  # get PatientID and procedure date (specimen taken date)
  icn <- tmpPath$PatientID[1]
  specDate <- as.Date(tmpPath$SpecimenTakenDateTime[1])
  
  # Get colo df
  tmpColo <- coloAll[coloAll$PatientID.unlinked == icn,]
  tiuDocSIDs <- gsub(" ", "", unlist(strsplit(tmpPath$NoteID.linked, split=",", fixed=T)))
  
  if(any(tmpColo$NoteID.unlinked %in% tiuDocSIDs)){
    
    chosen.df <- tmpColo[which(tmpColo$NoteID.unlinked %in% tiuDocSIDs),]
    linked_tmp <- tidyr::crossing(tmpPath, chosen.df)
    return(linked_tmp)
    
  } else{
    dateDifferences <- difftime(as.Date(tmpColo$EntryDateTime.unlinked), specDate, "days")
    diffUse <- dateDifferences[dateDifferences >= 0 & dateDifferences < 90]
    
    if(length(diffUse) > 0){
      chosen.df <- tmpColo[which(difftime(as.Date(tmpColo$EntryDateTime.unlinked), specDate, "days") == min(diffUse)),]
      linked_tmp <- tidyr::crossing(tmpPath, chosen.df)
      return(linked_tmp)
    }
  }
})


linked <- as.data.frame(data.table::rbindlist(linked_list))
unlinked1 <- coloAll[!coloAll$NoteID.unlinked %in% linked$NoteID.unlinked,]
unlinked2 <- llamaMerged[!llamaMerged$PathologyReportID.path %in% linked$PathologyReportID.path,]
all <- dplyr::bind_rows(linked, unlinked1, unlinked2)

# Convert min size to cm for all
all$length_min_cm <- all$length_min
all$length_min_cm[which(all$length_units=="mm")] <- all$length_min[which(all$length_units=="mm")]/10

colnames(all)

colsKeep <- c("PathologyReportID.path", "PatientID.unlinked", "PatientID", 
              "NoteID.path", "NoteID.linked",
              "NoteID.unlinked", 
              "SpecimenTakenDateTime", "EntryDateTime",
              "sample_ID.path", "number_of_fragments",               
              "length", "specimen_type", "lesion_type", "number_of_concerning_lesions",
              "indication", "location.path", "shape", "dysplasia_grade",
              "inflammation_severity", "inflammation_type", "T_stage", "N_stage",
              "aggregate_or_single", "length_min_cm", "length_max_cm",                     
              "sample_ID.linked", "size", "location.linked", "morphology",                        
              "completeness_of_resection", "random_bx",          
              "indication.unlinked", "colitis_extent.unlinked",           
              "colitis_severity.unlinked", "landmarks_reached.unlinked",        
              "bowel_prep_quality.unlinked", "random_biopsies_taken.unlinked",    
              "number_of_visible_lesions.unlinked", "max_visible_lesion_size.unlinked"            
)

renamedCols <- c("PathologyReportID", "PatientID.unlinked", "PatientID.path",
                 "NoteID.path", "NoteID.linked",
                 "NoteID.unlinked", 
                 "SpecimenTakenDateTime", "EntryDateTime.path",
                 "sample_ID.path", "number_of_fragments.path",               
                 "length.path", "specimen_type.path", "lesion_type.path", 
                 "number_of_concerning_lesions.path",
                 "indication.path", "location.path", "shape.path", 
                 "dysplasia_grade.path",
                 "inflammation_severity.path", "inflammation_type.path",
                 "T_stage.path", "N_stage.path",
                 "aggregate_or_single.path", "length_min_cm.path", "length_max_cm.path",                     
                 "sample_ID.linked", "size.linked", "location.linked", "morphology.linked",                        
                 "completeness_of_resection.linked", "random_bx.linked",          
                 "indication.unlinked", "colitis_extent.unlinked",           
                 "colitis_severity.unlinked", "landmarks_reached.unlinked",        
                 "bowel_prep_quality.unlinked", "random_biopsies_taken.unlinked",    
                 "number_of_visible_lesions.unlinked", "max_visible_lesion_size.unlinked"            
)

allKeep <- all[,colsKeep]
colnames(allKeep) <- renamedCols

allKeep$NoteID.path <- paste0(allKeep$NoteID.path)
allKeep$NoteID.unlinked <- paste0(allKeep$NoteID.unlinked)

# Some duplication may be present, figure it out later.
allKeep$PatientID <- dplyr::coalesce(allKeep$PatientID.unlinked, allKeep$PatientID.path)
allKeep$PatientID.unlinked <- NULL; allKeep$PatientID.path <- NULL

write.csv(allKeep, "./dysplasiaClassifier/results/results_path_colo_linked_unlinked_2025_04_23.csv", row.names=F)
dbWriteTable(conn, "results_path_colo_linked_unlinked_2025_04_23", allKeep)










