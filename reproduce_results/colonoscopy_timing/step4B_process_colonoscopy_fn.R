process_colonoscopy <- function(llamaRaw){
  
  # Need to account for multiple months
  llama <- lapply(llamaRaw, function(x){
    split_x <- unlist(strsplit(x, split = "\\n", fixed=T))
    id <- unlist(strsplit(x, split = "\t", fixed=T))[2]
    yn <- !grepl("No documented colonoscopy", x, fixed = T)
    outMonths <- c(); outYears <- c(); outSites <- c()
    ids <- c(); yns <- c()
    if(!grepl("No documented colonoscopy", x, fixed = T)){
      
      for(i in 1:length(split_x)){
        
        # Month
        month <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = ". Month: ", fixed=T))[2], 
          split = ". Site", fixed = T))[1]
        outMonths <- c(outMonths, month)
        
        # Year
        year <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = "Colonoscopy year: ", fixed=T))[2], 
          split = ". Month:", fixed = T))[1]
        outYears <- c(outYears, year)
        
        # Site 
        site <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = "Site: ", fixed=T))[2], 
          split = ".", fixed = T))[1]
        outSites <- c(outSites, site)
        
        ids <- c(ids, id)
        yns <- c(yns, yn)
      }
    }else{return(data.frame("PatientID" = id, "ColonoscopyYN" = yn,
                            "Site" = NA, "Month" = NA,
                            "Year" = NA))}

    return(data.frame("PatientID" = ids, "ColonoscopyYN" = yn,
                      "Site" = outSites, "Month" = outMonths,
                      "Year" = outYears))
  })
  
  out <- do.call(rbind, llama)
  return(out)

}
