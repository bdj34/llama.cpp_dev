
# Function to convert location in cm to anatomical location
convert_location <- function(x){
  digits <- suppressWarnings(as.numeric(stringr::str_extract_all(x, "\\d+")))
  if(is.na(digits)){
    return(x)
  } else if(digits <= 15){
    return("rectum")
  } else if(digits <= 40){
    return("sigmoid")
  } else if (digits <= 60){
    return("descending")
  } else if (digits <= 80){
    return("splenic flexure")
  }else if (digits < 100){
    return("transverse")
  }
}

# Get hgd/crc location(s) for a single patient. Called by get_hgd_crc() fn.
get_hgd_crc_location <- function(df, icd.df){
  
  DxDate <- suppressWarnings(min(as.Date(df$aggregate_hgd_crc_dx_date), na.rm=T))
  
  if(DxDate == Inf){
    return(list("unknown", "NA"))
  }
  
  # Otherwise, take all structured data from within 30 days of diagnosis:
  # sort by Onc Domain, Path report, then ICD
  # Concatenate locations from onc domain and path report, fixing formatting discrepancies
  # Use ICD only when other sources are unavailable
  path_within30 <- df[abs(difftime(as.Date(df$hgd_crc_dx_date_PATH), DxDate, units = "days")) < 30,]
  onc_within30 <- df[abs(difftime(as.Date(df$oncDomain_hgd_crc_dx_date), DxDate, units = "days")) < 30,]
  icd_within30 <- icd.df[abs(difftime(as.Date(icd.df$DxDate), DxDate, units = "days")) < 30,]
  
  oncDomain_unique <- unique(onc_within30$oncDomain_PrimarysiteX)
  path_unique <- unique(path_within30$hgd_crc_location_PATH)
  location_src <- "unknown"
  if(!all(is.na(oncDomain_unique) | oncDomain_unique %in% c("COLON NOS", "COLON OVERLAP"))){
    locationRaw <- oncDomain_unique[!is.na(oncDomain_unique)]
    location_src <- "oncDomain"
  }else if (!all(is.na(path_unique))){
    locationRaw <- sapply(path_unique[!is.na(path_unique)], convert_location)
    location_src <- "path"
  } else if(!all(is.na(oncDomain_unique))){
    locationRaw <- oncDomain_unique[!is.na(oncDomain_unique)]
    location_src <- "oncDomain"
  } else{
    locationRaw <- icd_within30$ICDCode
    location_src <- "ICD"
  }
  
  
  # Get location of the HGD/CRC
  locations <- c("cecum", "ascending", "hepatic flexure", "transverse", "splenic flexure",
                 "descending", "sigmoid", "rectosigmoid", "rectum", "colon (NOS)")
  regex <- paste0("(?i)", c("(cecum|ileocecal|C18\\.0|153\\.4)", "(ascending|C18\\.2|153\\.6)", 
                            "(hepatic|C18\\.3|153\\.0)", "(transverse|C18\\.4|153\\.1)", 
                            "(splenic|C18\\.5|153\\.7)", "(descending|C18\\.6|153\\.2)", 
                            "(\\bsigmoid|C18\\.7|153\\.3)", "(rectosigmoid|C19|154\\.0)", 
                            "(rectum|C20|154\\.1)", "(NOS|C18\\.8|C18\\.9|153\\.8|153\\.9)"))
  
  matched.df <- data.frame("location" = locations, "regex" = regex)
  location_vec <- c()
  for(i in 1:nrow(matched.df)){
    if(any(grepl(matched.df$regex[i], locationRaw, perl=T))){
      location_vec <- c(location_vec, matched.df$location[i])
    }
  }
  if(length(location_vec)==0){
    location_vec <- "unknown"
  }else if(length(location_vec) > 1){
    location_vec <- location_vec[location_vec != "colon (NOS)"]
  }
  
  return(list(paste0(location_vec, collapse = ", "), location_src))
}


# Input df must only be those individuals we phenotyped to have HGD/CRC
get_hgd_crc <- function(df, colectomy, icd.df){
  uniqPts <- unique(df$PatientID)
  hgd_crc <- data.frame()
  
  for(id in uniqPts){
    tmpDup <- df[df$PatientID==id,]
    # Get first date of diagnosis only
    tmp <- tmpDup[order(tmpDup$aggregate_hgd_crc_dx_date)[1],]
    tmpCol <- colectomy[colectomy$PatientID==id,]
    
    location_info <- get_hgd_crc_location(tmpDup, icd.df[icd.df$PatientID==id,])
    
    # If date is unknown, make a note of that
    if(all(is.na(tmp$aggregate_hgd_crc_dx_date))){
      
      hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                           "first_hgd_crc_dx_date" = as.Date(NA),
                                           "first_structured_hgd_crc" = as.Date(NA),
                                           "first_llm_freeTxt_hgd_crc" = as.Date(NA),
                                           "note" = "Needs manual review",
                                           "date_source" = "NA",
                                           "location" = location_info[[1]], 
                                           "location_source" = location_info[[2]]))
      
    } else{ 
      
      firstCol <- tmpCol[order(tmpCol$colectomyDate_llm_cpt)[1],]
      colectomy_source <- firstCol$colectomySource
      
      # Get date differences and other data on dates
      dateDiff <- abs(difftime(tmp$aggregate_hgd_crc_dx_date, tmpCol$colectomyDate_llm_cpt, units = "days"))
      col_before_crc <- tmp$aggregate_hgd_crc_dx_date > tmpCol$colectomyDate_llm_cpt
      hgd_crc_yr <- min(as.numeric(format(as.Date(tmp$aggregate_hgd_crc_dx_date), "%Y")))
      col_yr <- min(as.numeric(format(as.Date(firstCol$colectomyDate_llm_cpt), "%Y")))
      crcMonthKnown <- tmp$month_crcLLMFree %in% month.name
      colMonthKnown <- tmpCol$llm_Month %in% month.name
      
      # Determine source of CRC date and colectomy date (LLM vs. structured)
      if(tmp$aggregate_hgd_crc_dx_date==tmp$dx_date_crcLLMFree &
         (tmp$aggregate_hgd_crc_dx_date!=tmp$hgd_crc_dx_date_PATH | is.na(tmp$hgd_crc_dx_date_PATH)) &
         (tmp$aggregate_hgd_crc_dx_date!=tmp$oncDomain_hgd_crc_dx_date | is.na(tmp$oncDomain_hgd_crc_dx_date)) &
         (tmp$aggregate_hgd_crc_dx_date!=tmp$first_hgd_crc_ICD_date | is.na(tmp$first_hgd_crc_ICD_date))){
        hgd_crc_source <- "LLMs"
      }else{hgd_crc_source <- "structured"}
      first_struct <- pmin(tmp$hgd_crc_dx_date_PATH, tmp$oncDomain_hgd_crc_dx_date,
                           tmp$first_hgd_crc_ICD_date, na.rm=T)
      first_llm <- tmp$dx_date_crcLLMFree
      
      if(nrow(tmpCol) == 0){
        hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                             "first_hgd_crc_dx_date" = as.Date(tmp$aggregate_hgd_crc_dx_date),
                                             "first_structured_hgd_crc" = as.Date(first_struct),
                                             "first_llm_freeTxt_hgd_crc" = as.Date(first_llm),
                                             "note" = "No colectomy",
                                             "date_source" = hgd_crc_source,
                                             "location" = location_info[[1]], 
                                             "location_source" = location_info[[2]]))
        next
      }
      
      # Replace HGD/CRC date with colectomy date in certain situations
      if(!col_before_crc){
        
        hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                             "first_hgd_crc_dx_date" = as.Date(tmp$aggregate_hgd_crc_dx_date),
                                             "first_structured_hgd_crc" = as.Date(first_struct),
                                             "first_llm_freeTxt_hgd_crc" = as.Date(first_llm),
                                             "note" = "Colectomy after HGD/CRC", 
                                             "date_source" = hgd_crc_source, 
                                             "location" = location_info[[1]], 
                                             "location_source" = location_info[[2]]))
        
      }else if(((hgd_crc_source == "LLMs" & colectomy_source == "LLMs") |
                (hgd_crc_source == "LLMs" & !crcMonthKnown) |
                (colectomy_source == "LLMs" & !colMonthKnown))
               & col_yr == hgd_crc_yr){
        
        hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                             "first_hgd_crc_dx_date" = as.Date(firstCol$colectomyDate_llm_cpt),
                                             "first_structured_hgd_crc" = as.Date(first_struct),
                                             "first_llm_freeTxt_hgd_crc" = as.Date(first_llm),
                                             "note" = "Modified so HGD/CRC is now at colectomy (same year)",
                                             "date_source" = hgd_crc_source, 
                                             "location" = location_info[[1]], 
                                             "location_source" = location_info[[2]]))
        
      } else if(((hgd_crc_source == "LLMs" & crcMonthKnown) |
                 (colectomy_source == "LLMs" & colMonthKnown))
                & dateDiff <= 90){
        
        hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                             "first_hgd_crc_dx_date" = as.Date(firstCol$colectomyDate_llm_cpt),
                                             "first_structured_hgd_crc" = as.Date(first_struct),
                                             "first_llm_freeTxt_hgd_crc" = as.Date(first_llm),
                                             "note" = "Modified so HGD/CRC is now at colectomy (LLMS, <=90 days)",
                                             "date_source" = hgd_crc_source, 
                                             "location" = location_info[[1]], 
                                             "location_source" = location_info[[2]]))
        
        
      } else if(hgd_crc_source == "structured" & colectomy_source == "CPT"
                & dateDiff <= 60){
        
        hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                             "first_hgd_crc_dx_date" = as.Date(firstCol$colectomyDate_llm_cpt),
                                             "first_structured_hgd_crc" = as.Date(first_struct),
                                             "first_llm_freeTxt_hgd_crc" = as.Date(first_llm),
                                             "note" = "Modified so HGD/CRC is now at colectomy (<=60 days)",
                                             "date_source" = hgd_crc_source, 
                                             "location" = location_info[[1]], 
                                             "location_source" = location_info[[2]]))
        
      } else{
        
        hgd_crc <- rbind(hgd_crc, data.frame("PatientID" = id, 
                                             "first_hgd_crc_dx_date" = as.Date(tmp$aggregate_hgd_crc_dx_date),
                                             "first_structured_hgd_crc" = as.Date(first_struct),
                                             "first_llm_freeTxt_hgd_crc" = as.Date(first_llm),
                                             "note" = "Colectomy but no HGD/CRC date change",
                                             "date_source" = hgd_crc_source, 
                                             "location" = location_info[[1]], 
                                             "location_source" = location_info[[2]]))
        
      }
    }
  }
  hgd_crc <- hgd_crc[!is.na(hgd_crc$PatientID),]
  return(hgd_crc)
}

# Get crc location(s) for a single patient. Called by get_crc() fn.
get_crc_location <- function(df, icd.df){
  
  DxDate <- suppressWarnings(min(as.Date(df$aggregate_crc_dx_date), na.rm=T))
  
  if(DxDate == Inf){
    return(list("unknown", "NA"))
  }
  
  # Otherwise, take all structured data from within 30 days of diagnosis:
  # sort by Onc Domain, Path report, then ICD
  # Concatenate locations from onc domain and path report, fixing formatting discrepancies
  # Use ICD only when other sources are unavailable
  path_within30 <- df[abs(difftime(as.Date(df$crc_dx_date_PATH), DxDate, units = "days")) < 30,]
  onc_within30 <- df[abs(difftime(as.Date(df$oncDomain_crc_dx_date), DxDate, units = "days")) < 30,]
  icd_within30 <- icd.df[abs(difftime(as.Date(icd.df$DxDate), DxDate, units = "days")) < 30,]
  
  oncDomain_unique <- unique(onc_within30$oncDomain_PrimarysiteX)
  path_unique <- unique(path_within30$crc_location_PATH)
  location_src <- "unknown"
  if(!all(is.na(oncDomain_unique) | oncDomain_unique %in% c("COLON NOS", "COLON OVERLAP"))){
    locationRaw <- oncDomain_unique[!is.na(oncDomain_unique)]
    location_src <- "oncDomain"
  }else if (!all(is.na(path_unique))){
    locationRaw <- sapply(path_unique[!is.na(path_unique)], convert_location)
    location_src <- "path"
  }else if(!all(is.na(oncDomain_unique))){
    locationRaw <- oncDomain_unique[!is.na(oncDomain_unique)]
    location_src <- "oncDomain"
  } else{
    locationRaw <- icd_within30$ICDCode
    location_src <- "ICD"
  }
  
  
  # Get location of the CRC
  locations <- c("cecum", "ascending", "hepatic flexure", "transverse", "splenic flexure",
                 "descending", "sigmoid", "rectosigmoid", "rectum", "colon (NOS)")
  regex <- paste0("(?i)", c("(cecum|ileocecal|C18\\.0|153\\.4)", "(ascending|C18\\.2|153\\.6)", 
                            "(hepatic|C18\\.3|153\\.0)", "(transverse|C18\\.4|153\\.1)", 
                            "(splenic|C18\\.5|153\\.7)", "(descending|C18\\.6|153\\.2)", 
                            "(\\bsigmoid|C18\\.7|153\\.3)", "(rectosigmoid|C19|154\\.0)", 
                            "(rectum|C20|154\\.1)", "(NOS|C18\\.8|C18\\.9|153\\.8|153\\.9)"))
  
  matched.df <- data.frame("location" = locations, "regex" = regex)
  location_vec <- c()
  for(i in 1:nrow(matched.df)){
    if(any(grepl(matched.df$regex[i], locationRaw, perl=T))){
      location_vec <- c(location_vec, matched.df$location[i])
    }
  }
  if(length(location_vec)==0){
    location_vec <- "unknown"
  }else if(length(location_vec) > 1){
    location_vec <- location_vec[location_vec != "colon (NOS)"]
  }
  
  return(list(paste0(location_vec, collapse = ", "), location_src))
}

get_crc <- function(df, colectomy, icd.df){
  uniqPts <- unique(df$PatientID)
  crc <- data.frame()
  
  for(id in uniqPts){
    tmpDup <- df[df$PatientID==id,]
    tmp <- tmpDup[order(tmpDup$aggregate_crc_dx_date)[1],]
    tmpCol <- colectomy[colectomy$PatientID==id,]
    
    location_info <- get_crc_location(tmpDup, icd.df[icd.df$PatientID==id,])
    
    # If date is unknown, make a note of that
    if(all(is.na(tmp$aggregate_crc_dx_date))){
      
      crc <- rbind(crc, data.frame("PatientID" = id, 
                                   "first_crc_dx_date" = as.Date(NA),
                                   "first_structured_crc" = as.Date(NA),
                                   "first_llm_freeTxt_crc" = as.Date(NA),
                                   "note" = "Needs manual review",
                                   "date_source" = "NA",
                                   "location" = location_info[[1]], 
                                   "location_source" = location_info[[2]]))
      
    } else{ 
      
      firstCol <- tmpCol[order(tmpCol$colectomyDate_llm_cpt)[1],]
      colectomy_source <- firstCol$colectomySource
      
      # Get date differences and other data on dates
      dateDiff <- abs(difftime(tmp$aggregate_crc_dx_date, tmpCol$colectomyDate_llm_cpt, units = "days"))
      col_before_crc <- tmp$aggregate_crc_dx_date > tmpCol$colectomyDate_llm_cpt
      crc_yr <- min(as.numeric(format(as.Date(tmp$aggregate_crc_dx_date), "%Y")))
      col_yr <- min(as.numeric(format(as.Date(firstCol$colectomyDate_llm_cpt), "%Y")))
      crcMonthKnown <- tmp$month_crcLLMFree %in% month.name
      colMonthKnown <- tmpCol$llm_Month %in% month.name
      
      # Determine source of CRC date and colectomy date (LLM vs. structured)
      if(tmp$aggregate_crc_dx_date==tmp$dx_date_crcLLMFree &
         (tmp$aggregate_crc_dx_date!=tmp$crc_dx_date_PATH | is.na(tmp$crc_dx_date_PATH)) &
         (tmp$aggregate_crc_dx_date!=tmp$oncDomain_crc_dx_date | is.na(tmp$oncDomain_crc_dx_date)) &
         (tmp$aggregate_crc_dx_date!=tmp$first_crc_ICD_date | is.na(tmp$first_crc_ICD_date))){
        crc_source <- "LLMs"
      }else{crc_source <- "structured"}
      first_struct <- pmin(tmp$crc_dx_date_PATH, tmp$oncDomain_crc_dx_date,
                           tmp$first_crc_ICD_date, na.rm=T)
      first_llm <- tmp$dx_date_crcLLMFree
      
      if(nrow(tmpCol) == 0){
        crc <- rbind(crc, data.frame("PatientID" = id, 
                                     "first_crc_dx_date" = as.Date(tmp$aggregate_crc_dx_date),
                                     "first_structured_crc" = as.Date(first_struct),
                                     "first_llm_freeTxt_crc" = as.Date(first_llm),
                                     "note" = "No colectomy",
                                     "date_source" = crc_source, 
                                     "location" = location_info[[1]], 
                                     "location_source" = location_info[[2]]))
        next
      }
      
      # Replace CRC date with colectomy date in certain situations
      if(!col_before_crc){
        
        crc <- rbind(crc, data.frame("PatientID" = id, 
                                     "first_crc_dx_date" = as.Date(tmp$aggregate_crc_dx_date),
                                     "first_structured_crc" = as.Date(first_struct),
                                     "first_llm_freeTxt_crc" = as.Date(first_llm),
                                     "note" = "Colectomy after CRC", 
                                     "date_source" = crc_source, 
                                     "location" = location_info[[1]], 
                                     "location_source" = location_info[[2]]))
        
      }else if(((crc_source == "LLMs" & colectomy_source == "LLMs") |
                (crc_source == "LLMs" & !crcMonthKnown) |
                (colectomy_source == "LLMs" & !colMonthKnown))
               & col_yr == crc_yr){
        
        crc <- rbind(crc, data.frame("PatientID" = id, 
                                     "first_crc_dx_date" = as.Date(firstCol$colectomyDate_llm_cpt),
                                     "first_structured_crc" = as.Date(first_struct),
                                     "first_llm_freeTxt_crc" = as.Date(first_llm),
                                     "note" = "Modified so CRC is now at colectomy (same year)",
                                     "date_source" = crc_source, 
                                     "location" = location_info[[1]],
                                     "location_source" = location_info[[2]]))
        
      } else if(((crc_source == "LLMs" & crcMonthKnown) |
                 (colectomy_source == "LLMs" & colMonthKnown))
                & dateDiff <= 90){
        
        crc <- rbind(crc, data.frame("PatientID" = id, 
                                     "first_crc_dx_date" = as.Date(firstCol$colectomyDate_llm_cpt),
                                     "first_structured_crc" = as.Date(first_struct),
                                     "first_llm_freeTxt_crc" = as.Date(first_llm),
                                     "note" = "Modified so CRC is now at colectomy (LLMS, <=90 days)",
                                     "date_source" = crc_source, 
                                     "location" = location_info[[1]], 
                                     "location_source" = location_info[[2]]))
        
        
      } else if(crc_source == "structured" & colectomy_source == "CPT"
                & dateDiff <= 60){
        
        crc <- rbind(crc, data.frame("PatientID" = id, 
                                     "first_crc_dx_date" = as.Date(firstCol$colectomyDate_llm_cpt),
                                     "first_structured_crc" = as.Date(first_struct),
                                     "first_llm_freeTxt_crc" = as.Date(first_llm),
                                     "note" = "Modified so CRC is now at colectomy (<=60 days)",
                                     "date_source" = crc_source, 
                                     "location" = location_info[[1]], 
                                     "location_source" = location_info[[2]]))
        
      } else{
        
        crc <- rbind(crc, data.frame("PatientID" = id, 
                                     "first_crc_dx_date" = as.Date(tmp$aggregate_crc_dx_date),
                                     "first_structured_crc" = as.Date(first_struct),
                                     "first_llm_freeTxt_crc" = as.Date(first_llm),
                                     "note" = "Colectomy but no CRC date change",
                                     "date_source" = crc_source, 
                                     "location" = location_info[[1]], 
                                     "location_source" = location_info[[2]]))
        
      }
    }
  }
  crc <- crc[!is.na(crc$PatientID),]
  return(crc)
}
