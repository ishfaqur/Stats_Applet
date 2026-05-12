# =============================================================================
# TRAFFIC SPEED MODEL  —  Bayesian DP Mixture + Locally-Periodic HSGP
# =============================================================================
# Model:  y(t) = X(t)' beta[c(t)] + eta(t) + eps(t)
#
#   y(t)    : log( speed(t) / v_ref )
#   X(t)    : intercept [+ optional covariates]
#   beta[k] : cluster-k regression vector  —  Horseshoe base distribution
#   c(t)    : cluster label  ~  Truncated Dirichlet Process (stick-breaking, K atoms)
#   eta(t)  : GP, locally-periodic kernel  k(tau) = sigma_gp^2
#               * exp( -2 sin^2(pi*tau/T) / ell_per^2 )   [periodic]
#               * exp( -tau^2 / (2 ell_rbf^2) )            [RBF envelope]
#             Approximated via Hilbert-Space GP (HSGP, M basis functions)
#   eps(t)  : iid N(0, sigma^2)
#
# Priors:
#   sigma^2           ~ InvGamma(a_sig, b_sig)
#   alpha_dp          ~ Gamma(a_alp, b_alp)
#   sigma_gp, ell_per, ell_rbf ~ Half-Cauchy  [MH on log scale]
#   beta[k,j] | tau, lambda[k,j] ~ N(0, tau^2 lambda[k,j]^2)
#   lambda[k,j] ~ Half-Cauchy(0,1)            [local horseshoe scale]
#   tau         ~ Half-Cauchy(0,1)            [global horseshoe scale]
#
# Computational strategy:
#   - HSGP reduces GP cost from O(n^3) to O(nM + M^3).
#     Spectral density of the product kernel is derived analytically:
#     the periodic factor is expanded in a Fourier–Bessel series so that
#     S_product(w) = sigma_gp^2 * sum_k c_k/2 * [S_rbf(w-k*w0)+S_rbf(w+k*w0)]
#     where c_k = exp(-1/l^2)*I_k(1/l^2) and S_rbf is the RBF spectral density.
#   - Phi'Phi precomputed once (M x M). Only the diagonal and scalar sigma2
#     change between iterations, so no full matrix rebuild is needed.
#   - All Horseshoe conditionals are closed-form InvGamma.
#   - Cluster assignments are sampled via a vectorised cumulative-sum trick
#     (no per-observation R loop).
#   - Beta[k] update uses a p x p Cholesky solve (p is tiny: 1-4).
#
# References:
#   Riutort-Mayol et al. (2023). Practical HSGP for probabilistic programming.
#   Makalic & Schmidt (2016). A simple sampler for the horseshoe estimator.
#   Sethuraman (1994). Constructive definition of the Dirichlet process.
# =============================================================================

# ---- Package bootstrap -------------------------------------------------------
pkgs <- c("coda", "ggplot2", "dplyr", "tidyr")
new  <- pkgs[!vapply(pkgs, requireNamespace, logical(1L), quietly = TRUE)]
if (length(new)) install.packages(new, quiet = TRUE)
invisible(lapply(pkgs, library, character.only = TRUE))


# =============================================================================
# 1.  UTILITY FUNCTIONS
# =============================================================================

# Inverse-Gamma sampler:  X ~ IG(shape, rate)  =>  E[X] = rate / (shape - 1)
rinvgamma <- function(n, shape, rate){
  1.0 / rgamma(n, shape = shape, rate = rate)
}
# Stick-breaking weights from v[1:(K-1)]
#   pi_k = v_k * prod_{j < k} (1 - v_j)
stick_break <- function(v) {
  K  <- length(v) + 1L
  pi <- numeric(K)
  r  <- 1.0
  for (k in seq_len(K - 1L)) { pi[k] <- v[k] * r; r <- r * (1.0 - v[k]) }
  pi[K] <- r
  pi
}

# Vectorised categorical sampler from rows of a log-probability matrix.
#   log_prob : n x K  (unnormalised; row-constant shifts cancel)
#   Returns  : integer vector length n, values in {1,...,K}
#
# Method: build cumulative-probability matrix column-by-column (O(nK), no loop
# over n). Then exploit R's column-major storage so that  cum_p < u  correctly
# broadcasts the length-n vector u across all K columns.
rcat_rows <- function(log_prob) {
  n <- nrow(log_prob); K <- ncol(log_prob)
  lp_max <- apply(log_prob, 1L, max)               # numeric stability
  prob   <- exp(log_prob - lp_max)
  prob   <- prob / rowSums(prob)
  cum_p  <- prob
  for (k in 2L:K) cum_p[, k] <- cum_p[, k - 1L] + prob[, k]
  u <- runif(n)
  # cum_p < u: column-major recycling applies u[i] to every row i across cols.
  # rowSums counts columns STRICTLY below u[i]  =>  first-exceed index.
  as.integer(rowSums(cum_p < u) + 1L)
}

# Safe Cholesky with jitter fallback
safe_chol <- function(A, jitter = 1e-9) {
  tryCatch(chol(A), error = function(e) chol(A + diag(jitter, nrow(A))))
}


# =============================================================================
# 2.  HSGP UTILITIES
# =============================================================================

# Build HSGP eigenbasis on  t in [min(t), max(t)].
#
# Domain mapping:  t_s = (t - t_mid) / (t_rng/2)  maps  [min,max] -> [-1,1].
# Expanded domain: [-L, L]  with  L = bf  (in scaled units).
#
# Eigenfunctions:  phi_m(t_s) = sin( m*pi*(t_s + L) / (2L) ) / sqrt(L)
#
# Eigenfrequencies in ORIGINAL (day) units:
#   omega_m = m * pi / (L * t_rng)   [rad / day]
# (This is independent of bf when expressed in original units — bf only
# controls approximation accuracy at the domain boundaries.)
#
# With t_rng = 30 days and bf = 1.5:
#   omega_m = m * pi / 45   =>  daily frequency (2*pi rad/day) at m = 90,
#   so M = 250 covers harmonics up to ~8.3 cycles/day (2.9-hr periods).
hsgp_basis <- function(t, M, bf = 1.5) {
  t_rng <- diff(range(t))
  t_mid <- (max(t) + min(t)) / 2.0
  t_s   <- (t - t_mid) / (t_rng / 2.0)
  L     <- bf
  m_seq <- seq_len(M)
  omega <- m_seq * pi / (L * t_rng)           # rad/day
  Phi   <- outer(t_s, m_seq,
                 function(ts, mm) sin(mm * pi * (ts + L) / (2.0 * L)) / sqrt(L))
  list(Phi = Phi, omega = omega, M = M, bf = bf,
       t_rng = t_rng, t_mid = t_mid, L = L)
}

# Spectral density of the locally-periodic x RBF kernel at frequencies omega.
#
# Fourier-Bessel expansion of the periodic factor:
#   exp(-2 sin^2(pi*tau/T)/l^2) = sum_{k>=0} c_k * cos(2*pi*k*tau/T)
#   c_0 = exp(-1/l^2) I_0(1/l^2),   c_k = 2 exp(-1/l^2) I_k(1/l^2)  (k >= 1)
# Using  besselI(..., expon.scaled=TRUE) = exp(-x) * I_k(x)  for stability.
#
# S_product(w) = sigma_gp^2 * { c_0 S_rbf(w)
#   + sum_{k=1}^{n_harm} (c_k/2) [S_rbf(w - k*w0) + S_rbf(w + k*w0)] }
# where  S_rbf(w) = ell_rbf * sqrt(2*pi) * exp(-ell_rbf^2 * w^2 / 2)
#        w0 = 2*pi / T_per
hsgp_spectral <- function(omega, sigma_gp, ell_per, ell_rbf, T_per,
                          n_harm = 8L) {
  inv_l2 <- 1.0 / ell_per^2
  c_k    <- pmax(c(
    besselI(inv_l2, nu = 0L,             expon.scaled = TRUE),
    2.0 * besselI(inv_l2, nu = seq_len(n_harm), expon.scaled = TRUE)
  ), 0.0)
  S_rbf  <- function(w) ell_rbf * sqrt(2.0 * pi) * exp(-0.5 * ell_rbf^2 * w^2)
  w0     <- 2.0 * pi / T_per
  S      <- c_k[1L] * S_rbf(omega)
  for (k in seq_len(n_harm))
    S <- S + (c_k[k + 1L] / 2.0) *
    (S_rbf(omega - k * w0) + S_rbf(omega + k * w0))
  sigma_gp^2 * pmax(S, 1e-12)
}


# =============================================================================
# 3.  DATA SIMULATION
# =============================================================================

# Simulate one month of 15-minute traffic speed data.
#
# Three latent traffic regimes (true cluster labels):
#   1 — Morning rush  (weekdays 07:00 – 09:00)
#   2 — Evening rush  (weekdays 16:30 – 18:30)
#   3 — Free flow     (all other times & weekends)
#
# The GP component is generated via random Fourier features drawn from the
# exact spectral density of the locally-periodic x RBF kernel.
#
# Args:
#   n_days       : days of data  (30 => n = 2 976 obs at 15-min intervals)
#   interval_min : sampling interval in minutes
#   n_extra_pred : extra predictors beyond intercept
#                  0 => intercept only
#                  1 => + weekend indicator
#                  2 => + weekend + sin(2*pi*hour/24)
#                  3 => + weekend + sin + cos
simulate_traffic <- function(n_days = 30L, interval_min = 15L,
                             n_extra_pred = 0L, sigma_gp = 0.12,
                             ell_per = 0.80, ell_rbf      = 3.00,
                             sigma_eps    = 0.04, seed = 2025L) {
  set.seed(seed)
  ipd <- 24L * 60L %/% interval_min             # intervals per day  (96)
  n   <- n_days * ipd
  dt  <- interval_min / (60.0 * 24.0)           # minutes -> fraction of a day
  t   <- seq(0.0, n_days - dt, by = dt)         # time in days
  
  hour    <- (t %% 1.0) * 24.0                  # hour of day  [0, 24)
  dow     <- floor(t) %% 7L                     # day-of-week  0=Mon…6=Sun
  is_wknd <- dow >= 5L
  
  # True cluster assignments
  c_true <- rep(3L, n)
  c_true[!is_wknd & hour >= 7.0  & hour <  9.0 ] <- 1L
  c_true[!is_wknd & hour >= 16.5 & hour < 18.5 ] <- 2L
  
  # Design matrix
  p   <- 1L + n_extra_pred
  nms <- c("intercept", "weekend", "sin_hour", "cos_hour")[seq_len(p)]
  X   <- matrix(1.0, n, p, dimnames = list(NULL, nms))
  if (n_extra_pred >= 1L) X[, 2L] <- as.double(is_wknd)
  if (n_extra_pred >= 2L) X[, 3L] <- sin(2.0 * pi * hour / 24.0)
  if (n_extra_pred >= 3L) X[, 4L] <- cos(2.0 * pi * hour / 24.0)
  
  # True regression coefficients per cluster
  beta_true       <- matrix(0.0, 3L, p, dimnames =
                              list(c("morning","evening","freeflow"), nms))
  beta_true[,1L]  <- c(-0.55, -0.75, -0.08)
  if (n_extra_pred >= 1L) beta_true[,2L] <- c( 0.12,  0.18,  0.15)
  if (n_extra_pred >= 2L) beta_true[,3L] <- c(-0.10, -0.08,  0.05)
  if (n_extra_pred >= 3L) beta_true[,4L] <- c(-0.05, -0.04,  0.02)
  lin_pred <- rowSums(X * beta_true[c_true, , drop = FALSE])
  
  # GP via random Fourier features from the exact product-kernel spectral density
  T_per  <- 1.0
  n_rff  <- 2000L
  inv_l2 <- 1.0 / ell_per^2
  Kf     <- 10L
  c_k    <- pmax(c(
    besselI(inv_l2, 0L, expon.scaled = TRUE),
    2.0 * besselI(inv_l2, seq_len(Kf), expon.scaled = TRUE)
  ), 0.0)
  ctot   <- sum(c_k);  w0 <- 2.0 * pi / T_per
  eta    <- numeric(n)
  
  for (k in 0L:Kf) {
    ck <- c_k[k + 1L];  if (ck < 1e-12) next
    nk <- max(1L, round(n_rff * ck / ctot))
    sc <- sqrt(2.0 * sigma_gp^2 * ck / (nk * ctot))
    # Positive-frequency component
    om <- rnorm(nk, k * w0, 1.0 / ell_rbf)
    ph <- runif(nk, 0.0, 2.0 * pi)
    eta <- eta + sc * rowSums(cos(outer(t, om) + matrix(ph, n, nk, byrow = TRUE)))
    # Negative-frequency component (k >= 1 only)
    if (k > 0L) {
      om2 <- rnorm(nk, -k * w0, 1.0 / ell_rbf)
      ph2 <- runif(nk, 0.0, 2.0 * pi)
      eta <- eta + sc * rowSums(cos(outer(t, om2) + matrix(ph2, n, nk, byrow = TRUE)))
    }
  }
  eta <- eta * sqrt(sigma_gp^2 / max(var(eta), 1e-10))  # rescale to target SD
  
  y <- lin_pred + eta + rnorm(n, 0.0, sigma_eps)
  
  list(y = y, X = X, t = t, n = n, p = p,
       hour = hour, dow = dow, is_wknd = is_wknd,
       c_true = c_true, beta_true = beta_true,
       eta_true = eta, lin_pred_true = lin_pred,
       n_days = n_days, ipd = ipd, T_per = T_per,
       sigma_gp_true  = sigma_gp,  ell_per_true  = ell_per,
       ell_rbf_true   = ell_rbf,   sigma_eps_true = sigma_eps)
}


# =============================================================================
# 4.  MCMC SAMPLER
# =============================================================================
#
# All updates are described in-line below.  The notation follows the model
# header at the top of the file.
#
# Args:
#   dat            : output of simulate_traffic()  (or same-structured list)
#   K              : DP truncation level  (20 is usually conservative)
#   M              : HSGP basis functions (250 covers ~8 daily harmonics for 30 days)
#   bf             : HSGP boundary factor (>= 1.5)
#   n_harm         : harmonics in spectral-density approximation
#   a_sig / b_sig  : InvGamma(a,b) prior on sigma^2
#   a_alp / b_alp  : Gamma(a,b) prior on alpha_dp
#   sc_sgp/lper/lrbf : Half-Cauchy scales for GP hyperparameters
#   sgp0/lper0/lrbf0 : initial GP hyperparameter values
#   mh_*           : MH proposal SD on the log scale for each GP hyperparam
#   n_iter / n_burnin / n_thin : MCMC schedule
fit_dp_gp <- function(dat, K = 20L,  M = 250L,  bf = 1.5,  n_harm = 8L,
                      # Priors 
                      a_sig = 2.0, b_sig = 0.05,
                      a_alp = 2.0, b_alp = 1.0,
                      sc_sgp = 0.5, sc_lper = 1.0, sc_lrbf = 10.0,
                      # Init & MH tuning
                      sgp0 = 0.15, lper0 = 1.0, lrbf0 = 3.0,
                      mh_sgp = 0.25, mh_lper = 0.25, mh_lrbf = 0.30,
                      # MCMC
                      n_iter = 3000L, n_burnin = 1000L, n_thin = 2L,
                      verbose = TRUE, freq = 250L) {
  y <- dat$y;  X <- dat$X;  t <- dat$t
  n <- dat$n;  p <- dat$p;  T_per <- dat$T_per
  
  # ---------- Pre-compute HSGP basis (constant throughout MCMC) --------------
  hgp   <- hsgp_basis(t, M, bf)
  Phi   <- hgp$Phi                     # n x M  — fixed
  omega <- hgp$omega                   # M-vector of eigenfrequencies [rad/day]
  PtP   <- crossprod(Phi)              # M x M  — computed once
  
  # ---------- Initialise ------------------------------------------------------
  sigma_gp <- sgp0;  ell_per <- lper0;  ell_rbf <- lrbf0
  S_diag   <- hsgp_spectral(omega, sigma_gp, ell_per, ell_rbf, T_per, n_harm)
  f_gp     <- rnorm(M, 0.0, sqrt(S_diag))
  eta      <- as.double(Phi %*% f_gp)
  
  sigma2   <- 0.02
  alpha_dp <- 2.0
  v        <- rbeta(K - 1L, 1.0, alpha_dp)
  pi_dp    <- stick_break(v)
  c_asgn   <- sample.int(K, n, replace = TRUE, prob = pi_dp)
  n_k      <- tabulate(c_asgn, nbins = K)
  
  # Horseshoe  (K x p matrices)
  tau2   <- 1.0;  xi <- 1.0
  lam2   <- matrix(1.0, K, p)
  psi_hs <- matrix(1.0, K, p)
  beta   <- matrix(0.0, K, p)
  beta[, 1L] <- seq(-0.8, -0.05, length.out = K)   # spread intercepts initially
  
  # ---------- Storage ---------------------------------------------------------
  n_keep <- as.integer(floor((n_iter - n_burnin) / n_thin))
  SS <- list(
    beta     = array(0.0, c(n_keep, K, p)),
    c_asgn   = matrix(0L,  n_keep, n),
    f_gp     = matrix(0.0, n_keep, M),
    eta      = matrix(0.0, n_keep, n),
    pi_dp    = matrix(0.0, n_keep, K),
    sigma2   = numeric(n_keep),
    sigma_gp = numeric(n_keep),
    ell_per  = numeric(n_keep),
    ell_rbf  = numeric(n_keep),
    tau2     = numeric(n_keep),
    alpha_dp = numeric(n_keep)
  )
  mh_acc <- integer(3L)      # acceptance counts for sigma_gp, ell_per, ell_rbf
  ks     <- 0L               # saved-sample counter
  
  cat(sprintf(
    "MCMC | n=%d  p=%d  K=%d  M=%d  n_iter=%d  n_keep=%d\n",
    n, p, K, M, n_iter, n_keep))
  t0 <- proc.time()["elapsed"]
  
  # ==========================================================================
  # MAIN LOOP
  # ==========================================================================
  for (iter in seq_len(n_iter)) {
    
    # ---- (a) Update GP basis coefficients f_gp  [blocked Gaussian] ----------
    # Residuals after subtracting the linear predictor:
    #   r = y - X beta[c(t)]
    # Conditional model:  r = Phi f + eps,  eps ~ N(0, sigma^2 I)
    # Prior:              f_m ~ N(0, S_m)  (diagonal, independent)
    # Posterior precision: Sigma_f^{-1} = Phi'Phi/sigma2 + diag(1/S_diag)
    # Posterior mean:      mu_f = Sigma_f * Phi'r / sigma2
    r_lin    <- y - rowSums(X * beta[c_asgn, , drop = FALSE])
    Phr      <- crossprod(Phi, r_lin)            # Phi'r, M-vector
    Prec_f   <- PtP / sigma2                     # Phi'Phi / sigma2  (M x M)
    diag(Prec_f) <- diag(Prec_f) + 1.0 / S_diag # add prior precision
    U        <- safe_chol(Prec_f)                # upper Cholesky
    mu_f     <- backsolve(U, forwardsolve(t(U), Phr / sigma2))
    f_gp     <- mu_f + backsolve(U, rnorm(M))    # N(mu_f, Sigma_f) sample
    eta      <- as.double(Phi %*% f_gp)
    
    # ---- (b) Update GP hyperparameters  [MH on log scale] -------------------
    # Log-posterior for (sigma_gp, ell_per, ell_rbf) given f_gp:
    #   log p(theta | f) = log p(theta)  +  sum_m [ -0.5 log S_m - 0.5 f_m^2/S_m ]
    # Half-Cauchy(0, sc) on positive reals =>
    #   log p(x) = log(2) + dcauchy(x, 0, sc, log=TRUE),  x > 0
    lp_gp <- function(sg, lp, lr) {
      if (sg <= 0 || lp <= 0 || lr <= 0) return(-Inf)
      S <- hsgp_spectral(omega, sg, lp, lr, T_per, n_harm)
      if (any(!is.finite(S) | S <= 0)) return(-Inf)
      lpr <- (log(2) + dcauchy(sg, 0, sc_sgp,  log = TRUE) +
                log(2) + dcauchy(lp, 0, sc_lper, log = TRUE) +
                log(2) + dcauchy(lr, 0, sc_lrbf, log = TRUE))
      lpr - 0.5 * sum(log(S) + f_gp^2 / S)
    }
    lp_cur <- lp_gp(sigma_gp, ell_per, ell_rbf)
    
    # sigma_gp  (Jacobian term log(sg_pr/sigma_gp) for log-scale proposal)
    sg_pr <- exp(log(sigma_gp) + rnorm(1L, 0, mh_sgp))
    if (log(runif(1L)) < lp_gp(sg_pr, ell_per, ell_rbf) - lp_cur +
        log(sg_pr / sigma_gp)) {
      sigma_gp <- sg_pr
      S_diag   <- hsgp_spectral(omega, sigma_gp, ell_per, ell_rbf, T_per, n_harm)
      lp_cur   <- lp_gp(sigma_gp, ell_per, ell_rbf)
      mh_acc[1L] <- mh_acc[1L] + 1L
    }
    # ell_per
    lp_pr <- exp(log(ell_per) + rnorm(1L, 0, mh_lper))
    if (log(runif(1L)) < lp_gp(sigma_gp, lp_pr, ell_rbf) - lp_cur +
        log(lp_pr / ell_per)) {
      ell_per <- lp_pr
      S_diag  <- hsgp_spectral(omega, sigma_gp, ell_per, ell_rbf, T_per, n_harm)
      lp_cur  <- lp_gp(sigma_gp, ell_per, ell_rbf)
      mh_acc[2L] <- mh_acc[2L] + 1L
    }
    # ell_rbf
    lr_pr <- exp(log(ell_rbf) + rnorm(1L, 0, mh_lrbf))
    if (log(runif(1L)) < lp_gp(sigma_gp, ell_per, lr_pr) - lp_cur +
        log(lr_pr / ell_rbf)) {
      ell_rbf <- lr_pr
      S_diag  <- hsgp_spectral(omega, sigma_gp, ell_per, ell_rbf, T_per, n_harm)
      mh_acc[3L] <- mh_acc[3L] + 1L
    }
    
    # ---- (c) Update cluster betas  [blocked Gaussian, per cluster] ----------
    # For cluster k with observations idx_k:
    #   Likelihood:  r_gp[idx_k] = X[idx_k,] beta[k,] + eps,  eps ~ N(0,sigma2 I)
    #   Prior:       beta[k,j] ~ N(0, tau2 * lam2[k,j])
    #   Posterior precision:  X_k'X_k/sigma2 + diag(1/(tau2*lam2[k,]))
    # Empty clusters: draw from prior (needed for potential future reassignment).
    r_gp <- y - eta
    for (k in seq_len(K)) {
      pr_prec <- diag(1.0 / (tau2 * lam2[k, ]), p, p)
      idx_k   <- which(c_asgn == k)
      if (length(idx_k) == 0L) {
        Lpr        <- safe_chol(diag(tau2 * lam2[k, ], p, p))
        beta[k, ]  <- as.double(t(Lpr) %*% rnorm(p))
      } else {
        Xk  <- X[idx_k, , drop = FALSE]
        rk  <- r_gp[idx_k]
        Pk  <- crossprod(Xk) / sigma2 + pr_prec
        Uk  <- safe_chol(Pk)
        muk <- backsolve(Uk, forwardsolve(t(Uk), crossprod(Xk, rk) / sigma2))
        beta[k, ] <- as.double(muk + backsolve(Uk, rnorm(p)))
      }
    }
    
    # ---- (d) Horseshoe hyperparameters  [InvGamma conjugate] ----------------
    # Auxiliary variable representation (Makalic & Schmidt 2016):
    #   beta[k,j] | tau2, lam2[k,j] ~ N(0, tau2 * lam2[k,j])
    #   lam2[k,j] | psi_hs[k,j]     ~ IG(1/2, 1/psi_hs[k,j])
    #   psi_hs[k,j]                  ~ IG(1/2, 1)
    #   tau2      | xi               ~ IG(1/2, 1/xi)
    #   xi                           ~ IG(1/2, 1)
    # Full conditionals:
    #   lam2[k,j] | ...  ~ IG(1, 1/psi[k,j] + beta[k,j]^2/(2*tau2))
    #   psi[k,j]  | lam2 ~ IG(1, 1 + 1/lam2[k,j])
    #   tau2      | ...  ~ IG((K*p+1)/2, 1/xi + sum(beta^2/lam2)/2)
    #   xi        | tau2 ~ IG(1, 1 + 1/tau2)
    lam2 <- matrix(rinvgamma(K * p, shape = 1.0,
                             rate  = as.double(1.0 / psi_hs + beta^2 / (2.0 * tau2))),
                   K, p)
    lam2 <- pmax(lam2, 1e-8)
    
    psi_hs <- matrix(rinvgamma(K * p, shape = 1.0,
                               rate  = as.double(1.0 + 1.0 / lam2)),
                     K, p)
    psi_hs <- pmax(psi_hs, 1e-8)
    
    tau2 <- max(rinvgamma(1L, shape = (K * p + 1.0) / 2.0,
                          rate  = 1.0 / xi + 0.5 * sum(beta^2 / lam2)),
                1e-8)
    xi   <- max(rinvgamma(1L, shape = 1.0, rate = 1.0 + 1.0 / tau2), 1e-8)
    
    # ---- (e) Update cluster assignments  [Categorical, vectorised] ----------
    # log p(c[i]=k | ...) = log pi_k + log N(y[i]; X[i,]'beta[k,]+eta[i], sigma2)
    # The constant -0.5*log(2*pi*sigma2) is the same for all k and cancels.
    mu_mat    <- eta + X %*% t(beta)        # n x K:  col k = eta + X beta[k,]
    log_lk    <- -0.5 / sigma2 * (matrix(y, n, K) - mu_mat)^2   # n x K
    log_prob  <- sweep(log_lk, 2L, log(pi_dp + 1e-300), "+")
    c_asgn    <- rcat_rows(log_prob)
    n_k       <- tabulate(c_asgn, nbins = K)
    
    # ---- (f) Update stick-breaking weights  [Beta conjugate] ----------------
    # v_k | c, alpha ~ Beta(1 + n_k, alpha + sum_{j > k} n_j)
    cn_rev <- rev(cumsum(rev(n_k)))         # cn_rev[k] = sum_{j>=k} n_j
    for (k in seq_len(K - 1L)){
      v[k] <- rbeta(1L, 1.0 + n_k[k], alpha_dp + cn_rev[k + 1L])
    }
    v     <- pmin(pmax(v, 1e-6), 1.0 - 1e-6)
    pi_dp <- stick_break(v)
    
    # ---- (g) Update DP concentration alpha  [MH on log scale] ---------------
    # log p(alpha | v) = log Gamma(a,b) + (K-1)*log(alpha) + alpha*sum(log(1-v))
    lp_alpha <- function(a){
      if (a <= 0) -Inf
      else dgamma(a, a_alp, b_alp, log = TRUE) +
        (K - 1L) * log(a) + a * sum(log(1.0 - v)) + log(a)
    }
    
    a_pr <- exp(log(alpha_dp) + rnorm(1L, 0, 0.3))
    
    if (log(runif(1L)) < lp_alpha(a_pr) - lp_alpha(alpha_dp)){
      alpha_dp <- a_pr
    }
    
      
    
    # ---- (h) Update sigma^2  [InvGamma conjugate] ---------------------------
    # sigma^2 | rest ~ IG(a_sig + n/2,  b_sig + 0.5 * sum(residuals^2))
    res_full <- y - rowSums(X * beta[c_asgn, , drop = FALSE]) - eta
    sigma2   <- max(rinvgamma(1L, shape = a_sig + n / 2.0,
                              rate  = b_sig + 0.5 * sum(res_full^2)),
                    1e-8)
    
    # ---- Store posterior samples (after burn-in, respecting thinning) --------
    if (iter > n_burnin && (iter - n_burnin) %% n_thin == 0L) {
      ks <- ks + 1L
      SS$beta[ks, , ]  <- beta
      SS$c_asgn[ks, ]  <- c_asgn
      SS$f_gp[ks, ]    <- f_gp
      SS$eta[ks, ]     <- eta
      SS$pi_dp[ks, ]   <- pi_dp
      SS$sigma2[ks]    <- sigma2
      SS$sigma_gp[ks]  <- sigma_gp
      SS$ell_per[ks]   <- ell_per
      SS$ell_rbf[ks]   <- ell_rbf
      SS$tau2[ks]      <- tau2
      SS$alpha_dp[ks]  <- alpha_dp
    }
    
    if (verbose && iter %% freq == 0L) {
      el <- proc.time()["elapsed"] - t0
      cat(sprintf(
        "  iter %4d/%d | sigma2=%.4f | sgp=%.3f | lper=%.3f | lrbf=%.2f | K_eff=%2d | %.1fs\n",
        iter, n_iter, sigma2, sigma_gp, ell_per, ell_rbf, sum(n_k > 0), el))
    }
  } # end MCMC loop
  
  elapsed <- proc.time()["elapsed"] - t0
  cat(sprintf(
    "Done. %.1fs | MH acc: sgp=%.2f  lper=%.2f  lrbf=%.2f\n",
    elapsed, mh_acc[1L]/n_iter, mh_acc[2L]/n_iter, mh_acc[3L]/n_iter))
  
  SS$n_keep    <- ks
  SS$K         <- K;   SS$M <- M
  SS$hgp       <- hgp
  SS$dat       <- dat
  SS$mh_acc    <- setNames(mh_acc / n_iter, c("sigma_gp","ell_per","ell_rbf"))
  SS
}


# =============================================================================
# 5.  POST-PROCESSING HELPERS
# =============================================================================

# Posterior cluster membership probability matrix  (n x K)
# Loop over observations (not draws x clusters): each tabulate() call is fast.
posterior_cluster_probs <- function(fit) {
  K  <- fit$K;  n <- ncol(fit$c_asgn);  ns <- fit$n_keep
  pm <- matrix(0.0, n, K)
  for (i in seq_len(n))
    pm[i, ] <- tabulate(fit$c_asgn[seq_len(ns), i], nbins = K)
  pm / ns
}

# MAP cluster label for each observation  (breaks ties by first occurrence)
map_clusters <- function(fit) max.col(posterior_cluster_probs(fit),
                                      ties.method = "first")

# Posterior mean + 95 % credible interval for the fitted values
fitted_summary <- function(fit) {
  ns <- fit$n_keep;  n <- fit$dat$n;  dat <- fit$dat
  fmat <- matrix(0.0, ns, n)
  for (s in seq_len(ns))
    fmat[s, ] <- rowSums(dat$X * matrix(fit$beta[s, fit$c_asgn[s, ], ], 
                                        nrow = dat$n, ncol = dat$p)) +
    fit$eta[s, ]
  list(mean = colMeans(fmat),
       lo   = apply(fmat, 2L, quantile, 0.025),
       hi   = apply(fmat, 2L, quantile, 0.975))
}

# Tidy scalar-parameter summary
summarise_scalars <- function(fit) {
  ns <- fit$n_keep
  vars <- c("sigma2","sigma_gp","ell_per","ell_rbf","tau2","alpha_dp")
  out  <- lapply(vars, function(v) {
    x <- fit[[v]][seq_len(ns)]
    c(mean = mean(x), sd = sd(x),
      q025 = quantile(x, 0.025), q975 = quantile(x, 0.975))
  })
  as.data.frame(do.call(rbind, out), row.names = vars)
}

# Effective number of clusters per MCMC draw
n_clusters_trace <- function(fit)
  apply(fit$c_asgn[seq_len(fit$n_keep), ], 1L, function(r) length(unique(r)))

