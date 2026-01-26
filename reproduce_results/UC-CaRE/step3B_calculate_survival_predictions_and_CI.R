
get_survival_predictions <- function(time_years){
  
  # Published baseline hazard (per year) and its 95% CI
  lambda_hat <- 0.0053
  lambda_CI <- c(0.0047, 0.0058)   
  
  # Published betas (log-HR) and variance-covariance matrix (from your table)
  beta_hat <- c(large = log(2.7),
                incomplete_or_invisible = log(3.4),
                multifocal = log(2.9),
                endo_moderate_severe = log(3.1))
  
  vcov_mat <- matrix(c(
    0.161051423, -0.005849893, -0.046865593, -0.001038021,
    -0.005849893,  0.156726196, -0.005749705, -0.026911947,
    -0.046865593, -0.005749705,  0.155634218,  0.020300342,
    -0.001038021, -0.026911947,  0.020300342,  0.148660355
  ), nrow = 4, byrow = TRUE)
  colnames(vcov_mat) <- rownames(vcov_mat) <- names(beta_hat)
  
  # All 16 binary combos
  combos <- expand.grid(large = 0:1,
                        incomplete_or_invisible = 0:1,
                        multifocal = 0:1,
                        endo_moderate_severe = 0:1)
  combos$group <- apply(combos, 1, paste0, collapse = "")
  combos$n_risk_factors <- rowSums(combos[,1:4])
  
  # Monte Carlo draws
  n_draws <- 10000
  
  # convert lambda CI -> SE on log-scale
  SE_log_lambda <- (log(lambda_CI[2]) - log(lambda_CI[1])) / (2 * 1.96)
  
  # Draw log(lambda) from Normal(log(lambda_hat), SE_log_lambda^2)
  log_lambda_draws <- rnorm(n_draws, mean = log(lambda_hat), sd = SE_log_lambda)
  
  # Draw beta vectors from multivariate normal
  beta_draws <- MASS::mvrnorm(n_draws, mu = beta_hat, Sigma = vcov_mat)  # matrix n_draws x p
  
  # ------------ Compute predicted survival draws -------------
  # For memory, do per-combo loop, compute S_draws: n_draws x length(time_years)
  
  out_list <- vector("list", nrow(combos))
  for(i in seq_len(nrow(combos))) {
    x <- as.numeric(combos[i, 1:4])            # covariate vector 0/1
    
    # compute linear predictor for each draw: (n_draws)
    lp_draws <- as.vector(beta_draws %*% x)    # log-HR for each draw
    # for each time t compute survival draws: outer operation
    # S = exp( - lambda_draw * t * exp(lp_draw) )
    S_mat <- sapply(time_years, function(t) exp(- exp(log_lambda_draws) * t * exp(lp_draws)))
    # S_mat is n_draws x n_times (columns)
    # summarize mean and 95% CI across draws for each time
    S_mean  <- colMeans(S_mat)
    S_lower <- apply(S_mat, 2, quantile, 0.025)
    S_upper <- apply(S_mat, 2, quantile, 0.975)
    out_list[[i]] <- data.frame(
      group = combos$group[i],
      n_risk_factors = paste0(combos$n_risk_factors[i]),
      time = time_years,
      S_mean = S_mean,
      S_lo = S_lower,
      S_hi = S_upper
    )
  }

  surv_df_tmp <- dplyr::bind_rows(out_list)
  
  surv_df <- surv_df_tmp %>%
    group_by(time, n_risk_factors) %>%
    mutate(
      S_mean_groupBy_n_risk_factors = mean(S_mean),
      S_lo_groupBy_n_risk_factors = mean(S_lo),
      S_hi_groupBy_n_risk_factors = mean(S_hi),
    ) %>% ungroup()
  
  
  return(surv_df)
}



# Required packages
get_survival_predictions_propagate_uncertainty <- function(time_years){
  
  # Published baseline hazard (per year) and its 95% CI
  lambda_hat <- 0.0053
  lambda_CI <- c(0.0047, 0.0058)  
  
  # Published betas (log-HR) and variance-covariance matrix (from your table)
  beta_hat <- c(large = log(2.7),
                incomplete_or_invisible = log(3.4),
                multifocal = log(2.9),
                endo_moderate_severe = log(3.1))
  
  vcov_mat <- matrix(c(
    0.161051423, -0.005849893, -0.046865593, -0.001038021,
    -0.005849893,  0.156726196, -0.005749705, -0.026911947,
    -0.046865593, -0.005749705,  0.155634218,  0.020300342,
    -0.001038021, -0.026911947,  0.020300342,  0.148660355
  ), nrow = 4, byrow = TRUE)
  colnames(vcov_mat) <- rownames(vcov_mat) <- names(beta_hat)
  
  # All 16 binary combos
  combos <- expand.grid(large = 0:1,
                        incomplete_or_invisible = 0:1,
                        multifocal = 0:1,
                        endo_moderate_severe = 0:1)
  combos$group <- apply(combos, 1, paste0, collapse = "")
  combos$n_risk_factors <- rowSums(combos[,1:4])
  
  # Monte Carlo draws
  n_draws <- 10000
  
  # convert lambda CI -> SE on log-scale
  SE_log_lambda <- (log(lambda_CI[2]) - log(lambda_CI[1])) / (2 * 1.96)
  
  # Draw log(lambda) from Normal(log(lambda_hat), SE_log_lambda^2)
  log_lambda_draws <- rnorm(n_draws, mean = log(lambda_hat), sd = SE_log_lambda)
  
  # Draw beta vectors from multivariate normal
  beta_draws <- MASS::mvrnorm(n_draws, mu = beta_hat, Sigma = vcov_mat)  # matrix n_draws x p
  
  # ------------ Compute predicted survival draws -------------
  # For memory, do per-combo loop, compute S_draws: n_draws x length(time_years)
  
  out_list <- vector("list", nrow(combos))
  for(i in seq_len(nrow(combos))) {
    x <- as.numeric(combos[i, 1:4]) # covariate vector 0/1
    names(x) <- colnames(combos)[1:4]
    fraction_of_x <- propagate_uncertainty_byScore(x)
    x1 <- sample(c(0, 1), size = n_draws, prob=c(1-fraction_of_x[1], fraction_of_x[1]), replace=T)
    x2 <- sample(c(0, 1), size = n_draws, prob=c(1-fraction_of_x[2], fraction_of_x[2]), replace=T)
    x3 <- sample(c(0, 1), size = n_draws, prob=c(1-fraction_of_x[3], fraction_of_x[3]), replace=T)
    x4 <- sample(c(0, 1), size = n_draws, prob=c(1-fraction_of_x[4], fraction_of_x[4]), replace=T)
    x_mat <- matrix(data=c(x1, x2, x3, x4), ncol=4)
    
    # compute linear predictor for each draw: (n_draws)
    lp_draws <- rowSums(beta_draws * x_mat)  # log-HR for each draw
    # for each time t compute survival draws: outer operation
    # S = exp( - lambda_draw * t * exp(lp_draw) )
    S_mat <- sapply(time_years, function(t) exp(- exp(log_lambda_draws) * t * exp(lp_draws)))
    
    # WIP: for each run, we want to distribute some of the S_mat to other risk 
    # groups randomly based on fraction of x
    
    # S_mat is n_draws x n_times (columns)
    # summarize mean and 95% CI across draws for each time
    S_mean  <- colMeans(S_mat)
    S_lower <- apply(S_mat, 2, quantile, 0.025)
    S_upper <- apply(S_mat, 2, quantile, 0.975)
    out_list[[i]] <- data.frame(
      group = combos$group[i],
      n_risk_factors = paste0(combos$n_risk_factors[i]),
      time = time_years,
      S_mean = S_mean,
      S_lo = S_lower,
      S_hi = S_upper
    )
  }
  
  surv_df_tmp <- dplyr::bind_rows(out_list)
  
  surv_df <- surv_df_tmp %>%
    group_by(time, n_risk_factors) %>%
    mutate(
      S_mean_groupBy_n_risk_factors = mean(S_mean),
      S_lo_groupBy_n_risk_factors = mean(S_lo),
      S_hi_groupBy_n_risk_factors = mean(S_hi),
    ) %>% ungroup()
  
  
  return(surv_df)
}

# Read in conf mat when sourcing (only do once). Give long name so we don't accidentally overwrite
conf_mat_DONOTOVERWRITE <- read.csv("<PATH>/webtool_validation/data/post_review_UCCARE_confusion_matrix_N=126_included_2025-10-30.csv")
propagate_uncertainty <- function(x_vec){
  
  out_vec <- c()
  for(i in 1:length(x_vec)){
    predictor_name <- names(x_vec)[i]
    conf_mat_tmp <- conf_mat_DONOTOVERWRITE[conf_mat_DONOTOVERWRITE$predictor==predictor_name,]
    
    if(x_vec[i]==0){
      # 0*P(TN|Neg) + 1*P(FN|Neg)
      out_vec[i] <- conf_mat_tmp$FN/sum(conf_mat_tmp$FN + conf_mat_tmp$TN)
    }else{
      # 1*P(TP|Pos) + 0*P(FP|Pos)
      out_vec[i] <- conf_mat_tmp$TP/sum(conf_mat_tmp$TP + conf_mat_tmp$FP)
    }

  }
  names(out_vec) <- names(x_vec)
  return(out_vec)
}

conf_mat_withScore <- read.csv("<PATH>/webtool_validation/data/post_review_UCCARE_confusion_matrix_withScore_N=124_included_2025-11-04.csv")

propagate_uncertainty_byScore <- function(x_vec){
  
  out_vec <- c()
  for(i in 1:length(x_vec)){
    predictor_name <- names(x_vec)[i]
    conf_mat_tmp <- conf_mat_withScore[conf_mat_withScore$predictor==predictor_name &
                                         conf_mat_withScore$score ==sum(x_vec),]
    
    if(x_vec[i]==0){
      # 0*P(TN|Neg) + 1*P(FN|Neg)
      out_vec[i] <- conf_mat_tmp$FN/sum(conf_mat_tmp$FN + conf_mat_tmp$TN)
    }else{
      # 1*P(TP|Pos) + 0*P(FP|Pos)
      out_vec[i] <- conf_mat_tmp$TP/sum(conf_mat_tmp$TP + conf_mat_tmp$FP)
    }
    
  }
  names(out_vec) <- names(x_vec)
  return(out_vec)
}

sampled_lp_propagate_uncertainty <- function(dfIN, betas){
  
  if(is.null(names(betas))){
    stop("betas must be named vec")
  }else if(!all(names(betas) %in% c("large", "incomplete_or_invisible",
                               "multifocal", "endo_moderate_severe"))){
    stop("names of betas must match c('large', 'incomplete_or_invisible',
                               'multifocal', 'endo_moderate_severe')")
  }
    
  lp_sampled <- c()
  for(i in 1:nrow(dfIN)){
    
    x_vec <- c(dfIN$large[i], dfIN$incomplete_or_invisible[i], 
               dfIN$multifocal[i], dfIN$endo_moderate_severe[i])
    names(x_vec) <- c("large", "incomplete_or_invisible",
                      "multifocal", "endo_moderate_severe")
    
    x_draw <- c()
    for(k in 1:length(x_vec)){
      predictor_name <- names(x_vec)[k]
      conf_mat_tmp <- conf_mat_withScore[conf_mat_withScore$predictor==predictor_name &
                                           conf_mat_withScore$score ==sum(x_vec),]
      
      if(x_vec[k]==0){
        # 0*P(TN|Neg) + 1*P(FN|Neg)
        frac_pos <- conf_mat_tmp$FN/sum(conf_mat_tmp$FN + conf_mat_tmp$TN)
      }else{
        # 1*P(TP|Pos) + 0*P(FP|Pos)
        frac_pos <- conf_mat_tmp$TP/sum(conf_mat_tmp$TP + conf_mat_tmp$FP)
      }
      x_draw <- c(x_draw, sample(0:1, size=1, prob =c(1-frac_pos, frac_pos)))
    }
    
    betas <- betas[names(x_vec)]
    
    lp_sampled <- c(lp_sampled, sum(betas * x_draw))
  }
  return(lp_sampled)
  
}

get_cum_haz <- function(lp, lambda_hat, t, maxT=NA){
  
  if(!is.na(maxT)){
    t = min(t, maxT)
  }
  
  return(-log(exp(- lambda_hat * t * exp(lp))))
  
}



