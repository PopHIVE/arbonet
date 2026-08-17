# =============================================================================
# ArboNET — historic county-level human disease cases for six domestic
# arboviruses. Source: CDC ArboNET, via the disease-specific historic-data
# dashboards.
#
# The dashboard pages are JavaScript visualizations with no download endpoint,
# but each is backed by a flat CSV under www.cdc.gov/wcms/vizdata/. Those URLs
# were resolved from the `dataUrl` field of each page's cdc-open-viz config
# JSON (e.g. /west-nile-virus/data-maps/explore-yearly-county-data.json), and
# are what this script reads -- nothing is scraped.
#
# www.cdc.gov sits behind Akamai and answers most non-browser clients with a
# 403; download.file(method = "libcurl") gets through where httr and plain
# curl do not.
#
# Two traps worth knowing about. (1) Five of the six files mix per-year rows
# with a pre-aggregated all-years row whose Year holds a range ("2003-2025");
# keeping both double-counts every case. (2) The WNV file names its case
# column "Reported human cases" while the others use "Total human disease
# cases", and it carries an extra blood-donor column. Columns are therefore
# resolved by pattern, and an ambiguous match is an error rather than a
# silently dropped measure.
#
# Verified: county sums reproduce CDC's published state totals exactly (e.g.
# Jamestown Canyon 362 cases 2011-2025, matching all 25 states individually),
# and national totals reconcile against CDC's separately published cumulative
# file once Connecticut (which CDC blanks there but publishes yearly) and the
# unallocated codes are accounted for.
# =============================================================================

library(dplyr)

# One row per disease. `code` becomes the middle segment of every output column
# name (arbonet_<code>_<measure>). This table is the source definition; the
# rest of the script derives from it.
sources <- tibble::tribble(
  ~code, ~url,
  "wnv", "https://www.cdc.gov/wcms/vizdata/live/ncezid_dvbd/WNV/wnv_hist_hum_nonhum_yearly.csv",
  "eee", "https://www.cdc.gov/wcms/vizdata/live/ncezid_dvbd/EEE/eee_hist_hum_nonhum.csv",
  "jcv", "https://www.cdc.gov/wcms/vizdata/live/ncezid_dvbd/JCV/jcv_hist_hum_nonhum.csv",
  "lac", "https://www.cdc.gov/wcms/vizdata/live/ncezid_dvbd/LAC/lac_hist_hum_nonhum.csv",
  "sle", "https://www.cdc.gov/wcms/vizdata/live/ncezid_dvbd/SLE/sle_hist_hum_nonhum.csv",
  "pow", "https://www.cdc.gov/wcms/vizdata/live/ncezid_dvbd/POW/pow_hist_hum_nonhum.csv"
)

# The canonical PopHIVE geography crosswalk, read from Ingest rather than
# vendored here, so this repo stays in step with it.
FIPS_URL <- "https://raw.githubusercontent.com/PopHIVE/Ingest/main/resources/all_fips.csv.gz"

dir.create("raw", showWarnings = FALSE)
dir.create("standard", showWarnings = FALSE)

# --- 1. Download raw data ----------------------------------------------------
sources$raw_path <- file.path("raw", paste0(sources$code, "_county.csv"))
for (i in seq_len(nrow(sources))) {
  download.file(sources$url[i], sources$raw_path[i],
                method = "libcurl", mode = "wb", quiet = TRUE)
}

raw_md5 <- setNames(
  vapply(sources$raw_path, function(p) unname(tools::md5sum(p)), character(1)),
  sources$code
)
fingerprint <- paste(names(raw_md5), raw_md5, sep = "=", collapse = ";")

previous <- if (file.exists("process.json")) jsonlite::fromJSON("process.json") else list()

# --- 2. Only rebuild when the upstream files have changed --------------------
if (identical(previous$fingerprint, fingerprint)) {
  message("ArboNET data is up to date; nothing to rebuild")
} else {

  # --- 3. Reference geography ------------------------------------------------
  fips_path <- file.path("raw", "all_fips.csv.gz")
  download.file(FIPS_URL, fips_path, method = "libcurl", mode = "wb", quiet = TRUE)
  all_fips <- vroom::vroom(fips_path, show_col_types = FALSE)
  valid_county <- all_fips$geography[nchar(all_fips$geography) == 5]

  # Resolve a column by pattern, erroring on an ambiguous or missing match so
  # an upstream rename fails loudly instead of quietly dropping a measure.
  pick_col <- function(nms, pattern, exclude = NULL, required = TRUE, label = pattern) {
    hits <- grep(pattern, nms, ignore.case = TRUE, value = TRUE)
    if (!is.null(exclude)) hits <- hits[!grepl(exclude, hits, ignore.case = TRUE)]
    if (length(hits) == 1) return(hits)
    if (length(hits) == 0 && !required) return(NA_character_)
    stop(sprintf("expected exactly one '%s' column, found %d: %s",
                 label, length(hits), paste(hits, collapse = ", ")))
  }

  # NA-preserving aggregates: a geography whose every input row is missing
  # stays missing, rather than collapsing to 0 and implying a true zero count.
  sum_na <- function(x) if (all(is.na(x))) NA_real_ else sum(x, na.rm = TRUE)
  max_na <- function(x) if (all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)

  # --- 4. Read and normalize each disease file into a common long shape ------
  read_disease <- function(code, raw_path) {
    d <- vroom::vroom(raw_path, col_types = vroom::cols(.default = "c"))
    nms <- names(d)

    col_year     <- pick_col(nms, "^Year$",         label = "year")
    col_geo      <- pick_col(nms, "^County$",       label = "county")
    col_activity <- pick_col(nms, "^Activity$",     label = "activity")
    col_neuro    <- pick_col(nms, "^Neuroinvasive", label = "neuroinvasive cases")
    col_cases    <- pick_col(nms, "human.*cases",
                             exclude = "neuroinvasive", label = "human cases")
    col_donors   <- pick_col(nms, "blood donor", required = FALSE,
                             label = "blood donor screening")

    out <- tibble::tibble(
      geography = d[[col_geo]],
      year_raw  = d[[col_year]],
      activity  = d[[col_activity]],
      cases     = as.numeric(d[[col_cases]]),
      neuro     = as.numeric(d[[col_neuro]]),
      donors    = if (is.na(col_donors)) NA_real_ else as.numeric(d[[col_donors]])
    )

    # Drop the pre-aggregated all-years rows (Year holds a range).
    out <- out[!grepl("-", out$year_raw), ]

    # "Data unavailable" marks a geography CDC did not report that year
    # (notably Connecticut, which moved from counties to planning regions in
    # 2022). Those rows carry blank counts and must stay missing, not zero.
    unavailable <- grepl("data unavailable", out$activity, ignore.case = TRUE)

    # Non-human activity = veterinary cases or infections found in mosquitoes,
    # birds, or sentinel animals, per the dashboard legend.
    nonhuman <- as.numeric(grepl("non-human", out$activity, ignore.case = TRUE))
    nonhuman[unavailable] <- NA_real_
    # Powassan's dashboard reports human cases only, so no row ever carries a
    # non-human category. Leave the measure missing rather than asserting an
    # absence of activity that was never surveilled.
    if (all(nonhuman == 0, na.rm = TRUE)) nonhuman <- NA_real_

    out %>%
      mutate(
        disease           = code,
        time              = paste0(year_raw, "-12-31"),
        cases             = if_else(unavailable, NA_real_, cases),
        neuro_cases       = if_else(unavailable, NA_real_, neuro),
        blood_donors      = if_else(unavailable, NA_real_, donors),
        nonhuman_activity = nonhuman
      ) %>%
      select(geography, time, disease,
             cases, neuro_cases, nonhuman_activity, blood_donors)
  }

  long <- bind_rows(Map(read_disease, sources$code, sources$raw_path))

  # --- 5. Separate true counties from unallocated records --------------------
  # A few records use a placeholder code (state FIPS + 999) for cases whose
  # county of residence is unknown. Those are not counties, so they are held
  # out of the county rows, but they stay in the state and national rollups so
  # those totals still match CDC's published figures.
  is_county <- long$geography %in% valid_county
  unknown <- long %>%
    filter(!is_county, !is.na(cases) | !is.na(neuro_cases)) %>%
    distinct(geography) %>%
    pull(geography)
  if (length(unknown)) {
    message(sprintf(
      "held %d unallocated geography code(s) out of the county rows (retained in state/national totals): %s",
      length(unknown), paste(sort(unknown), collapse = ", ")))
  }

  widen <- function(x) {
    out <- tidyr::pivot_wider(
      x,
      names_from  = disease,
      values_from = c(cases, neuro_cases, nonhuman_activity, blood_donors),
      names_glue  = "arbonet_{disease}_{.value}"
    )
    # Blood-donor screening applies to West Nile virus only, and Powassan has
    # no non-human surveillance, so the pivot yields some entirely empty
    # columns. Drop them so the schema matches what is actually measured.
    keep <- names(out)[!names(out) %in% c("geography", "time")]
    keep <- keep[vapply(out[keep], function(v) !all(is.na(v)), logical(1))]
    out %>%
      select(geography, time, all_of(sort(keep))) %>%
      arrange(geography, time)
  }

  # --- 6. State and national rollups ----------------------------------------
  # Counts sum across geographies. The non-human activity indicator is a flag,
  # so it rolls up as "any constituent geography reported activity".
  roll_up <- function(x, group_geo) {
    x %>%
      mutate(geography = group_geo) %>%
      group_by(geography, time, disease) %>%
      summarize(
        cases             = sum_na(cases),
        neuro_cases       = sum_na(neuro_cases),
        blood_donors      = sum_na(blood_donors),
        nonhuman_activity = max_na(nonhuman_activity),
        .groups = "drop"
      )
  }

  state_long <- roll_up(long, substr(long$geography, 1, 2))
  national_long <- roll_up(state_long, "00")

  # The county file carries the national row alongside the counties so county
  # series can be charted against the national trend from one file. The levels
  # stay distinguishable by the width of `geography` ("00" national, 5-digit
  # county), so filter by that before summing across rows.
  data_county <- widen(bind_rows(long[is_county, ], national_long))
  data_state <- widen(bind_rows(state_long, national_long))

  # --- 7. Validate before writing -------------------------------------------
  for (nm in c("data_county", "data_state")) {
    d <- get(nm)
    dup <- sum(duplicated(d[c("geography", "time")]))
    if (dup > 0) stop(sprintf("%s has %d duplicate (geography, time) rows", nm, dup))
    if (any(is.na(d$geography)) || any(is.na(d$time))) {
      stop(sprintf("%s has missing geography or time", nm))
    }
    measures <- setdiff(names(d), c("geography", "time"))
    neg <- vapply(d[measures], function(v) any(v < 0, na.rm = TRUE), logical(1))
    if (any(neg)) {
      stop(sprintf("%s has negative counts in: %s", nm,
                   paste(names(neg)[neg], collapse = ", ")))
    }
  }

  # --- 8. Write standardized output -----------------------------------------
  vroom::vroom_write(data_county, "standard/data_county.csv.gz", delim = ",")
  vroom::vroom_write(data_state, "standard/data_state.csv.gz", delim = ",")

  # --- 9. Record state ------------------------------------------------------
  jsonlite::write_json(
    list(
      fingerprint = fingerprint,
      raw_md5     = as.list(raw_md5),
      updated     = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    ),
    "process.json", auto_unbox = TRUE, pretty = TRUE
  )

  message(sprintf("ArboNET data written: %d county rows, %d state/national rows",
                  nrow(data_county), nrow(data_state)))
}
