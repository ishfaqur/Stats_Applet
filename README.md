# Bayesian Traffic Speed Analysis with Dirichlet Process Mixture & HSGP

A sophisticated Bayesian model for analyzing traffic speed time series data using Dirichlet Process mixture models combined with locally-periodic Gaussian Processes, implemented with computationally efficient Hilbert Space approximation.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![R](https://img.shields.io/badge/R-%3E%3D%204.0-blue)](https://www.r-project.org/)

## 🎮 [Try the Interactive Demo →](https://YOUR-USERNAME.github.io/traffic-dp-gp-model/)

**NEW!** Explore the model interactively in your browser. No installation required - adjust parameters and see results in real-time!

## Overview

This repository implements a state-of-the-art Bayesian model for traffic speed analysis that:

- 🚗 **Automatically discovers traffic regimes** (e.g., morning rush, evening rush, free flow) without pre-labeling using Dirichlet Process mixtures
- 📊 **Captures daily periodic patterns** with a locally-periodic Gaussian Process
- ⚡ **Scales efficiently** to large datasets via Hilbert Space GP (HSGP) approximation
- 🎯 **Provides uncertainty quantification** through full Bayesian inference
- 🔍 **Handles covariates** (weekday/weekend, holidays, etc.) with horseshoe priors for sparsity

## Model Description

### Mathematical Formulation

The model decomposes traffic speed into three components:

```
y(t) = X(t)' β[c(t)] + η(t) + ε(t)
```

Where:
- **y(t)**: log(speed(t) / reference_speed) - normalized log-speed
- **X(t)' β[c(t)]**: Regime-specific regression (cluster assignment c(t))
- **η(t)**: Gaussian Process capturing smooth temporal patterns
- **ε(t)**: Observation noise ~ N(0, σ²)

### Key Components

#### 1. **Dirichlet Process Mixture Model**
- Uses stick-breaking construction for automatic regime discovery
- Number of clusters determined by the data (not pre-specified)
- Each regime has its own regression coefficients β[k]

#### 2. **Locally-Periodic Gaussian Process**
The GP uses a product kernel combining periodicity with local smoothness:

```
k(τ) = σ_GP² × exp(-2sin²(πτ/T) / ℓ_per²) × exp(-τ² / (2ℓ_RBF²))
       └─────── Periodic component ────┘   └── RBF envelope ──┘
```

- Captures daily cycles (rush hours, off-peak patterns)
- Local envelope allows patterns to evolve over time

#### 3. **Hilbert Space GP (HSGP) Approximation**
- Reduces computational complexity from O(n³) to O(nM + M³)
- Uses spectral decomposition of the kernel
- Fourier-Bessel expansion for the periodic component

#### 4. **Horseshoe Prior**
- Encourages sparsity in regression coefficients
- Automatically determines which covariates are important
- Adaptive shrinkage (strong for irrelevant, weak for relevant features)

## Repository Structure

```
.
├── index.html                          # 🎮 Interactive web visualizer (NEW!)
├── HSGP_StickBreakingCode.R           # Core model implementation
├── Diagnostics_n_Visualization.R       # Diagnostic plots and summaries
├── RealTest_HSGP.R                     # Example with real data
├── run_simulation.R                    # Example with simulated data
├── Input_for_HSGP__1_.RData           # (Your real data file - not included)
├── README.md                           # This file
├── DEPLOYMENT_GUIDE.md                 # How to deploy the interactive applet
└── [Other documentation files...]
```

**🎮 Interactive Applet Features:**
- Real-time parameter adjustment
- 5 visualization modes (time series, clusters, GP, distributions, spectral)
- Works completely offline
- Mobile-friendly responsive design
- No dependencies - pure HTML/CSS/JavaScript

## Installation

### Prerequisites

- R >= 4.0
- RStudio (recommended)

### Required R Packages

```r
install.packages(c("coda", "ggplot2", "dplyr", "tidyr"))
```

All packages are automatically installed when you run the main script.

## Quick Start

### Option 1: Using Simulated Data (Recommended for Testing)

```r
# Set working directory to where you saved the files
setwd("path/to/repo")

# Run the simulation
source("run_simulation.R")
```

This will:
1. Generate 30 days of synthetic traffic data (2,880 observations)
2. Fit the Bayesian model (~5-10 minutes)
3. Generate comprehensive diagnostic plots
4. Save results to `simulation_results.RData`

### Option 2: Using Your Own Data

Prepare your data as follows:

```r
# Load your traffic data
# Required columns: speed, reference_speed, daytype, seq_id

source("HSGP_StickBreakingCode.R")

# Prepare data object
dat <- list(
  y = log(your_data$speed / your_data$reference_speed),
  X = model.matrix(~ daytype, data = your_data),
  t = your_data$seq_id / 96,  # Time in days (96 = 15-min intervals/day)
  n = nrow(your_data),
  p = 2,  # Number of predictors (intercept + weekend)
  T_per = 1,  # Period = 1 day
  ipd = 96    # Intervals per day
)

# Fit model
fit <- fit_dp_gp(
  dat = dat,
  K = 5L,           # Maximum clusters
  M = 250L,         # HSGP basis functions
  n_iter = 20000L,  # MCMC iterations
  n_burnin = 10000L,
  n_thin = 2L,
  verbose = TRUE
)

# Generate diagnostics
source("Diagnostics_n_Visualization.R")
```

## Model Parameters

### Main Function: `fit_dp_gp()`

| Parameter | Default | Description |
|-----------|---------|-------------|
| `dat` | - | Data list (see structure above) |
| `K` | 5 | Maximum number of clusters |
| `M` | 250 | Number of HSGP basis functions |
| `n_iter` | 20000 | Total MCMC iterations |
| `n_burnin` | 10000 | Burn-in period |
| `n_thin` | 2 | Thinning interval |
| `bf` | 1.5 | Boundary factor for HSGP |
| `n_harm` | 8 | Harmonics for periodic kernel |
| `verbose` | TRUE | Print progress |
| `freq` | 500 | Progress update frequency |

### Prior Hyperparameters (Advanced)

```r
fit_dp_gp(
  dat = dat,
  # ... basic parameters ...
  a_sig = 2.0,      # InvGamma shape for σ²
  b_sig = 0.05,     # InvGamma rate for σ²
  a_alp = 2.0,      # Gamma shape for DP concentration
  b_alp = 1.0,      # Gamma rate for DP concentration
  sc_sgp = 0.5,     # Half-Cauchy scale for σ_GP
  sc_lper = 1.0,    # Half-Cauchy scale for ℓ_per
  sc_lrbf = 10.0,   # Half-Cauchy scale for ℓ_RBF
  # Initial values
  sgp0 = 0.15,
  lper0 = 1.0,
  lrbf0 = 3.0,
  # Metropolis-Hastings tuning
  mh_sgp = 0.25,
  mh_lper = 0.25,
  mh_lrbf = 0.30
)
```

## Diagnostic Outputs

The `Diagnostics_n_Visualization.R` script generates:

1. **Trace Plots** - MCMC convergence for σ², σ_GP, ℓ_per, ℓ_RBF, τ², α_DP
2. **Effective Sample Sizes** - MCMC efficiency diagnostics
3. **Fitted Values Plot** - Model predictions with 95% credible intervals, colored by cluster
4. **GP Component Plot** - Temporal smooth component η(t)
5. **Cluster Membership Heatmap** - Posterior probabilities over time
6. **Beta Posteriors** - Regime-specific coefficient distributions
7. **Spectral Density Plot** - GP frequency decomposition
8. **Posterior Predictive Check** - Model adequacy assessment

## Example Results

### Typical Output (Simulated Data)

```
=== Posterior scalar summaries ===
             mean      sd    q025    q975
sigma2     0.0016  0.0001  0.0014  0.0018
sigma_gp   0.1195  0.0089  0.1030  0.1377
ell_per    0.8043  0.0521  0.7091  0.9123
ell_rbf    3.0245  0.2134  2.6234  3.4589
tau2       0.0234  0.0156  0.0089  0.0598
alpha_dp   1.8734  0.4521  1.0923  2.8456

Effective number of clusters: 3.2 (±0.4)
True number of regimes: 3
```

### Computational Performance

- **Dataset**: 2,880 observations (30 days × 96 intervals/day)
- **MCMC**: 20,000 iterations (10,000 burn-in, thinning=2)
- **Runtime**: ~5-10 minutes on standard laptop
- **Memory**: ~500 MB

## Methodology Details

### Computational Strategy

1. **HSGP Efficiency**: Pre-compute Φ'Φ (M×M) once; only diagonal updates needed
2. **Vectorized Sampling**: Cluster assignments use cumulative-sum trick (no R loop)
3. **Blocked Updates**: β[k] updated via Cholesky solve (dimension = #predictors, typically 1-4)
4. **Conjugate Updates**: Most parameters (σ², λ, τ², v) have closed-form conditionals
5. **Adaptive MH**: GP hyperparameters updated on log-scale with tunable step sizes

### Theoretical Background

This implementation is based on:

- **HSGP**: Riutort-Mayol et al. (2023). "Practical Hilbert space approximate Bayesian Gaussian processes for probabilistic programming"
- **Horseshoe**: Makalic & Schmidt (2016). "A simple sampler for the horseshoe estimator"
- **Stick-breaking**: Sethuraman (1994). "A constructive definition of the Dirichlet process"
- **Locally-periodic kernels**: Theory from Rasmussen & Williams (2006), spectral methods

## Advanced Usage

### Custom Predictors

Add more covariates beyond intercept and weekend:

```r
# Example: intercept + weekend + hourly sine/cosine
X <- model.matrix(~ daytype + I(sin(2*pi*hour/24)) + I(cos(2*pi*hour/24)), 
                  data = your_data)
```

### Sensitivity Analysis

Test prior sensitivity:

```r
# Informative prior
fit1 <- fit_dp_gp(dat, a_sig=3, b_sig=0.1, sc_lrbf=5.0)

# Diffuse prior
fit2 <- fit_dp_gp(dat, a_sig=1, b_sig=0.01, sc_lrbf=20.0)

# Compare posteriors
rbind(
  summarise_scalars(fit1),
  summarise_scalars(fit2)
)
```

### Model Comparison

```r
# Different cluster limits
fit_K3 <- fit_dp_gp(dat, K=3L)
fit_K5 <- fit_dp_gp(dat, K=5L)
fit_K10 <- fit_dp_gp(dat, K=10L)

# Compare effective clusters
mean(n_clusters_trace(fit_K3))
mean(n_clusters_trace(fit_K5))
mean(n_clusters_trace(fit_K10))
```

## Troubleshooting

### Common Issues

**Problem**: MCMC not converging (trace plots show trends)
- **Solution**: Increase `n_burnin` to 15000-20000
- Check: Effective sample sizes should be >200

**Problem**: Too many/few clusters
- **Solution**: Adjust `a_alp` and `b_alp` (higher α → more clusters)
- Try: `a_alp=1.0, b_alp=2.0` for fewer clusters

**Problem**: Low MH acceptance rates (<15%)
- **Solution**: Reduce `mh_sgp`, `mh_lper`, `mh_lrbf` by 30-50%
- Target: 20-40% acceptance

**Problem**: Memory issues with large datasets
- **Solution**: Reduce `M` (basis functions) to 150-200
- Or: Increase `n_thin` to save fewer samples

## Performance Tips

1. **Start small**: Test with `n_iter=5000` first
2. **Tune MH steps**: Aim for 20-40% acceptance rates
3. **Parallel chains**: Run multiple chains in separate R sessions
4. **Save results**: Always `save(fit, file="results.RData")` for long runs

## Citation

If you use this code in your research, please cite:

```bibtex
@software{traffic_dp_gp,
  title = {Bayesian Traffic Speed Analysis with Dirichlet Process Mixture and HSGP},
  year = {2025},
  url = {https://github.com/yourusername/traffic-dp-gp}
}
```

## License

MIT License - see LICENSE file for details

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## Contact

For questions or issues, please open a GitHub issue.

## Acknowledgments

- Hilbert Space GP implementation inspired by the Stan team's work
- Traffic data structure based on common ITS data formats
- MCMC diagnostics use the excellent `coda` package

---

**Note**: This is research-grade code. Always validate results against domain knowledge and check MCMC convergence diagnostics before drawing conclusions.
