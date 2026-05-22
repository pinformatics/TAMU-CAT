# Grade Import Runbook

## Purpose

This document explains the course competency import system used by `Admin > Grade Import Batches`.

## What the feature does

The grade import system allows staff to upload faculty-provided files and generate:

- `GradeCompetencyEvidence` rows
- derived `GradeCompetencyRating` rows
- pending unmatched rows when students do not exist yet

The imported data is shown as a separate course-derived source. It does not replace advisor feedback.

## Supported import formats

### 1. Mapping workbook format

This format uses:

- one grade sheet
- one mapping sheet

The mapping sheet defines:

- assignment-to-competency rules
- grade-range-to-competency-level rules
- optional course code scoping

Supported grade sheet styles:

- narrow row-based sheet
- Canvas-style wide gradebook

### 2. Direct competency export format

This format does not need a mapping sheet.

Supported file types:

- `.csv`
- `.xlsx`
- `.xlsm`

Expected identifiers:

- `Student SIS ID`
- `Student UIN`
- or `Student ID`

Expected competency columns:

- `EMHA ... result`
- `EMHA ... mastery points`
- `RMHA ... result`
- `RMHA ... mastery points`
- `[Competency Title] COURSE TARGET`
- `[Competency Title] ASSESSED LEVEL`
- `[Competency Title] LEVEL`

Ignored columns:

- `HPMC ...`

Important interpretation:

- `mastery points` is used as the student's actual course competency level
- `assessed level` / `level` is also used as the student's actual course competency level
- `result` is used as the course target level
- `course target` is also used as the course target level
- both values must be whole numbers from 1 through 5 when present

Course code derivation:

- derived from sheet or file name
- example: `PHPM_633_700` becomes `PHPM-633-700`

## Current workflow

1. Go to `Admin > Grade Import Batches`
2. Upload one or more files
3. Leave `dry run` checked for the first pass
4. Review the batch detail page
5. Commit the dry run if it is correct

Related operator guides:

- [Fall Competency Workflow](FALL_COMPETENCY_WORKFLOW.md)
- [Faculty Export Preparation Guide](FACULTY_EXPORT_PREPARATION.md)
- [Failed Import Troubleshooting](FAILED_IMPORT_TROUBLESHOOTING.md)
- [Semester Release Checklist](SEMESTER_RELEASE_CHECKLIST.md)

## Batch statuses

- `processing`: file parsing is underway
- `completed`: batch finished without row/file failures
- `completed_with_errors`: batch finished but some rows failed
- `failed`: file-level failure or total batch failure
- `rolled_back`: evidence and ratings were removed

## File-level metrics

### Processed Rows

Count of evidence rows created, not always raw input rows.

If one row maps to multiple competencies, processed rows can be larger than source-row count.

### Pending Rows

Rows stored because the student could not be matched locally.

These are staged for later reconciliation.

### Failed Rows

Rows that could not be turned into evidence or pending rows.

Examples:

- missing identifiers
- invalid values
- unmapped assignments

### Match Rate

This is effectively an import success rate based on processed versus failed rows. It is not a pure “student matched” metric.

## Dry run, commit, rollback

### Dry run

- batch is processed and saved
- evidence and ratings exist for preview
- batch is excluded from reportable course views

### Commit dry run

- marks the batch as reportable
- course ratings then appear in downstream admin/reporting views

### Rollback

- deletes evidence and derived ratings for the batch
- changes status to `rolled_back`

Use rollback carefully. It is intended for undoing a bad committed batch.

## Duplicate protection

The importer has duplicate protection for:

- evidence rows
- pending rows

It uses:

- source keys
- file checksum
- import fingerprints

Result:

- re-uploading the same file should not create duplicated records
- duplicate attempts appear as warnings

## Pending unmatched rows

When a student does not exist locally at import time:

- the row is saved in `grade_import_pending_rows`
- status is `pending_student_match`
- a reconciliation flow can attach it later when the student exists

This is preferred over forcing admins to re-upload the file later.

## Competency title normalization

The importer resolves competency titles through the editable alias lookup at:

- [db/data/competency_aliases.csv](../db/data/competency_aliases.csv)

Use this file as the internal master list for strings that should map to the 17 canonical competencies. Staff can add rows when Canvas, faculty templates, or competency-model language uses a different string.

Required columns:

- `raw_string`
- `canonical_competency_title`

Helpful optional columns:

- `source`
- `notes`
- `active`

If an uploaded file contains a competency string that is not recognized, the import preview records a `missing_competency_mapping` issue so the alias file can be updated or the uploaded file can be corrected.

When the missing string is close to a known competency or alias, diagnostics include a “Did you mean …?” suggestion. The error report and correction file include structured review fields such as:

- `column`
- `value`
- `expected`
- `received`
- `suggested_canonical_competency_title`
- `suggested_alias_string`
- `correction_hint`

Example:

- `Legal and Ethical Bases for Health Services and Health Systems`
- `Legal & Ethical Bases for Health Services and Health Systems`

Both normalize to the canonical competency title used by reports.

## Important files

- [app/services/grade_imports/batch_processor.rb](../app/services/grade_imports/batch_processor.rb)
- [app/services/grade_imports/pending_row_reconciler.rb](../app/services/grade_imports/pending_row_reconciler.rb)
- [app/services/grade_imports/batch_rating_rebuilder.rb](../app/services/grade_imports/batch_rating_rebuilder.rb)
- [app/controllers/admin/grade_import_batches_controller.rb](../app/controllers/admin/grade_import_batches_controller.rb)

## Sample files

Useful template files currently in the repo:

- `Admin > Grade Import Batches > New batch > Template files`
  - Canvas grade template
  - Canvas competency template
  - Faculty competency template
- [public/grade-import-examples/Example Canvas Grade Export.xlsx](../public/grade-import-examples/Example%20Canvas%20Grade%20Export.xlsx)
- [public/grade-import-examples/Example Canvas Competency Export.csv](../public/grade-import-examples/Example%20Canvas%20Competency%20Export.csv)
- [public/grade-import-examples/Example Faculty Competency Export 26S PHPM 601.csv](../public/grade-import-examples/Example%20Faculty%20Competency%20Export%2026S%20PHPM%20601.csv)
- [local_import_samples/folder_run_samples/folder_run_canvas_sample.xlsx](../local_import_samples/folder_run_samples/folder_run_canvas_sample.xlsx)
- [local_import_samples/folder_run_samples/folder_run_direct_sample.xlsx](../local_import_samples/folder_run_samples/folder_run_direct_sample.xlsx)

Note:

- samples are intended for parser and operator workflow validation; successful student matching still depends on identifiers existing in the target environment
- additional dated outputs from sample-generation runs should be treated as local artifacts and not committed

## Smoke-test checklist

When changing import behavior, test:

1. mapping workbook import
2. direct competency CSV import
3. duplicate suppression on re-upload
4. pending-row creation for missing students
5. reconciliation after creating a matching student
6. dry run commit
7. rollback
8. target-met reporting
9. student overview competency history export
