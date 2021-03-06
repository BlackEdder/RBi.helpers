#' @rdname output_to_proposal
#' @name output_to_proposal
#' @title Construct a proposal from run results
#' @description
#' This function takes the provided \code{\link{libbi}} which has been
#' run and returns a new model which has the proposal constructed from
#' the sample mean and standard deviation.
#' @param wrapper a \code{\link{libbi}} which has been run
#' @param scale a factor by which to scale all the standard deviations
#' @param correlations whether to take into account correlations
#' @param start whether this is the first attempt, in which case we'll use 1/10 of every bound, and 1 otherwise
#' @importFrom data.table setnames
#' @importFrom stats cov
#' @importFrom rbi get_block add_block
#' @return the updated bi model
#' @keywords internal
output_to_proposal <- function(wrapper, scale, correlations = FALSE, start = FALSE) {

  if (!wrapper$run_flag) {
    stop("The model should be run first")
  }

  model <- wrapper$model
  ## get constant expressions
  const_lines <- grep("^[[:space:]]*const", model[], value = TRUE)
  for (const_line in const_lines) {
    line <-
      gsub(" ", "", sub("^[[:space:]]*const[[:space:]]*", "", const_line))
    assignment <- strsplit(line, "=")[[1]]
    tryCatch(
    {
      assign(assignment[1], eval(parse(text = assignment[2])))
    },
    error = function(cond)
    {
      warning("Cannot convert const expression for ", assignemnt[1],
              "into R expression")
      warning("Original message: ", cond)
    })
  }
  for (block in c("parameter", "initial"))
  {
    ## get parameters
    param_block <- get_block(model, block)
    ## only go over variable parameters
    var_lines <- grep("~", param_block, value = TRUE)
    if (length(var_lines) > 0)
    {
      params <- sub("[[:space:]]*~.*$", "", var_lines)
      ## remove any dimensions
      params <- gsub("[[:space:]]*\\[[^]]*\\]", "", params)
      ## read parameters
      res <- bi_read(wrapper$output_file_name, vars = params)

      if (correlations) { ## adapt to full covariance matrix
        l <- list()
        for (param in names(res)) {
          y <- copy(res[[param]])
          ## extract columns that are dimensions
          unique_dims <- unique(y[setdiff(colnames(y), c("np", "value"))])
          if (sum(dim(unique_dims)) > 0)
          {
            ## for parameters with dimensions, create a parameter for each
            ## possible dimension(s)
            a <- apply(unique_dims, 1, function(x) {
              merge(t(x), y)
            })
            ## create correct parameter names (including the dimensions)
            if (length(a))
              names(a) <- unname(apply(unique_dims, 1, function(x) {
                paste0(param, "[", paste(rev(x), collapse = ","), "]")
              }))
          } else
          {
            a <- list(y)
            names(a) <- param
          }

          ## loop over all parameters (if dimensionsless, just the parameter,
          ## otherwise all possible dimensions) and remove all dimension columns
          a <- lapply(names(a), function(x) {
            for (col in colnames(unique_dims)) {
              a[[x]][[col]] <- NULL
            }
            data.table::setnames(a[[x]], "value", x)
          })
          l <- c(l, a)
        }

        ## create a wide table of all the parameters, for calculating
        ## covariances 
        wide <- l[[1]]
        if (length(l) > 1) {
          for (i in seq(2, length(l))) {
            wide <- merge(wide, l[[i]])
          }
        }
        wide[["np"]] <- NULL

        ## calculate the covariance matrix
        c <- stats::cov(wide)
        if (start) {
          c[, ] <- 0
        }

        ## calculate the vector of variances, and scaling of the mean
        sd_vec <- diag(c) - c[1, ]**2 / c[1, 1]
        mean_scale <- c[1, ] / c[1, 1]

        ## in case machine precision has made something < 0, set it to 0
        sd_vec[!(is.finite(sd_vec) & sd_vec > 0)] <- 0
        mean_scale[!(is.finite(mean_scale))] <- 0

        ## take square root of variances to get standard deviation
        sd_vec <- sqrt(sd_vec)
      } else {
        sd_vec <- vapply(params, function(p) {
          ifelse(length(res[[p]]) == 1, 0, sd(res[[p]]$value))
        }, 0)
      }

      if (missing(scale)) {
        scale_string <- ""
      } else {
        scale_string <- paste0(scale, " * ")
      }

      ## get prior density definition for each parameter
      param_bounds <- vapply(params, function(param) {grep(paste0("^[[:space:]]*", param, "[[[:space:]][^~]*~"), param_block, value = TRUE)}, "")
      ## select parameter that are variable (has a ~ in its prior line)
      variable_bounds <- param_bounds[vapply(param_bounds, function(x) {length(x) > 0}, TRUE)]

      proposal_lines <- c()

      first <- TRUE ## we're at the first parameter
      for (dim_param in names(sd_vec)) { ## loop over all parameters
        ## create dimensionless parameter
        param <- gsub("\\[[^]]*\\]", "", dim_param)
        ## check if it's variable
        if (param %in% names(variable_bounds[param]))
        {
          ## extract name of the parameter plus dimensions
          param_string <-
            sub(paste0("^[:space:]*(", param, "[^[:space:]~]*)[[:space:]~].*$"), "\\1", variable_bounds[param])
          ## extract bounded distribution split from parameters
          param_bounds_string <-
            sub("^.*(uniform|truncated_gaussian|truncated_normal|gamma|beta)\\((.*)\\)[[:space:]]*$",
                "\\1|\\2", variable_bounds[param])

          ## split distribution from arguments
          args <- strsplit(param_bounds_string, split = "\\|")
          ## extract distribution
          dist <- args[[1]][1]
          ## extract arguments to distribution
          bounds_string <- args[[1]][2]

          if (first) {
            ## first parameter; this is treated slightly different from the
            ## others in building up the multivariate normal distribution from
            ## interdependent univariate normal distributions
            mean <- ifelse(correlations, dim_param, param_string)
            if (correlations) {
              old_name <- "_old_mean_"
              proposal_lines <- paste("inline", old_name, "=", dim_param)
              sd <- sqrt(c[dim_param, dim_param])
            } else {
              sd <- sd_vec[[dim_param]]
            }
          } else {
            if (correlations) {
              mean <- paste0(dim_param, " + (", mean_scale[dim_param], ") * _old_mean_diff_")
            } else {
              mean <- param_string
            }
            sd <- sd_vec[[dim_param]]
          }

          ## impose bounds on gamma and beta distributions
          if (dist == "beta") {
            bounds_string <- "lower = 0, upper = 1"
          } else if (dist == "gamma") {
            bounds_string <- "lower = 0"
          }

          if (is.na(bounds_string) || bounds_string == variable_bounds[param]) {
            ## no bounds, just use a gaussian
            if (sd == 0) {
              sd <- 1
            }
            proposal_lines <-
              c(proposal_lines,
                paste0(ifelse(correlations, dim_param, param_string), " ~ gaussian(",
                       "mean = ", mean,
                       ", std = ", scale_string, sd, ")"))
          } else {
            ## there are (potentially) bounds, use a truncated normal
            bounds <- c(lower = NA, upper = NA)

            ## extract upper and lower bounds
            split_bounds <- strsplit(bounds_string, split = ",")[[1]]
            for (bound in c("lower", "upper")) {
              named <- grep(paste0(bound, "[[:space:]]*="), split_bounds)
              if (length(named) > 0) {
                bounds[bound] <- split_bounds[named]
                split_bounds <- split_bounds[-named]
              }
            }

            ## remove any arguments that don't pertain to bounds
            if (any(is.na(bounds))) {
              if (length(grep("^truncated", dist)) > 0) {
                named_other <- grep("(mean|std)", split_bounds)
                if (length(named_other) > 0) {
                  split_bounds <- split_bounds[-named_other]
                }
                if (length(named_other) < 2) {
                  split_bounds <- split_bounds[-seq_len(2 - length(named_other))]
                }
              }
            }

            ## get bounds
            for (split_bound in split_bounds) {
              bounds[which(is.na(bounds))][1] <- split_bound
            }

            ## get lower and upper bound
            bounds <- gsub("(lower|upper)[[:space:]]*=[[:space:]]*", "", bounds)
            bounds <- bounds[!is.na(bounds)]

            ## evaluate bounds (if they are given as expressions)
            eval_bounds <- tryCatch(
            {
              vapply(bounds, function(x) {as.character(eval(parse(text = x)))}, "")
            },
            error = function(cond)
            {
              warning("cannot convert bounds for ", param, "into r expression")
              warning("original message: ", cond)
              ret <- bounds
              ret[] <- NA
              return(ret)
            })
            bounds <- eval_bounds

            if (sd == 0) {
              ## no variation
              if (sum(!is.na(as.numeric(bounds))) == 2) {
                ## range / 10
                sd <- diff(as.numeric(bounds)) / 10
              } else {
                sd <- 1
              }
            } else {
              if (sum(!is.na(as.numeric(bounds))) == 2) {
                sd <- min(sd, diff(as.numeric(bounds)) / 10)
              }
            }

            ## construct proposal
            proposal_lines <- c(proposal_lines,
                                paste0(ifelse(correlations, dim_param, param_string),
                                       " ~ truncated_gaussian(",
                                       "mean = ", mean,
                                       ", std = ", scale_string, sd,
                                       ifelse(length(bounds) > 0,
                                              paste0(", ", paste(names(bounds), "=", bounds,
                                                                 sep = " ", collapse = ", "),
                                                     ")"),
                                              ")")))
          }

          if (first) {
            first <- FALSE
            if (correlations) {
              proposal_lines <- c(proposal_lines, paste("inline", "_old_mean_diff_", "=", dim_param, "-", "_old_mean_"))
            }
          }
        }
      }

      model <- add_block(model, name = paste0("proposal_", block), 
                         lines = proposal_lines)
    }
  }

  return(model)
}
