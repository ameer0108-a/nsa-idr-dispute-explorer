# Data quality checks

All nine checks run on the staged line items (5,783,034 rows across the four 2025 quarters). A row can fail more than one check, so the per-check counts add up to more than the totals at the bottom.

Every failure goes to `dq_failures`, and every row that failed anything goes to `dq_audit` along with the list of checks it failed. Reject-level failures are left out of `fct_line_items`, so they never reach the reporting views. Warn-level failures stay in.

| Check | Dimension | Severity | What it looks for | Rows flagged | Share of rows |
|---|---|---|---|---:|---:|
| DQ01 Duplicate DLI across quarters | Uniqueness | reject | Same DLI number shows up in more than one quarterly file. CMS republishes reopened disputes in the quarter they were corrected, so the latest copy is kept and earlier copies fail. | 5,604 | 0.097% |
| DQ02 Missing or malformed IDs | Completeness | reject | Dispute number is not DISP-<digits> or DLI number is not DLI - <digits>. | 0 | 0.000% |
| DQ03 Unknown determination outcome | Validity | reject | Payment determination outcome is blank or not one of the three values CMS defines (provider, plan, split). | 2 | 0.000% |
| DQ04 Service state missing or invalid | Validity | warn | Location of service is N/R or not a valid state or territory code. Row is kept and reported under Unknown state. | 57,356 | 0.992% |
| DQ05 Malformed NPI | Validity | warn | An NPI was reported but it is not 10 digits (most of these look like 9-digit tax IDs typed into the NPI field). | 780 | 0.013% |
| DQ06 Line result contradicts dispute result | Consistency | reject | Dispute is marked as a provider win or a plan win, but at least one of its line items shows the other side's offer selected. That should have been a split decision. | 43,492 | 0.752% |
| DQ07 Single dispute with several billable lines | Consistency | reject | Dispute type is Single but it carries more than one single or bundled line item. A single dispute should cover one item or one bundle. | 437 | 0.008% |
| DQ08 Prevailing offer does not match selected offer | Consistency | reject | The prevailing offer (as a ratio to QPA) does not equal the offer of the side that was selected, within 0.01. | 0 | 0.000% |
| DQ09 Implausible offer ratio | Plausibility | reject | An offer or the prevailing offer is negative, the provider offered $0, or a ratio is above 1,000 times the QPA. | 3,623 | 0.063% |

- **Failed at least one check:** 110,973 rows (1.92%)
- **Rejected (removed from reporting):** 52,985 rows (0.92%)

## Notes on a few of them

**DQ01, duplicate DLIs.** CMS says reopened disputes show up again in the file for the quarter they were corrected. All 5,604 flagged rows are earlier copies from Q1 and Q2 whose corrected versions are in Q3 or Q4. The newer copy is kept.

**DQ06, line result contradicts dispute result.** This covers 4,414 disputes, all of them batched. The dispute is labeled a provider win or a plan win, but at least one line inside it shows the other side's offer picked. That should have been a split decision. Since there's no way to tell which label is wrong, every line in those disputes is rejected.

**DQ04, missing service state.** All 57,356 are N/R, meaning the location wasn't reported. The outcome and offer data on these rows is fine, so they stay in and show up as Unknown in the state view.

**DQ09, implausible ratios.** These are negative offers, providers offering $0, or ratios over 1,000 times the QPA. The 1,000x cutoff is deliberately loose. Real awards at 20 to 50 times the QPA happen for some codes (neuromonitoring especially), so the check only catches values that look like unit or typing errors.

**Checks that caught nothing (DQ02, DQ08).** They still run. If a future file comes in with broken IDs or a prevailing offer that doesn't match either side, the build will catch it.
