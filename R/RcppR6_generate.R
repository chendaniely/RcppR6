## This bit is tricky because it *must* be recursive; we're going to
## trigger writing in deeper and deeper parts of the tree.  For each
## level, we want to generate bits of template information that go in
## different places.
RcppR6_generate <- function(dat) {
  info <- RcppR6_package_info(dat$path)
  info$hash <- dat$hash

  tmp <- lapply(dat$classes, RcppR6_generate_class, info)

  collect <- function(name, dat, required=TRUE, collapse="\n") {
    if (required) {
      str <- vcapply(dat, "[[", name)
    } else {
      str <- unlist(lapply(dat, "[[", name))
    }
    paste(str, collapse=collapse)
  }

  info$forward_declaration <- collect("forward_declaration", tmp, FALSE)
  info$rcpp_prototypes     <- collect("rcpp_prototype",      tmp)
  info$rcpp_definitions    <- collect("rcpp_definition",     tmp)
  info$RcppR6_traits       <- collect("RcppR6_traits",       tmp)

  wr_data <- list(RcppR6=info$RcppR6, package=info)

  str_r_header   <- wr(info$templates$RcppR6.R_header,   wr_data)
  if (any(vlapply(dat$classes, "[[", "is_templated"))) {
    str_r_header <- paste(str_r_header,
                          info$templates$RcppR6_support.R,
                          sep="\n\n")
  }
  str_cpp_header <- wr(info$templates$RcppR6.cpp_header, wr_data)
  str_RcppR6.R   <- paste(str_r_header,
                          collect("r", tmp, collapse="\n\n"),
                          sep="\n\n")
  str_RcppR6.cpp <- paste(str_cpp_header,
                          collect("cpp", tmp, collapse="\n\n"),
                          sep="\n\n")

  ## Coming out, *all* we want is the generated code I think, rather
  ## than the intermediates.  It'd be pretty easy to also return the
  ## intermediates, but lets not for now as that leaves us free to
  ## rejig how those internals are kept.
  ##
  ## The package info bits are also required as they have the filename
  ## locations; they could be easily regenerated, alternatively.
  contents <- list(
    RcppR6.R           = str_RcppR6.R,
    RcppR6.cpp         = str_RcppR6.cpp,
    RcppR6_pre.hpp     = wr(info$templates$RcppR6_pre.hpp, wr_data),
    RcppR6_post.hpp    = wr(info$templates$RcppR6_post.hpp, wr_data),
    RcppR6_support.hpp = wr(info$templates$RcppR6_support.hpp, wr_data))
  list(package=info, contents=contents)
}

## TODO: lots of intermediate bits through here that can be simplified
## together; but the functions are pure now so that makes it easier to
## think about.
##
## The res / info / wr_data thing is very poorly thought though and
## may change completely soon.  Also, need to work out what the
## minimum amount of data to be returned is.
RcppR6_package_info <- function(path) {
  package_name <- package_name(path)
  paths <-
    list(root        = path,
         inst        = file.path(path, "inst"),
         include     = file.path(path, "inst/include"),
         include_pkg = file.path(path, "inst/include", package_name),
         r           = file.path(path, "R"),
         src         = file.path(path, "src"))
  files <- list(
    RcppR6.R           = file.path(paths$r,           "RcppR6.R"),
    RcppR6.cpp         = file.path(paths$src,         "RcppR6.cpp"),
    RcppR6_pre.hpp     = file.path(paths$include_pkg, "RcppR6_pre.hpp"),
    RcppR6_post.hpp    = file.path(paths$include_pkg, "RcppR6_post.hpp"),
    RcppR6_support.hpp = file.path(paths$include_pkg, "RcppR6_support.hpp"),
    package_include = file.path(paths$include, sprintf("%s.h", package_name)))

  ret <- list()
  ret$name      <- package_name
  ret$NAME      <- toupper(package_name)
  ret$paths     <- paths
  ret$files     <- files
  ret$templates <- RcppR6_read_templates()
  ret$RcppR6    <- RcppR6_RcppR6_info()
  ret
}

RcppR6_RcppR6_info <- function() {
  list(input_name="obj_",
       type_name="type",
       ## These should be constant, but would vary if using RC backend
       r_self_name="self",
       r_value_name="value",
       R6_ptr_name=".ptr",
       R6_generator_prefix=mangle_R6_generator(""),
       version=as.character(packageVersion(.packageName)))
}

RcppR6_generate_class <- function(dat, info) {
  if (dat$type == "class_ref") {
    RcppR6_generate_class_ref(dat, info)
  } else {
    RcppR6_generate_class_list(dat, info)
  }
}

## Here, consider farming out the templated types entirely.
RcppR6_generate_class_ref <- function(dat, info) {
  ret <- list()
  ret$name_r       <- dat$name_r
  ret$name_cpp     <- dat$name_cpp
  ret$name_safe    <- dat$name_safe
  ret$is_templated <- dat$is_templated
  ## This is only non-NULL for templated classes
  if (!is.null(dat$inherits)) {
    ret$inherits   <- mangle_R6_generator(dat$inherits)
  }

  ret$input_type   <- mangle_input(info$name, dat$name_cpp)
  ret$R6_generator <- mangle_R6_generator(dat$name_safe)
  ret$forward_declaration <- RcppR6_generate_forward_declaration(dat)

  if (ret$is_templated) {
    ## Need to push the template information in here...
    ret$templates <- dat$templates
    res_constructor <- RcppR6_generate_constructor(dat$constructor, info, ret)

    concrete <- lapply(ret$templates$concrete, function(x)
      RcppR6_generate_class_ref(x$class, info))

    keep <- c("r", "cpp",
              "RcppR6_traits",
              "rcpp_prototype",
              "rcpp_definition")
    ret[keep] <- lapply(keep, function(x)
      paste(vcapply(concrete, "[[", x), collapse="\n\n"))
    ret$r <- paste(res_constructor$r, ret$r, sep="\n\n")
  } else {
    res_constructor <- RcppR6_generate_constructor(dat$constructor, info, ret)
    res_methods <- lapply(dat$methods, RcppR6_generate_method,  info, ret)
    res_active  <- lapply(dat$active,  RcppR6_generate_active,  info, ret)

    join_r <- function(x, pre) {
      if (length(x) > 0L) {
        paste0(pre, indent(paste(x, collapse=",\n"), 6L))
      }
    }
    join_cpp <- function(x) {
      if (length(x) > 0L) {
        paste(x, collapse="\n")
      }
    }

    ret$methods_r <- join_r(vcapply(res_methods, "[[", "r"), ",\n")
    ret$active_r  <- join_r(vcapply(res_active,  "[[", "r"), "\n")

    ret$constructor_cpp <- res_constructor$cpp
    ret$methods_cpp <- join_cpp(vcapply(res_methods, "[[", "cpp"))
    ret$active_cpp  <- join_cpp(vcapply(res_active,  "[[", "cpp"))

    wr_data <- list(class=ret, package=info, RcppR6=info$RcppR6)
    ret$class_r <- wr(info$templates$R6_generator, wr_data)

    ## NOTE: using paste(c(...), collapse=.) rather than paste(..., sep=.)
    ## because it filters NULL values
    ret$r <- paste(c(res_constructor$r,
                     ret$class_r), collapse="\n")
    ret$cpp <- paste(c(ret$constructor_cpp,
                       ret$methods_cpp,
                       ret$active_cpp), collapse="\n")

    ## TODO: Rename
    ##   - rcpp_prototypes -> rcpp_prototype
    ##   - rcpp_definitions -> rcpp_definition
    ret$rcpp_prototype  <- wr(info$templates$rcpp_prototypes, wr_data)
    ret$rcpp_definition <- wr(info$templates$rcpp_definitions, wr_data)
    ret$RcppR6_traits   <- wr(info$templates$RcppR6_traits,    wr_data)
  }
  ret
}

RcppR6_generate_constructor <- function(dat, info, parent) {
  ret <- list()
  ret$roxygen <- RcppR6_generate_roxygen(dat$roxygen)
  ret$args <- RcppR6_generate_args(dat$args, info)

  if (parent$is_templated) {
    ret$types <- collapse(parent$templates$parameters)

    ## Valid template types:
    valid <- sapply(parent$templates$concrete, function(x)
                    dput_to_character(unname(x$parameters_r)))
    names(valid) <- vcapply(parent$templates$concrete, "[[", "name_r")
    ret$valid_r_repr <-
      sprintf("list(%s)", collapse(sprintf('"%s"=%s', names(valid), valid)))

    ## Don't use the strings here: we want the actual functions:
    ## TODO: Do this with switch() perhaps?
    ret$constructors_r_repr <-
      sprintf("list(%s)", collapse(sprintf('"%s"=`%s`',
                                           names(valid), names(valid))))
    wr_data <- list(constructor=ret, class=parent)
    ret$r <- wr(info$templates$R6_generator_generic,
                wr_data)
  } else {
    ret$name_cpp    <- dat$name_cpp
    ret$name_safe   <- mangle_constructor(parent$name_safe)
    ret$return_type <- parent$name_cpp
    wr_data <- list(constructor=ret, class=parent)
    ## TODO: Don't always use `` around the name; do that only if
    ## parse/deparse requires it (might be slower to check).
    ret$r <- wr(info$templates$constructor_r, wr_data)
    ret$cpp <- wr(info$templates$constructor_cpp, wr_data)
  }

  ret
}

RcppR6_generate_method <- function(dat, info, parent) {
  ret <- list()

  ret$name_r <- dat$name_r
  ret$name_cpp <- dat$name_cpp
  ret$name_safe <- mangle_method(parent$name_safe, dat$name_safe)

  ret$return_type <- dat$return_type
  ret$return_statement <- if (dat$return_type == "void") "" else "return "
  ret$is_member   <- dat$access == "member"
  ret$is_function <- dat$access == "function"

  ret$args <- RcppR6_generate_args(dat$args, info)

  wr_data <- list(RcppR6=info$RcppR6, method=ret)
  ret$r <- wr(info$templates$method_r, wr_data)
  ret$cpp <- drop_blank(wr(info$templates$method_cpp, wr_data))

  ret
}

RcppR6_generate_active <- function(dat, info, parent) {
  ret <- list()
  ret$name_r       <- dat$name_r
  ret$is_readonly  <- dat$readonly # NOTE change of name here

  ret$name_safe_get <- mangle_active(parent$name_safe, dat$name_safe, "get")
  if (dat$access == "field") {
    ret$name_cpp <- dat[["name_cpp"]]
  } else {
    ret$name_cpp_get  <- dat[["name_cpp"]]
  }
  if (!dat$readonly) {
    ret$name_safe_set <- mangle_active(parent$name_safe, dat$name_safe, "set")
    ret$name_cpp_set  <- dat[["name_cpp_set"]]
  }
  ret$input_type   <- mangle_input(info$name, parent$name_cpp)
  ret$class_name_r <- parent$name_r
  ret$return_type  <- dat$type
  ret$is_field     <- dat$access == "field"
  ret$is_member    <- dat$access == "member"
  ret$is_function  <- dat$access == "function"

  wr_data <- list(RcppR6=info$RcppR6, active=ret)
  ret$r   <- drop_blank(wr(info$templates$active_r,   wr_data))
  ret$cpp <- drop_blank(wr(info$templates$active_cpp, wr_data))

  ret
}

RcppR6_generate_args <- function(dat, info) {
  RcppR6 <- info$RcppR6
  is_constructor <- dat$parent_type == "constructor"
  is_member      <- dat$parent_type == "member"

  ret <- list()
  ## R:
  if (is.null(dat$defaults)) {
    ret$defn_r <- collapse(dat$names)
  } else {
    defn_r <- dat$names
    i <- !is.na(dat$defaults)
    defn_r[i] <- sprintf("%s=%s", dat$names[i], dat$defaults[i])
    ret$defn_r <- collapse(defn_r)
  }

  ret$body_r <- collapse(c(if (!is_constructor) RcppR6$r_self_name, dat$names))

  ## C++ details are harder:
  if (is_constructor) {
    types_cpp <- dat$types
    names_cpp <- dat$names
    body_cpp_prefix <- NULL
  } else {
    input_cpp <- mangle_input(info$name, dat$parent_class_name_cpp)
    types_cpp <- c(input_cpp,         dat$types)
    names_cpp <- c(RcppR6$input_name, dat$names)
    body_cpp_prefix <- if (!is_member) paste0("*", RcppR6$input_name)
  }
  ret$defn_cpp <- paste(types_cpp, names_cpp, collapse=", ")
  ret$body_cpp  <- collapse(c(body_cpp_prefix, dat$names))

  ret
}

RcppR6_generate_roxygen <- function(str) {
  if (length(str) > 0) {
    paste(paste0("##' ", strsplit(str, "\n", fixed=TRUE)[[1]]),
          collapse="\n")
  } else {
    ""
  }
}

RcppR6_generate_forward_declaration <- function(x) {
  if (x$forward_declare) {
    info <- guess_namespace(x$name_cpp)
    ns <- strsplit(info$namespace, "::", fixed=TRUE)[[1]]
    paste0(paste(sprintf("namespace %s { ", ns), collapse=""),
           sprintf("%s %s;", x$forward_declare_type, info$name),
           paste(rep(" }", length(ns)), collapse=""))
  } else {
    character(0)
  }
}

RcppR6_generate_roxygen <- function(str) {
  if (length(str) > 0) {
    paste(paste0("##' ", strsplit(str, "\n", fixed=TRUE)[[1]]),
          collapse="\n")
  } else {
    ""
  }
}

RcppR6_generate_class_list <- function(dat, info) {
  ret <- list()
  ret$name_r       <- dat$name_r
  ret$name_cpp     <- dat$name_cpp
  ret$name_safe    <- dat$name_safe
  ret$input_type   <- mangle_input(info$name, dat$name_cpp)
  ret$forward_declaration <- RcppR6_generate_forward_declaration(dat)

  ## Something like this will be needed if templating is allowed:
  ## ret$is_templated <- FALSE
  ## if (!is.null(dat$inherits)) {
  ##   ret$inherits   <- mangle_R6_generator(dat$inherits)
  ## }

  ## Copy along with generate_class_ref here.
  ## res_constructor <- RcppR6_generate_constructor(dat$constructor, info, ret)
  ## res_methods <- lapply(dat$methods, RcppR6_generate_method,  info, ret)
  ## res_active  <- lapply(dat$active,  RcppR6_generate_active,  info, ret)

  ret$validator_cpp <- dat$validator_cpp
  ret$constructor <- list(name_cpp=mangle_constructor(dat$name_safe),
                          name_r=dat$name_r,
                          roxygen=RcppR6_generate_roxygen(dat$roxygen))
  if (!is.null(ret$validator_cpp)) {
    ret$constructor$validator_cpp <- mangle_validator(dat$name_safe)
  }

  ret$fields <- whisker::iteratelist(dat$list,
                                     name="field_name",
                                     value="field_type")

  wr_data <- list(class=ret, package=info, RcppR6=info$RcppR6)

  ## NOTE: 'r' does not use wr_data
  ret$r <- drop_blank(wr(info$templates$list_generator, ret))
  ret$cpp <- drop_blank(wr(info$templates$constructor_list_cpp, wr_data))

  ret$rcpp_prototype  <- wr(info$templates$rcpp_prototypes, wr_data)
  ret$rcpp_definition <-
    drop_blank(wr(info$templates$rcpp_list_definitions, wr_data))
  ret$RcppR6_traits   <- wr(info$templates$RcppR6_traits, wr_data)

  ret
}
