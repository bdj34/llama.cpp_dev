locations_ordered <- c("rectum",  "rectosigmoid", "sigmoid", "descending", 
                       "splenic flexure", "transverse", "hepatic flexure", 
                       "ascending", "cecum")
locations_regex <- paste0("(?i)", c("rectum", "rectosigmoid", "\\bsigmoid", "descending",
                                    "splenic", "transverse", "hepatic", 
                                    "ascending", "cecum|ileocecal"))
									
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
  if(nrow(indexLGD) > 0){
    indexLGD$lgdLoc <- rep(NA, nrow(indexLGD))
    location <- sapply(indexLGD$location.path, convert_location)
    location[is.na(location)] <- indexLGD$location.linked[is.na(location)]
    location[is.na(location)] <- "unknown"
    
    for(k in 1:length(locations_ordered)){
      
      # Get LGD locations from current path reports
      if(nrow(indexLGD)>0){
        for(l in 1:nrow(indexLGD)){
          if(grepl(locations_regex[k], location[l], perl=T)){
            indexLGD$lgdLoc[l] <- k
          }
        }
      }
    }
  }
  
  return(indexLGD)
}

# Function to determine if any of the index LGD are invisible
invisible_bools <- function(df){
  
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
  return(invisible_vec)
}


