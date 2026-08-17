# arbonet

Ingests CDC [ArboNET](https://www.cdc.gov/mosquitoes/php/arbonet/index.html)
historic county-level arboviral disease surveillance data for
[PopHIVE](https://pophive.org).

Six domestic arboviruses, each from its CDC historic-data dashboard:

| Code  | Virus                             | Years     |
|-------|-----------------------------------|-----------|
| `wnv` | [West Nile virus](https://www.cdc.gov/west-nile-virus/data-maps/historic-data.html) | 1999–2025 |
| `eee` | [Eastern equine encephalitis virus](https://www.cdc.gov/eastern-equine-encephalitis/data-maps/historic-data.html) | 2003–2025 |
| `jcv` | [Jamestown Canyon virus](https://www.cdc.gov/jamestown-canyon/data-maps/historic-data.html) | 2011–2025 |
| `lac` | [La Crosse virus](https://www.cdc.gov/la-crosse-encephalitis/data-maps/historic-data.html) | 2003–2025 |
| `sle` | [St. Louis encephalitis virus](https://www.cdc.gov/sle/data-maps/historic-data.html) | 2003–2025 |
| `pow` | [Powassan virus](https://www.cdc.gov/powassan/data-maps/historic-data.html) | 2004–2025 |

## Output

Both files are wide, keyed on `geography` + `time` (`YYYY-12-31`, annual).

- `standard/data_county.csv.gz` — 5-digit county FIPS, plus a national (`"00"`)
  row per year so county series can be charted against the national trend.
  Filter on `nchar(geography)` before summing across rows.
- `standard/data_state.csv.gz` — 2-digit state FIPS plus national (`"00"`).

Measure columns are `arbonet_<code>_<measure>`:

| Measure | Meaning |
|---------|---------|
| `_cases` | Total reported human disease cases (neuroinvasive + non-neuroinvasive) |
| `_neuro_cases` | Neuroinvasive cases (meningitis, encephalitis, acute flaccid paralysis) |
| `_nonhuman_activity` | 1 if veterinary/mosquito/bird/sentinel activity was reported, else 0. Not produced for `pow`, whose dashboard reports human cases only. |
| `arbonet_wnv_blood_donors` | Presumptive viremic blood donors found by blood-supply screening. WNV only. |

See `measure_info.json` for full definitions and caveats.

## Usage

```r
source("ingest.R")
```

No API key required, but note: the dashboard pages are JavaScript
visualizations with no download endpoint. `ingest.R` reads the flat CSVs that
back them under `www.cdc.gov/wcms/vizdata/`, resolved from each page's
cdc-open-viz config JSON. `www.cdc.gov` also sits behind Akamai and answers
most non-browser clients with a 403 — `download.file(method = "libcurl")` gets
through where `httr` and plain `curl` do not.

## Interpreting the data

- Cases are reported by **county of residence**, not where exposure occurred.
- **Non-neuroinvasive disease is substantially under-reported.** CDC advises
  against using total case counts to compare activity between locations or over
  time; use `_neuro_cases` for that.
- **Non-human surveillance is not standardized.** A `0` means nothing was
  reported to CDC, not that there is no risk.
- **The most recent year is preliminary** and subject to revision.
- **Connecticut changes geography mid-series** — counties through 2022,
  planning regions from 2023 — so its FIPS codes shift.
- **Unallocated records** (state FIPS + `999`, used when county of residence is
  unknown) are held out of the county rows but retained in the state and
  national totals, so those still reconcile with CDC's published figures. The
  ingest logs which codes it held out.
- **Counts are passed through unsuppressed**, exactly as CDC publishes them.
  County values of 1–2 cases are common; no further suppression or imputation
  is applied here.

## Consumed by

Intended to be pulled by [PopHIVE/Ingest](https://github.com/PopHIVE/Ingest)
directly from GitHub, following the same pattern as `PopHIVE/hud-chas`,
`PopHIVE/bureau-labor-statistics`, and `PopHIVE/usda-food-access`.
