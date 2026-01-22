process_colectomy <- function(llamaRaw){
  llamaYN <- sapply(llamaRaw, function(x){
    unlist(strsplit(
      unlist(strsplit(x, split = "Answer: ", fixed=T))[2], 
      split = ".", fixed = T))[1]
  })
  llamaID <- sapply(llamaRaw, function(x){
    unlist(strsplit(x, split = "\t", fixed=T))[2]
  })
  
  # Need to account for multiple months
  llamaMonth <- sapply(llamaRaw, function(x){
    split_x <- unlist(strsplit(x, split = "\\n", fixed=T))
    outMonths <- c()
    if(length(split_x) > 1){
      for(i in 2:length(split_x)){
        month <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = ". Procedure month: ", fixed=T))[2], 
          split = ". Procedure", fixed = T))[1]
        outMonths <- c(outMonths, month)
      }
    }else{outMonths <- c(NA)}
    return(outMonths[!is.na(outMonths)])
  })
  
  llamaYear <- sapply(llamaRaw, function(x){
    split_x <- unlist(strsplit(x, split = "\\n", fixed=T))
    outYears <- c()
    if(length(split_x) > 1){
      for(i in 2:length(split_x)){
        year <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = ". Procedure year: ", fixed=T))[2], 
          split = ".", fixed = T))[1]
        outYears <- c(outYears, year)
      }
    }else{outYears <- c(NA)}
    return(outYears[!is.na(outYears)])
  })
  
  llamaProc <- sapply(llamaRaw, function(x){
    split_x <- unlist(strsplit(x, split = "\\n", fixed=T))
    outYears <- c()
    if(length(split_x) > 1){
      for(i in 2:length(split_x)){
        year <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = "Procedure type: ", fixed=T))[2], 
          split = ". Segments", fixed = T))[1]
        outYears <- c(outYears, year)
      }
    }else{outYears <- c(NA)}
    return(outYears[!is.na(outYears)])
  })
  
  llamaSegments <- sapply(llamaRaw, function(x){
    split_x <- unlist(strsplit(x, split = "\\n", fixed=T))
    outYears <- c()
    if(length(split_x) > 1){
      for(i in 2:length(split_x)){
        year <- unlist(strsplit(
          unlist(strsplit(split_x[i], split = "Segments removed: ", fixed=T))[2], 
          split = ". Procedure", fixed = T))[1]
        outYears <- c(outYears, year)
      }
    }else{outYears <- c(NA)}
    return(outYears[!is.na(outYears)])
  })
  
  names(llamaID) <- NULL; names(llamaYN) <- NULL
  names(llamaProc) <- NULL; names(llamaMonth) <- NULL
  names(llamaYear) <- NULL; names(llamaSegments) <- NULL
  
  
  llama.df <- data.frame("PatientID" = character(), "ColectomyYN" = character(),
                         "Procedure" = character(), "Month" = character(),
                         "Year" = character(), "Segments" = character()) 
  
  for(i in 1:length(llamaID)){
    
    if(llamaYN[i] == "Yes"){
      llama.df <- rbind(llama.df, data.frame("PatientID" = llamaID[i], "ColectomyYN" = llamaYN[i],
                                             "Procedure" = llamaProc[[i]], "Month" = llamaMonth[[i]],
                                             "Year" = llamaYear[[i]], "Segments" = llamaSegments[[i]]))
    }else{
      llama.df <- rbind(llama.df, data.frame("PatientID" = llamaID[i], "ColectomyYN" = llamaYN[i],
                                             "Procedure" = NA, "Month" = NA,
                                             "Year" = NA, "Segments" = NA))
    }
  }
  return(llama.df)
}
