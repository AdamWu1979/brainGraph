#' Bootstrapping for global graph measures
#'
#' Perform bootstrapping to obtain groupwise standard error estimates of a
#' global graph measure.
#'
#' The confidence intervals are calculated using the \emph{normal approximation}
#' at the \eqn{100 \times conf}\% level (by default, 95\%).
#'
#' For getting estimates of \emph{weighted global efficiency}, a method for
#' transforming edge weights must be provided. The default is to invert them.
#' See \code{\link{xfm.weights}}.
#'
#' @param densities Numeric vector of graph densities to loop through
#' @param resids An object of class \code{brainGraph_resids} (the output from
#'   \code{\link{get.resid}})
#' @param R Integer; the number of bootstrap replicates. Default: \code{1e3}
#' @param measure Character string of the measure to test. Default: \code{mod}
#' @param conf Numeric; the level for calculating confidence intervals. Default:
#'   \code{0.95}
#' @param .progress Logical indicating whether or not to show a progress bar.
#'   Default: \code{getOption('bg.progress')}
#' @inheritParams xfm.weights
#' @export
#'
#' @return \code{brainGraph_boot} -- an object of class \code{brainGraph_boot}
#'   containing some input variables, in addition to a list of
#'   \code{\link[boot]{boot}} objects (one for each group).
#'
#' @name Bootstrapping
#' @family Group analysis functions
#' @family Structural covariance network functions
#' @seealso \code{\link[boot]{boot}}, \code{\link[boot]{boot.ci}}
#' @author Christopher G. Watson, \email{cgwatson@@bu.edu}
#' @examples
#' \dontrun{
#' boot.E.global <- brainGraph_boot(densities, resids.all, 1e3, 'E.global')
#' }

brainGraph_boot <- function(densities, resids, R=1e3,
                            measure=c('mod', 'E.global', 'Cp', 'Lp', 'assortativity',
                                      'strength', 'mod.wt', 'E.global.wt'),
                            conf=0.95, .progress=getOption('bg.progress'),
                            xfm.type=c('1/w', '-log(w)', '1-w', '-log10(w/max(w))', '-log10(w/max(w)+1)')) {
  stopifnot(inherits(resids, 'brainGraph_resids'))
  if (!requireNamespace('boot', quietly=TRUE)) stop('Must install the "boot" package.')

  # 'statistic' function for the bootstrapping process
  statfun <- function(x, i, measure, res.obj, xfm.type) {
    corrs <- corr.matrix(res.obj[i], densities=densities, rand=TRUE)
    if (measure %in% c('strength', 'mod.wt', 'E.global.wt')) {
      g.boot <- apply(corrs[[1L]]$r.thresh, 3L, function(y)
                      graph_from_adjacency_matrix(corrs[[1L]]$R * y, mode='undirected',
                                                  diag=FALSE, weighted=TRUE))
    } else {
      g.boot <- apply(corrs[[1L]]$r.thresh, 3L, graph_from_adjacency_matrix,
                      mode='undirected', diag=FALSE)
    }
    res <- switch(measure,
        mod=, mod.wt=vapply(g.boot, function(y) max(cluster_louvain(y)$modularity), numeric(1L)),
        E.global=vapply(g.boot, efficiency, numeric(1L), 'global'),
        E.global.wt=vapply(g.boot, function(g) efficiency(xfm.weights(g, xfm.type), 'global'), numeric(1L)),
        Cp=vapply(g.boot, transitivity, numeric(1L), type='localaverage'),
        Lp=vapply(g.boot, mean_distance, numeric(1L)),
        assortativity=vapply(g.boot, assortativity_degree, numeric(1L)),
        strength=vapply(g.boot, function(y) mean(strength(y)), numeric(1L)))
    return(res)
  }

  # Show a progress bar so you aren't left in the dark
  intfun <- statfun
  if (isTRUE(.progress)) {
    intfun <- function(data, indices, measure, res.obj, xfm.type) {
      curVal <- get('counter', envir=env) + ncpus
      assign('counter', curVal, envir=env)
      setTxtProgressBar(get('progbar', envir=env), curVal)
      flush.console()
      statfun(data, indices, measure, res.obj, xfm.type)
    }
  }

  ncpus <- getOption('bg.ncpus')
  if (.Platform$OS.type == 'windows') {
    my.parallel <- 'snow'
    cl <- makeCluster(ncpus, type='SOCK')
    clusterEvalQ(cl, library(brainGraph))
  } else {
    my.parallel <- 'multicore'
    cl <- NULL
  }

  measure <- match.arg(measure)
  xfm.type <- match.arg(xfm.type)
  env <- environment()
  grps <- unique(groups(resids))
  my.boot <- setNames(vector('list', length(grps)), grps)
  for (g in grps) {
    counter <- 0
    res.dt <- resids$resids.all[g]
    if (isTRUE(.progress)) progbar <- txtProgressBar(min=0, max=R, style=3)
    my.boot[[g]] <- boot::boot(res.dt, intfun, measure=measure, res.obj=resids[g], xfm.type=xfm.type, R=R,
                         parallel=my.parallel, ncpus=ncpus, cl=cl)
    if (isTRUE(.progress)) close(progbar)
  }

  out <- list(measure=measure, densities=densities, Group=grps, conf=conf, boot=my.boot)
  class(out) <- c('brainGraph_boot', class(out))
  return(out)
}

#' Print a summary from a bootstrap analysis
#'
#' @param object,x A \code{brainGraph_boot} object
#' @export
#' @rdname Bootstrapping

summary.brainGraph_boot <- function(object, ...) {
  if (!requireNamespace('boot', quietly=TRUE)) stop('Must install the "boot" package.')
  kNumDensities <- length(object$densities)
  # Get everything into a data.table
  boot.dt <- with(object,
                  data.table(Group=rep(Group, each=kNumDensities),
                             density=rep.int(densities, length(Group)),
                             Observed=c(vapply(boot, with, numeric(kNumDensities), t0)),
                             se=c(vapply(boot, function(x) apply(x$t, 2L, sd), numeric(kNumDensities)))))
  setnames(boot.dt, 'Group', getOption('bg.group'))
  ci <- with(object,
             vapply(seq_along(densities), function(x)
                    vapply(boot, function(y)
                           boot::boot.ci(y, type='norm', index=x, conf=conf)$normal[2L:3L],
                           numeric(2L)),
                    numeric(2L * length(Group))))
  boot.dt$ci.low <- c(t(ci[2L * (seq_along(object$Group) - 1L) + 1L, ]))
  boot.dt$ci.high <- c(t(ci[2L * (seq_along(object$Group) - 1L) + 2L, ]))

  meas.full <- switch(object$measure,
                      mod='Modularity', mod.wt='Modularity (weighted)',
                      E.global='Global efficiency', E.global.wt='Global efficiency (weighted)',
                      Cp='Clustering coefficient',
                      Lp='Average shortest path length',
                      assortativity='Degree assortativity',
                      strength='Average strength')
  boot.sum <- list(meas.full=meas.full, DT.sum=boot.dt, conf=object$conf, R=object$boot[[1L]]$R)
  class(boot.sum) <- c('summary.brainGraph_boot', class(boot.sum))
  boot.sum
}

#' @aliases summary.brainGraph_boot
#' @method print summary.brainGraph_boot
#' @export

print.summary.brainGraph_boot <- function(x, ...) {
  print_title_summary('Bootstrap analysis')
  cat('Graph metric: ', x$meas.full, '\n')
  cat('Number of bootstrap samples generated: ', x$R, '\n')
  conf.pct <- 100 * x$conf
  cat(conf.pct, '% confidence intervals\n\n')
  print(x$DT.sum)
  invisible(x)
}

#' Plot bootstrap output of global graph measures across densities
#'
#' The \code{plot} method returns two \code{ggplot} objects: one with shaded
#' regions based on the standard error, and the other based on confidence
#' intervals (calculated using the normal approximation).
#'
#' @param ... Unused
#' @param alpha A numeric indicating the opacity for the confidence bands
#' @export
#' @rdname Bootstrapping
#'
#' @return \code{plot} -- \emph{list} with the following elements:
#'   \item{se}{A ggplot object with ribbon representing standard error}
#'   \item{ci}{A ggplot object with ribbon representing confidence intervals}

plot.brainGraph_boot <- function(x, ..., alpha=0.4) {
  Observed <- se <- ci.low <- ci.high <- NULL
  gID <- getOption('bg.group')

  boot.sum <- summary(x)
  boot.dt <- boot.sum$DT.sum

  # 'base' plotting
  if (!requireNamespace('ggplot2', quietly=TRUE)) {
    grps <- boot.dt[, unique(get(gID))]

    par(mfrow=c(2L, 1L))
    # 1. SE plot
    ymin <- boot.dt[, min(Observed - se)]
    ymax <- boot.dt[, max(Observed + se)]
    boot.dt[get(gID) == grps[1L],
            plot(density, Observed, type='l', col=plot.cols[1L],
                 ylim=c(ymin, ymax), ylab=boot.sum$meas.full)]
    boot.dt[get(gID) == grps[2L],
            lines(density, Observed, col=plot.cols[2L])]
    for (i in 1L:2L) {
      boot.dt[get(gID) == grps[i],
              polygon(x=c(density, rev(density)),
                      y=c(Observed + se, rev(Observed - se)),
                      col=adjustcolor(plot.cols[i], alpha.f=alpha),
                      border=plot.cols[i])]
    }
    legend('topright', title=gID, grps, fill=plot.cols[1L:2L])

    # 2. CI plot
    ymin <- boot.dt[, min(ci.low)]
    ymax <- boot.dt[, max(ci.high)]
    boot.dt[get(gID) == grps[1L],
            plot(density, Observed, type='l', col=plot.cols[1L],
                 ylim=c(ymin, ymax), ylab=boot.sum$meas.full)]
    boot.dt[get(gID) == grps[2L],
            lines(density, Observed, col=plot.cols[2L])]
    for (i in 1L:2L) {
      boot.dt[get(gID) == grps[i],
              polygon(x=c(density, rev(density)),
                      y=c(ci.high, rev(ci.low)),
                      col=adjustcolor(plot.cols[i], alpha.f=alpha),
                      border=plot.cols[i])]
    }
    legend('topright', title=gID, grps, fill=plot.cols[1L:2L])
    return(invisible(x))

  # 'ggplot2' plotting
  } else {
    b <- ggplot2::ggplot(boot.dt, ggplot2::aes(x=density, y=Observed, col=get(gID))) +
      ggplot2::geom_line() +
      ggplot2::labs(y=boot.sum$meas.full)
    se <- b + ggplot2::geom_ribbon(ggplot2::aes(ymin=Observed-se, ymax=Observed+se, fill=get(gID)), alpha=alpha)
    ci <- b + ggplot2::geom_ribbon(ggplot2::aes(ymin=ci.low, ymax=ci.high, fill=get(gID)), alpha=alpha)
    return(list(se=se, ci=ci))
  }
}
