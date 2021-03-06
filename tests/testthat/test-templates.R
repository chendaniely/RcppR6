context("pair")

test_that("pair", {
  pkg <- RcppR6:::prepare_temporary("testTemplates")
  RcppR6::install(pkg)
  devtools::document(pkg)
  expect_that(RcppR6::check(pkg), not(throws_error()))
  devtools::load_all(pkg)
  ## fresh=TRUE here would be nice, but can't happen.
  devtools::test(pkg)
  ## Should always clean up here, really.  Will go away when the
  ## tempdir issue does.
  unlink(pkg, recursive=TRUE)
})
