# Function to determine which row(s) is/are LGD
return_only_lgd <- function(df){
  
  lgdBools <- (
      (
        (
          df$lesion_type.path %in% c("dysplasia",
                                   "dysplasia-associated lesion or mass (dalm)",
                                   "low grade dysplasia") &
            df$dysplasia_grade.path %in% c("low grade dysplasia", "dysplasia", "unknown")
        ) | 
          df$lesion_type.path %in% c("adenoma",
                                   "traditional serrated adenoma", "tubular adenoma", 
                                   "tubulovillous adenoma", "villous adenoma")
          | 
            df$dysplasia_grade.path %in% c("dysplasia", "low grade dysplasia")
      )
    & !grepl("(?i)(adenoca|high)", df$lesion_type.path, perl=T)
    & !df$dysplasia_grade.path %in% c("adenocarcinoma", "high grade dysplasia", "indefinite for dysplasia")
    & ! ( df$location.path %in% c("unknown") &
            (df$location.linked %in% c("unknown", "not stated") | is.na(df$location.linked)))
    & ! df$location.linked %in% c("other", "ileum")
    & ! df$location.path %in% ("appendix")
  )
  
  indexLGD <- df[lgdBools,]
  return(indexLGD)
}

ind_binary <- function(df){
  
  df <- df[!is.na(df$lesion_type.path),]
  indBools <- (
        (df$lesion_type.path == "indefinite for dysplasia" |
          df$dysplasia_grade.path == "indefinite for dysplasia")
    & !grepl("(?i)(adenoca|high)", df$lesion_type.path, perl=T)
    & !df$dysplasia_grade.path %in% c("adenocarcinoma", "high grade dysplasia", "low grade dysplasia")
    & ! ( df$location.path %in% c("unknown") &
            (df$location.linked %in% c("unknown", "not stated") | is.na(df$location.linked)))
    & ! df$location.linked %in% c("other", "ileum")
    & ! df$location.path %in% ("appendix")
  )
  
  return(as.numeric(any(indBools, na.rm=T)))
}

# Within historical extent
return_colitis_associated <- function(df, nowOrPast, returnAllLGD=F){
  
  locations_ordered <- c("rectum", "rectosigmoid", "sigmoid", "descending", "splenic flexure",
                         "transverse", "hepatic flexure", "ascending", "cecum", "ileocecal valve")
  
  if(any(is.na(df$sample_ID.path))){
    stop("First input to 'return_colitis_associated' fn must not have NA entries for path variables")
  }
  
  # Find the location of the lgd and the max known extent of the colitis.
  # Convert both to numeric for comparison of whether LGD is "within" colitis extent
  max_extent <- 0
  df$lgdLoc <- rep(NA, nrow(df))
  location <- sapply(df$location.path, convert_location)
  location[is.na(location)] <- df$location.linked[is.na(location)]
  location[is.na(location)] <- "unknown"
  for(k in 1:length(locations_ordered)){
    if(grepl(paste0("\\b", locations_ordered[k], "\\b"), 
             paste0(nowOrPast$colitis_extent.unlinked, collapse=" "), perl=T)){
      max_extent <- k
    }
    for(l in 1:nrow(df)){
      if(locations_ordered[k] == location[l]){
        df$lgdLoc[l] <- k
      }
    }
  }
  
  # See if the LGD is within the colitis extent.
  path_infl_bools <- !df$inflammation_severity.path %in% c("unknown", "none")
  
  if(any(path_infl_bools)){
    # Adjust max_extent based on the path inflammation
    max_extent <- max(c(which(locations_ordered %in% location[path_infl_bools]), 
                        max_extent), na.rm=T)
  }
  
  # Identify index LGD(s)
  if(returnAllLGD){
    indexLGD <- df
  }else{
    indexLGD <- df[which(df$lgdLoc <= max_extent),]
  }
  return(list(indexLGD, max_extent))
}

# Making changes to reflect Shailja's comments: quiescent and not stated are diff.
get_endo <- function(df){
  infl_ordered <- c("none", "mild", "moderate", "severe")
  
  mod_sev <- as.numeric(any(df$colitis_severity.unlinked %in% c("moderate", "severe"), na.rm=T))
  if(mod_sev == 0 & all(is.na(df$colitis_severity.unlinked))){
    stop("All unlinked are NA")
  }
  
  max_endo <- "not stated"
  if(any(infl_ordered %in% df$colitis_severity.unlinked)){
    max_endo <- tail(infl_ordered[infl_ordered %in% df$colitis_severity.unlinked], 1)
  }
  
  return(list(mod_sev, max_endo))
}

targeted_completeness <- function(df, completeness){
  
  unique_sampleIDs <- unique(paste0(df$SurgicalPathologySID, "_", df$sample_ID.path))
  targetedCompleteness_vec <- c()
  for(sid_sample in unique_sampleIDs){
    targetedCompleteness_vec <- c(targetedCompleteness_vec, 
                                  completeness$answer_27B[grepl(sid_sample, completeness$combinedID, 
                                                                fixed=T)])
  }
  
  return(targetedCompleteness_vec)
}


endo_nextFive <- function(df){
  infl_ordered <- c("none", "mild", "moderate", "severe")
  
  max_endo <- "not stated"
  if(any(infl_ordered %in% df$colitis_severity.unlinked)){
    max_endo <- tail(infl_ordered[infl_ordered %in% df$colitis_severity.unlinked], 1)
  }else if(nrow(df)==0){
    max_endo <- "missing. No VA reports."
  }
  
  return(max_endo)
}


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

get_metachronous_lgd <- function(future_path, advNeoDate, colectomyDate, indexOnly, allPt, VA_colo_dates){
  
  event_censor_date <- suppressWarnings(min(c(as.Date(advNeoDate, format = "%Y-%m-%d"),
                                         as.Date(colectomyDate, format = "%Y-%m-%d")), na.rm=T))
  
  relevant_path <- future_path[as.Date(future_path$SpecimenTakenDateTime, format = "%Y-%m-%d") < event_censor_date,]
  
  colo_dates_afterIndex_beforeCensor <- VA_colo_dates[
    which(VA_colo_dates <= event_censor_date &
            VA_colo_dates > (as.Date(indexOnly$SpecimenTakenDateTime[1]) + 30))
  ]
  
  if(nrow(relevant_path) == 0 & length(colo_dates_afterIndex_beforeCensor) == 0){
    return("No documented VA colonoscopy before HGD/CRC or censor")
  }
  
  future_lgdAll <- return_only_lgd(relevant_path)
  if(nrow(future_lgdAll)==0){
    return("no metachronous LGD before event/censor")
  }
  
  unique_dates <- unique(future_lgdAll$SpecimenTakenDateTime)
  
  # Get previous colonoscopy reports to determine if colitis-associated
  for(i in 1:length(unique_dates)){
    time_diff_colo <- as.numeric(difftime(as.Date(allPt$EntryDateTime.unlinked), as.Date(unique_dates[i]), 
                                          units="days")/365.25)
    time_diff_path <- as.numeric(difftime(as.Date(allPt$SpecimenTakenDateTime), as.Date(unique_dates[i]), 
                                          units="days")/365.25)
    metachOrPast <- allPt[which(time_diff_colo <= 30/365.25 | time_diff_path <= 0),]
    
    future_lgd <- return_colitis_associated(future_lgdAll[future_lgdAll$SpecimenTakenDateTime==unique_dates[i],],
                                            metachOrPast)[[1]]
    if(nrow(future_lgd)==0){
      next
    }
    future_loc <- sapply(future_lgd$location.path, convert_location)
    index_loc <- sapply(indexOnly$location.path, convert_location)
    if (any(future_loc %in% index_loc)){
      return("metachronous LGD in same segment")
    }else{
      return("metachronous LGD in different segment")
    }
  }
  return("no metachronous LGD before event/censor")
}


convert_sizes <- function(x){
  cm <- grepl("cm", x)
  digits <- suppressWarnings(as.numeric(stringr::str_extract_all(x, "\\d+\\.?\\d*")))
  if(!cm & !is.na(digits)){
    return(unlist(digits)/10)
  }else{
    return(unlist(digits))
  }
}

get_sizes <- function(df){
  sizes <- suppressWarnings(sapply(df$size.linked, convert_sizes))
  sizes[is.na(sizes)] <- suppressWarnings(as.numeric(df$length_max_cm.path[is.na(sizes)]))
  sizes[is.na(sizes)] <- suppressWarnings(sapply(df$max_visible_lesion_size.unlinked[is.na(sizes)], convert_sizes))
  
  if(all(is.na(sizes))){
    large <- NA
  } else if(any(is.na(sizes))){
    large <- NA
    if(any(sizes >= 1, na.rm=T)){
      large <- 1
    }
  }else{
    large <- as.numeric(any(sizes >= 1, na.rm=T))
  }
  return(list(large, sizes))
}

get_spec_type <- function(df){
  if(any(df$specimen_type.path == "endoscopic submucosal dissection (ESD)")){
    spec_type <- "ESD"
  }else if(any(df$specimen_type.path == "endoscopic mucosal resection (EMR)")){
    spec_type <- "EMR"
  } else if(any(df$specimen_type.path == "surgical resection")){
    spec_type <- "surgical resection"
  } else{
    spec_type <- "polypectomy/biopsy"
  }
  return(spec_type)
}


# Function to remove unknowns (NA), and score
remove_unknowns_score <- function(x, colsUCCARE){
  
  keepRows <- 1:nrow(x)
  for(col in colsUCCARE){
    keepRows <- setdiff(keepRows, which(is.na(x[,col])))
  }
  x <- x[keepRows,]
  x$score <- rowSums(x[,colsUCCARE], na.rm=F)
  stopifnot(!any(is.na(x$score)))
  return(x)
}

# For plotting
theme_large_text <- function(){theme(axis.title = element_text(size=16),
                                     axis.text=element_text(size=14),
                                     legend.text = element_text(size = 14),
                                     legend.title = element_blank())}



# Get binary risk groups and order by number of risk factors
get_binary_risk_groups <- function(data, 
                            colNames=c("large", "incomplete_or_invisible", "multifocal", "endo_moderate_severe")
                            ){
  
  binary.df <- data[,colNames]
  uniq_binary.df <- unique(binary.df)
  
  data$binary_coding_UCCaRE <- NA
  for(i in 1:nrow(data)){
    data$binary_coding_UCCaRE[i] <- paste0(binary.df[i,], collapse = "")
  }
  data$binary_coding_UCCaRE <- factor(data$binary_coding_UCCaRE)
  levels = c("0000", "0001", "0010", 
             "0100", "1000", "0011", 
             "0101", "1001", "0110",
             "1010", "1100", "0111", 
             "1011", "1101", "1110", 
             "1111")
  labelsRaw <- c("large", "incomplete/invisible", "multifocal", "endo. infl.")
  labels <- c()
  for(level in levels){
    labels <- c(labels, paste0(labelsRaw[which(as.numeric(unlist(strsplit(level, split = "")))==1)], collapse = " and "))
  }
  labels[1] <- "none"; labels[16] <- "all"
  data$binary_coding_UCCaRE <- factor(data$binary_coding_UCCaRE, levels = levels,
                                      labels = labels)
  return(data$binary_coding_UCCaRE)
}


# Function to determine if any of the index LGD are invisible
any_is_invisible <- function(df){
  
  # See if "any_invisible" (random bx)
  invisible_vec <- any(df$random_biopsies_taken.unlinked == "yes", na.rm=T) &
    ( df$random_bx.linked == "yes" | 
      df$indication.path == "random biopsy" |
        (
          (df$random_bx.linked == "unknown" |
            df$indication.path == "surveillance biopsy")
          & df$morphology.linked == "invisible"
        ) 
    )
  return(as.numeric(any(invisible_vec)))
}


is_multifocal <- function(df){
  any_invisible <- any_is_invisible(df)
  if(any_invisible == 1){
    return(as.numeric(length(unique(df$sample_ID.path)) > 1 |
                        length(unique(df$location.path)) > 1))
  }else {
    return(as.numeric(length(unique(df$sample_ID.path)) > 1 |
                        length(unique(df$location.path)) > 1 |
                        any(!df$number_of_concerning_lesions.path %in% c("0", "1"))))
  }
}

# Categorize morphology in descending risk: non-polypoid, invisible, poylpoid
get_morphology <- function(df){
  any_invisible <- any_is_invisible(df)
  
  # Use colonoscopy report if available
  if(any(df$morphology.linked %in% c("depressed", "flat", "flat depressed", "flat elevated",
                                     "laterally spreading", "ulcerated"))){
    index_morphology <- "non-polypoid"
  }else if(any_invisible == 1){
    index_morphology <- "invisible"
  }else if(any(df$morphology.linked %in% c("sessile", "pedunculated", "pseudopolyp"))){
    index_morphology <- "polypoid"
  }else{
    
    # Use path shape/indication
    if(any(df$shape.path %in% c("flat", "flat depressed", "flat elevated", "nonpolypoid")) |
       any(df$indication.path %in% c("visible dysplasia", "ulceration", "thickened folds",
                                     "abnormal mucosa", "erosions"))){
      index_morphology <- "non-polypoid"
    }else if (any(df$shape.path %in% c("pedunculated", "polypoid", "sessile"))  |
              any(df$indication.path %in% c("polyp", "mass", "nodularity"))){
      index_morphology <- "polypoid"
    }else{
      index_morphology <- "unknown"
    }
    
  }

  return(index_morphology)
}


# Function to collapse dates less than N days apart
collapse_dates <- function(dates, window_days, keepers=NULL, returnAllKeepers = TRUE){
  
  # Possibly simplify function to remove option to have removeAllKeepers = FALSE
  
  dates <- as.Date(sort(unique(as.Date(dates[!is.na(dates)]))))
  keepers <- as.Date(sort(unique(as.Date(keepers[!is.na(keepers)]))))
  
  if(!all(keepers %in% dates)){
    warning("Keeper dates need to be in the dates vector to ensure proper functionality!")
  }
  if(length(dates)==0){return(as.Date(character()))}
  
  out_dates <- c()
  current_group <- c(dates[1])
  
  if(length(dates) > 1){
    for(i in 2:length(dates)){
      if(as.numeric(dates[i] - current_group[1]) <= window_days){
        current_group <- c(current_group, dates[i])
        
        # Compare with the latest keeper (if present) in each group. Otherwise, compare to first date of the group
        if(any(keepers %in% current_group) & returnAllKeepers){
          current_group <- unique(c(sort(keepers[keepers %in% current_group], decreasing=TRUE), current_group))
        }
        
      }else{
        selected <- keepers[keepers %in% current_group]
        
        if(length(selected) > 0){
          out_dates <- c(out_dates, sort(selected)[1])
        }else{
          out_dates <- c(out_dates, sort(current_group)[1])
        }
        current_group <- c(dates[i])
      }
    }
  }
  
  selected <- keepers[keepers %in% current_group]
  if(returnAllKeepers){
    if(length(selected) > 0){
      return(unique(c(as.Date(out_dates), keepers)))
    }else{
      return(unique(c(as.Date(out_dates), sort(current_group)[1], keepers)))
    }
  }else{
    if(length(selected) > 0){
      return(unique(c(as.Date(out_dates), sort(selected)[1])))
    }else{
      return(unique(c(as.Date(out_dates), sort(current_group)[1])))
    }
  }
}
