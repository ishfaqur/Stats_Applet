# =============================================================================
# DIAGNOSTICS & VISUALISATION  —  DP-GP Traffic Model
# Source this AFTER running the core script (dp_gp_core.R) so that
# `dat` and `fit` are in the environment.
# =============================================================================
# Requires: ggplot2, dplyr, tidyr, coda  (all loaded by the core script)
# =============================================================================


# =============================================================================
# 1.  TRACE PLOTS FOR SCALAR PARAMETERS
# =============================================================================
plot_traces <- function(fit, true_vals = NULL) {
  ns   <- fit$n_keep
  vars <- c("sigma2","sigma_gp","ell_per","ell_rbf","tau2","alpha_dp")
  labs <- c(expression(sigma^2), expression(sigma[GP]),
            expression(ell[per]), expression(ell[rbf]),
            expression(tau^2),   expression(alpha[DP]))
  
  op <- par(mfrow = c(2L, 3L), mar = c(3, 3, 2.5, 1), mgp = c(2, 0.7, 0))
  for (i in seq_along(vars)) {
    x <- fit[[vars[i]]][seq_len(ns)]
    plot(x, type = "l", col = "#2c7bb6", lwd = 0.6,
         main = labs[[i]], xlab = "Saved draw", ylab = "")
    if (!is.null(true_vals) && vars[i] %in% names(true_vals))
      abline(h = true_vals[[vars[i]]], col = "#d7191c", lty = 2, lwd = 1.5)
  }
  par(op)
  invisible()
}

# Effective sample size & Gelman-Rubin (single chain — just ESS here)
mcmc_diagnostics <- function(fit) {
  ns   <- fit$n_keep
  vars <- c("sigma2","sigma_gp","ell_per","ell_rbf","tau2","alpha_dp")
  ess  <- vapply(vars, function(v) {
    coda::effectiveSize(coda::as.mcmc(fit[[v]][seq_len(ns)]))
  }, numeric(1L))
  cat("Effective sample sizes:\n")
  print(round(ess))
  invisible(ess)
}


# =============================================================================
# 2.  FITTED VALUES + CLUSTER COLOURING
# =============================================================================
plot_fitted <- function(fit, n_plot_days = 7L, alpha_pts = 0.35) {
  dat  <- fit$dat
  ns   <- fit$n_keep
  ipd  <- dat$ipd
  idx  <- seq_len(min(n_plot_days * ipd, dat$n))
  
  fs   <- fitted_summary(fit)
  cmap <- map_clusters(fit)
  
  df <- data.frame(
    t      = dat$t[idx],
    y      = dat$y[idx],
    fit    = fs$mean[idx],
    lo     = fs$lo[idx],
    hi     = fs$hi[idx],
    c_map  = factor(cmap[idx])#,
    #c_true = factor(dat$c_true[idx])
  )
  
  p <- ggplot(df, aes(t)) +
    geom_ribbon(aes(ymin = lo, ymax = hi), fill = "#4393c3", alpha = 0.20) +
    geom_point(aes(y = y, colour = c_map), size = 0.4, alpha = alpha_pts) +
    geom_line(aes(y = fit), colour = "#2166ac", linewidth = 0.65) +
    scale_colour_viridis_d(name = "MAP cluster") +
    labs(x = "Time (days)", y = "log(speed / v_ref)",
         title = sprintf("Fitted values + 95%% CI  [first %d days]", n_plot_days),
         subtitle = "Coloured by MAP cluster assignment") +
    theme_bw(base_size = 11)
  p2 <- df %>% 
    ggplot(aes(x=exp(y),fill=c_map))+
    geom_density(alpha = alpha_pts)+
    scale_fill_viridis_d()+
    theme_bw(base_size = 11)+
    labs(x = "speed / ref_speed",
         title = sprintf("Density of the ratio  [first %d days]", n_plot_days),
         subtitle = "by MAP cluster assignment") 
  print(p)
  print(p2)
  invisible(df)
}


# =============================================================================
# 3.  GP COMPONENT:  posterior mean eta(t)
# =============================================================================
plot_gp <- function(fit, n_plot_days = 7L) {
  dat <- fit$dat
  ns  <- fit$n_keep
  ipd <- dat$ipd
  idx <- seq_len(min(n_plot_days * ipd, dat$n))
  
  eta_post <- fit$eta[seq_len(ns), idx]
  eta_mean <- colMeans(eta_post)
  eta_lo   <- apply(eta_post, 2L, quantile, 0.025)
  eta_hi   <- apply(eta_post, 2L, quantile, 0.975)
  
  df <- data.frame(
    t        = dat$t[idx],
    eta_mean = eta_mean,
    eta_lo   = eta_lo,
    eta_hi   = eta_hi#,
    #eta_true = dat$eta_true[idx]
  )
  
  p <- ggplot(df, aes(t)) +
    geom_ribbon(aes(ymin = eta_lo, ymax = eta_hi), fill = "#74add1", alpha = 0.25) +
    geom_line(aes(y = eta_mean), colour = "#4575b4", linewidth = 0.7,
              linetype = "solid") +
    # geom_line(aes(y = eta_true), colour = "#d73027", linewidth = 0.55,
    #           linetype = "dashed") +
    labs(x = "Time (days)", y = expression(eta(t)),
         title = "GP temporal component",
         subtitle = "Blue = posterior mean + 95% CI") +
    theme_bw(base_size = 11)
  print(p)
  invisible(df)
}


# =============================================================================
# 4.  CLUSTER MEMBERSHIP HEATMAP  (observations x MCMC draws)
# =============================================================================
plot_cluster_heatmap <- function(fit, n_plot_days = 3L) {
  dat  <- fit$dat
  ns   <- fit$n_keep
  ipd  <- dat$ipd
  idx  <- seq_len(min(n_plot_days * ipd, dat$n))
  
  pm   <- posterior_cluster_probs(fit)[idx, ]
  K_eff <- which(colSums(pm) > 0.01)    # keep active clusters only
  
  df <- as.data.frame(pm[, K_eff, drop = FALSE])
  df$t <- dat$t[idx]
  df   <- tidyr::pivot_longer(df, -t, names_to = "cluster", values_to = "prob")
  df$cluster <- factor(df$cluster, levels = paste0("V", K_eff))
  
  p <- ggplot(df, aes(t, prob, fill = cluster)) +
    geom_area(position = "stack") +
    scale_fill_viridis_d(name = "Cluster") +
    labs(x = "Time (days)", y = "Posterior membership probability",
         title = sprintf("Cluster membership probabilities [first %d days]",
                         n_plot_days)) +
    theme_bw(base_size = 11)
  print(p)
  invisible(df)
}


# =============================================================================
# 5.  CLUSTER-SPECIFIC BETA POSTERIORS (violin / ridge plot)
# =============================================================================
plot_beta_posteriors <- function(fit, predictor_idx = 1L,
                                 pred_name = "Intercept") {
  ns    <- fit$n_keep
  K     <- fit$K
  # Active clusters (appeared at least once in saved draws)
  active <- which(colSums(fit$pi_dp[seq_len(ns), ]) > 0.01)
  
  df <- do.call(rbind, lapply(active, function(k) {
    data.frame(
      cluster = factor(k),
      beta    = fit$beta[seq_len(ns), k, predictor_idx]
    )
  }))
  
  p <- ggplot(df, aes(cluster, beta, fill = cluster)) +
    geom_violin(alpha = 0.6, colour = NA, scale = "width") +
    geom_boxplot(width = 0.15, outlier.size = 0.6, colour = "grey30") +
    scale_fill_viridis_d(guide = "none") +
    labs(x = "Cluster", y = bquote(beta[.(pred_name)]),
         title = sprintf("Posterior of '%s' coefficient by cluster", pred_name)) +
    theme_bw(base_size = 11)
  print(p)
  invisible(df)
}


# =============================================================================
# 6.  NUMBER OF ACTIVE CLUSTERS OVER ITERATIONS
# =============================================================================
plot_n_clusters <- function(fit) {
  nct <- n_clusters_trace(fit)
  df  <- data.frame(draw = seq_along(nct), n_clust = nct)
  p   <- ggplot(df, aes(draw, n_clust)) +
    geom_line(colour = "#1b7837", linewidth = 0.6) +
    labs(x = "Saved draw", y = "# active clusters",
         title = "Effective number of clusters per MCMC draw",
         subtitle = "Dashed = true number of regimes (3)") +
    theme_bw(base_size = 11)
  print(p)
  invisible(df)
}


# =============================================================================
# 7.  SPECTRAL DENSITY VISUALISATION
#     Shows the HSGP prior spectral density at posterior mean hyperparameters
# =============================================================================
plot_spectral <- function(fit) {
  ns  <- fit$n_keep
  dat <- fit$dat
  
  sg  <- mean(fit$sigma_gp[seq_len(ns)])
  lp  <- mean(fit$ell_per[seq_len(ns)])
  lr  <- mean(fit$ell_rbf[seq_len(ns)])
  om  <- fit$hgp$omega
  
  S_post <- hsgp_spectral(om, sg, lp, lr, dat$T_per)
  # S_true <- hsgp_spectral(om, dat$sigma_gp_true, dat$ell_per_true,
  #                         dat$ell_rbf_true, dat$T_per)
  
  # Convert to cycles/day for readability
  cpd <- om / (2 * pi)
  df  <- data.frame(cpd = cpd,
                    S = S_post / sum(S_post))#,
                    #S_true = S_true / sum(S_true))
  #df  <- tidyr::pivot_longer(df, -cpd, names_to = "type", values_to = "S")
  #df$which <- ifelse(df$type == "S_post", "Posterior mean", "True")
  
  p <- ggplot(df, aes(cpd, S)) +
    geom_line(linewidth = 0.8, color = "#2166ac") +
    scale_x_continuous(breaks = 0:5,
                       labels = c("0","1\n(daily)","2\n(48h)","3\n(64h)",
                                  "4\n(6h)","5\n(4.8h)")) +
    labs(x = "Frequency (cycles / day)", y = "Normalised spectral density",
         title = "HSGP prior spectral density") +#,
         #subtitle = "Peaks at harmonic frequencies of the daily cycle") +
    theme_bw(base_size = 11)
  print(p)
  invisible(df)
}


# =============================================================================
# 8.  POSTERIOR PREDICTIVE CHECK
# =============================================================================
plot_ppc <- function(fit, n_rep = 200L) {
  dat <- fit$dat
  ns  <- fit$n_keep
  idx <- sample.int(ns, min(n_rep, ns))
  
  y_rep_mat <- matrix(0.0, length(idx), dat$n)
  for (ii in seq_along(idx)) {
    s         <- idx[ii]
    beta_s <- matrix(fit$beta[s, fit$c_asgn[s, ], ], nrow = dat$n, ncol = dat$p)
    mu_s      <- rowSums(dat$X * beta_s) +
      fit$eta[s, ]
    y_rep_mat[ii, ] <- rnorm(dat$n, mu_s, sqrt(fit$sigma2[s]))
  }
  
  df <- data.frame(
    y_obs = dat$y,
    y_rep_mean = colMeans(y_rep_mat),
    y_rep_lo   = apply(y_rep_mat, 2L, quantile, 0.025),
    y_rep_hi   = apply(y_rep_mat, 2L, quantile, 0.975)
  )
  
  p <- ggplot(df, aes(y_obs, y_rep_mean)) +
    geom_point(size = 0.3, alpha = 0.3, colour = "#4393c3") +
    geom_abline(slope = 1, intercept = 0, colour = "#d73027", linewidth = 0.8) +
    labs(x = "Observed  y(t)", y = "Posterior predictive mean",
         title = "Posterior predictive check",
         subtitle = "Points should lie near the red identity line") +
    theme_bw(base_size = 11)
  print(p)
  invisible(df)
}


# =============================================================================
# 9.  CONVENIENCE WRAPPER — run all plots
# =============================================================================
plot_all <- function(fit, n_plot_days = 7L, true_vals=NULL) {
  # true_vals <- list(sigma2   = fit$dat$sigma_eps_true^2,
  #                   sigma_gp = fit$dat$sigma_gp_true,
  #                   ell_per  = fit$dat$ell_per_true,
  #                   ell_rbf  = fit$dat$ell_rbf_true)
  cat("--- Trace plots ---\n")
  plot_traces(fit, true_vals)
  cat("--- ESS ---\n")
  mcmc_diagnostics(fit)
  cat("--- Fitted values ---\n")
  plot_fitted(fit, n_plot_days)
  cat("--- GP component ---\n")
  plot_gp(fit, n_plot_days)
  cat("--- Cluster membership ---\n")
  plot_cluster_heatmap(fit, min(n_plot_days, 3L))
  cat("--- Beta posteriors (intercept) ---\n")
  plot_beta_posteriors(fit, 1L, "Intercept")
  cat("--- Beta posteriors weekend ---\n")
  plot_beta_posteriors(fit, 2L, "weekend")
  # cat("--- Active clusters ---\n")
  # plot_n_clusters(fit)
  cat("--- Spectral density ---\n")
  plot_spectral(fit)
  cat("--- PPC ---\n")
  plot_ppc(fit)
  invisible()
}

# Run all diagnostics on the fitted model
plot_all(fit, n_plot_days = 7L)

