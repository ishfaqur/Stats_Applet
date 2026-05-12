source("HSGP_StickBreakingCode.R")

load("Input_for_HSGP.RData")

data <- data %>% filter(!is.na(speed))
x <- model.matrix(as.formula("~daytype"),data)
colnames(x)[2] <- "weekend"
dat <- list(y = log(data$speed/data$reference_speed),
            X = x,
            t = data$seq_id/96,
            n = nrow(data),
            p = ncol(x),
            T_per = 1,
            ipd = 96)  # 4*24 = 96 15-minute intervals/day


cat(sprintf("n=%d obs, p=%d predictors, T_per=%.0f day\n", 
            dat$n, dat$p, dat$T_per))


cat("\n=== Fitting DP-GP model ===\n")
fit <- fit_dp_gp(
  dat      = dat,
  K        = 4L,
  M        = 250L,
  n_iter   = 20000L,
  n_burnin = 10000L,
  n_thin   = 2L,
  verbose  = TRUE,
  freq     = 500L,
  bf = 1.5,  n_harm = 8L#,
  # Priors (need to play with these!)
  # a_sig = 2.0, b_sig = 0.05,
  # a_alp = 2.0, b_alp = 1.0,
  # sc_sgp = 0.5, sc_lper = 1.0, sc_lrbf = 10.0,
  # # Init & MH tuning
  # sgp0 = 0.15, lper0 = 1.0, lrbf0 = 3.0,
  # mh_sgp = 0.25, mh_lper = 0.25, mh_lrbf = 0.30,
)



cat("\n=== Posterior scalar summaries ===\n")
print(round(summarise_scalars(fit), 4))

source("Diagnostics_n_Visualization.R")
