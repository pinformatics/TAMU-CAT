# Failed Import Troubleshooting

## Purpose

Use this guide when a grade import batch shows failed rows, pending matches, missing mappings, or confusing diagnostics.

## Start Here

1. Open the batch detail page.
2. Review the one-row file diagnostics summary.
3. Open the approval preview if the batch requires review.
4. Download the correction file when row cleanup is needed.
5. Fix the source file or lookup table.
6. Reupload the corrected file as a new dry run.

## Common Problems

### Invalid UIN

Meaning:

- the `Student UIN` field is blank, non-numeric, or not exactly 9 digits

Fix:

- correct the UIN in the uploaded file
- confirm the student exists in the app

### Missing Student Match

Meaning:

- the file has usable student information, but no local student record matched

Fix:

- create or correct the student record
- reconcile pending rows when possible
- reupload only if the source data itself was wrong

### Missing Competency Mapping

Meaning:

- a competency header did not match a canonical competency or alias

Fix:

- add an approved alias to [db/data/competency_aliases.csv](../db/data/competency_aliases.csv)
- or correct the header in the uploaded file

The importer may show `Did you mean ...?` suggestions. Treat suggestions as review aids, not automatic approval.

### Invalid Assessed Level

Meaning:

- an assessed-level cell is not a whole number from 1 through 5

Fix:

- replace the value with 1, 2, 3, 4, or 5
- leave the cell blank only when no assessed level exists

Diagnostics should identify blank values as blank instead of displaying a misleading placeholder.

### Invalid Course Target

Meaning:

- a course-target cell is not a whole number from 1 through 5

Fix:

- replace the value with 1, 2, 3, 4, or 5
- confirm the value is the course target, not the end-of-program target

### Duplicate File Warning

Meaning:

- a file with the same checksum was uploaded before

Fix:

- confirm whether this is intentional
- do not commit a duplicate unless it represents a corrected file with changed content

### Empty Student Processed Section

Possible causes:

- all rows failed
- all rows are pending student matches
- the same data was suppressed as duplicate evidence
- the batch is still a dry run and excluded from downstream reportable views

## What To Send Back To Faculty

Use the correction file when possible. It includes row details, expected values, received values, and suggested fixes.

Avoid sending internal audit logs or unrelated student-level exports.

## When To Commit

Commit only when:

- the preview has been reviewed
- failed rows are acceptable or corrected
- pending matches are acceptable or documented
- duplicate warnings are understood
- the semester is correct

Committing allows the batch to appear in course competency views and reports.
