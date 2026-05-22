# Fall Competency Workflow

## Purpose

Use this guide when preparing, importing, reviewing, releasing, and reporting course-derived competency results for a semester.

## Roles

- Program admins prepare settings, import course files, approve batches, release results, and export reports.
- Faculty or staff provide Canvas exports or faculty competency templates.
- Advisors review student competency history and use the overview pages for advising conversations.
- Students view released course competency results in My Competencies.

## Before Faculty Files Arrive

1. Confirm the active semester under `Admin > Program Setup > Semesters`.
2. Confirm tracks and class years under `Admin > Program Setup`.
3. Confirm end-of-program targets under `Admin > Program Setup > Competency Targets`.
4. Confirm course release dates under `Admin > Course Grade Release Dates`.
5. Confirm competency aliases in [db/data/competency_aliases.csv](../db/data/competency_aliases.csv).
6. Send the faculty export preparation guide to course contacts.

## Import Review Workflow

1. Go to `Admin > Grade Import Batches`.
2. Start a new batch and keep dry run enabled.
3. Upload one or more course files.
4. Open the batch detail page.
5. Review the one-row diagnostics summary.
6. Review failed values, missing mappings, invalid UINs, pending matches, and duplicate warnings.
7. Download the correction file if rows need cleanup.
8. Approve the preview only after every listed issue has been reviewed.
9. Commit the dry run when the preview is acceptable.

Dry runs are saved for review, but they are not reportable until committed.

## After Commit

1. Confirm the batch is assigned to the correct semester.
2. Confirm `Student Processed` rows show assessed levels and course targets.
3. Confirm target-met status in exports or reports.
4. Use `Reports > Course Competencies` to verify course-level target attainment.
5. Use `Student Overviews` to spot-check several students.
6. Release results when the course release date is reached.

## Reporting Outputs

Use these outputs for accreditation and program review:

- Grade import correction file for cleanup work.
- Batch evidence export for row-level course evidence.
- Batch derived ratings export for aggregated student competency ratings.
- Reports course competency CSV for course, competency, target, and release status summaries.
- Student overview competency history CSV for one-student advising or portfolio review.
- Portfolio export for Google Sites URLs plus competency summary and course target attainment.

## Release Rules

Course results stay hidden from students until the configured release date. Admins and advisors can review data before release for operational checks.

When a release date changes from embargoed to released, student and advisor notifications are queued.

## Final Signoff Checklist

- All expected course files are committed.
- No known missing competency mappings remain.
- No unresolved invalid UIN rows remain.
- Pending student matches have been reconciled or documented.
- Course release dates are correct.
- Reports show expected tracks, class years, courses, and semester.
- Export audit logs exist for student-level exports.
- A sample student view has been checked for released results.
