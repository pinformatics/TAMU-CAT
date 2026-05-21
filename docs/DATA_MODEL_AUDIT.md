# Data Model Audit

Last audited: 2026-05-20

This is the Phase 1 data model audit for the TAMU Competency Assessment Tool. It documents the current database shape, the main data ownership boundaries, and the recommended direction for future restructuring.

This document started as the Phase 1 planning artifact. Phase 2 began on 2026-05-20 with additive schema foundations only: lifecycle fields, course catalog tables, nullable canonical references, and backfills. It is still not a destructive schema refactor.

## Phase 2 Implementation Status

Implemented in migration:

```text
20260520160000_add_phase_two_data_model_foundations.rb
```

This is the single local foundation migration for the unpushed data-model work. It includes the Phase 2 foundations and the Phase 4 advisor assignment history table/backfill so the migration list stays compact before the branch is pushed.

Phase 2 added:

- student lifecycle fields: `status`, `graduated_at`, `archived_at`, `archived_by_id`, `archive_reason`
- semester lifecycle fields: `status`, `starts_on`, `ends_on`, `closed_at`, `archived_at`
- course catalog tables: `departments`, `courses`, `course_offerings`
- nullable canonical competency references on target/import/rating tables
- nullable course offering references on import file/evidence/pending rows
- backfill logic for competency ids and parseable course codes

Phase 2 intentionally did not remove old columns. `competency_title` and `course_code` remain compatibility/source fields while the app gradually moves toward `competency_id` and `course_offering_id`.

## Phase 3 Implementation Status

Phase 3 began on 2026-05-20 as the first application cutover layer. It keeps legacy columns in place, but current operational screens now use the Phase 2 lifecycle and canonical-reference foundations.

Implemented in Phase 3:

- shared student lifecycle filters on `Student`
- current-student defaults for Student Overview, Survey Records, Admin/Advisor Competencies, advisor dashboard counts, and admin student assignment management
- explicit `student_status` filters for staff overview, survey records, and competency matrix screens
- historical detail access remains available when an admin/advisor opens a specific permitted student
- course competency reads now prefer `competency_id` for imported course ratings, imported evidence, and target levels, while retaining `competency_title` fallback behavior

Phase 3 still does not remove old string columns. The compatibility fields remain useful for source-file audit trails and for any rows not yet backfilled.

## Phase 4 Implementation Status

Phase 4 began on 2026-05-20 by adding advisor assignment history while keeping `students.advisor_id` as the current advisor pointer.

Implemented in Phase 4:

- new `student_advisor_assignments` table
- current assignment backfill from existing `students.advisor_id`
- `StudentAdvisorAssignment` model with current/historical scopes
- automatic history sync when `students.advisor_id` changes
- admin assignment changes stamp `assigned_by_id`
- Student Overview shows recent advisor assignment history

This is still additive. Current screens continue reading `students.advisor_id` for operational advisor scope, while the history table preserves who advised a student over time.

## Phase 5 Implementation Status

Phase 5 began on 2026-05-20 as an operational guardrails layer. It does not add another schema change.

Implemented in Phase 5:

- People Management now exposes student lifecycle status filters.
- Admins can update student lifecycle status from the student management table.
- Admins can bulk-select students and set them to active, graduated, withdrawn, inactive, or archived.
- Archived updates store the admin and optional archive reason.
- Reactivating a student clears graduated/archive timestamps and archive metadata.
- Student lifecycle changes are recorded in `admin_activity_logs` as `student_lifecycle_update`.
- `DataModelHealthCheck` provides reusable validation counts for student records, advisor assignment history, competency links, and course references.
- The admin dashboard shows a compact Data Model Health panel.
- `bin/rails data_model:health` prints the same guardrail report from the command line.

## Current Mental Model

The app now has three major data sources that are combined in dashboards, student records, competencies pages, reports, exports, and heatmaps.

| Source | Main tables | Current meaning |
| --- | --- | --- |
| People and program setup | `users`, `students`, `advisors`, `admins`, `program_tracks`, `program_years`, `program_semesters`, `majors` | Who the person is, their role, their track/year/major, and the current semester context. |
| Survey and advisor data | `surveys`, `survey_sections`, `categories`, `questions`, `survey_assignments`, `student_questions`, `survey_response_versions`, `feedback`, `advisor_feedback_submissions`, `confidential_advisor_notes` | Student self-assessment responses, survey assignment/completion, historical response snapshots, and legacy advisor feedback. |
| Course competency imports | `grade_import_batches`, `grade_import_files`, `grade_competency_evidences`, `grade_import_pending_rows`, `grade_competency_ratings`, `course_grade_release_dates` | Faculty/admin uploaded course competency scores from mastery-points columns and imported course target levels from result columns. |

The important product-level comparison is:

```text
student self score
advisor legacy score
course-derived score
configured program/track/year goal
imported course-level target
```

## Canonical Tables To Keep

These tables already represent clear concepts and should remain part of the future model, even if some columns or associations are improved.

| Table | Recommendation |
| --- | --- |
| `users` | Keep as the authentication and person identity table. |
| `students`, `advisors`, `admins` | Keep role profile tables. Consider adding lifecycle fields to `students`. |
| `domains`, `competencies` | Keep as the competency catalog. Future competency evidence should reference `competencies.id`. |
| `program_tracks`, `program_years`, `majors` | Keep as program configuration lookup tables. |
| `program_semesters` | Keep as the semester/term table, but expand it with lifecycle and date fields. |
| `surveys`, `survey_sections`, `categories`, `questions` | Keep as survey definition tables. |
| `survey_assignments` | Keep as the survey-to-student assignment/completion table. |
| `survey_response_versions` | Keep as the audit/snapshot table for survey responses. |
| `grade_import_batches`, `grade_import_files` | Keep as import workflow/provenance tables. |
| `admin_activity_logs`, `survey_change_logs`, `notifications`, `site_settings` | Keep as audit, notification, and configuration support tables. |

## Tables That Need Normalization Later

These tables work today, but they contain the main technical debt.

| Table | Current issue | Recommended direction |
| --- | --- | --- |
| `grade_competency_evidences` | Uses `competency_title` strings and loose `course_code` strings. Also stores preview/dry-run evidence in the same table used for later reporting. | Add nullable `competency_id` and future `course_offering_id`. Keep raw title/code as source metadata. Continue filtering reportable batches carefully until a cleaner committed-evidence model exists. |
| `grade_competency_ratings` | Derived course ratings also use `competency_title` strings. | Add nullable `competency_id`. Consider rebuilding from a canonical evidence table in the future. |
| `grade_import_pending_rows` | Pending rows duplicate many evidence fields and use string competency/course identifiers. | Keep for review workflow, but add `competency_id` and future `course_offering_id` after canonical parsing is stable. |
| `competency_target_levels` | Uses `competency_title`, `track` label strings, and both `program_year`/`class_of` concepts. | Move toward `competency_id`, `program_track_id` or track key, and one clear cohort/program-year field. |
| `student_questions` | Stores current answer values by student/question, but does not itself express competency evidence. | Keep as survey response state. Derive self competency evidence into a future canonical evidence/read model. |
| `feedback` | Numeric advisor competency data is legacy but still feeds comparisons. | Keep for history. Derive advisor competency evidence into a future canonical evidence/read model, then mark as legacy in UI and docs. |
| `surveys.track` and `survey_track_assignments.track` | Track is partly denormalized as text. | Prefer track keys or `program_track_id` references in future migrations. |
| `survey_offerings.class_of` and `students.program_year` | Naming is inconsistent. | Standardize around one term. Recommended: `program_year` if it means cohort/graduation year in the app. |

## Legacy Or Compatibility Areas

These should not be deleted quickly. They need a transition plan.

- `feedback` and `advisor_feedback_submissions` are legacy advisor competency workflow data.
- `student_questions` is still the primary current-answer storage for surveys.
- `survey_response_versions` is the newer historical/snapshot layer.
- `competency_title` string columns are compatibility fields and source metadata, not ideal long-term join keys.
- `class_of` still appears in some survey offering/target contexts while `program_year` is used on students.

## Main Data Model Risks

### Competency Identity

The app has a good `competencies` table, but import/rating/target data often joins by `competency_title` string. This creates risk when names change, punctuation differs, or source files contain typos.

Recommended migration direction:

1. Add nullable `competency_id` to import evidence, pending rows, ratings, and target levels.
2. Backfill by matching normalized titles to `competencies.title`.
3. Update code to prefer `competency_id`.
4. Keep `competency_title` as imported/source display metadata.
5. Add validations once backfill is complete.

### Course Identity

Course data is currently mostly stored as a string such as:

```text
PHPM-633-700
```

That string contains several separate facts:

```text
department code: PHPM
department name: Public Hlth Pol & Mgmt
course number: 633
course title: Health Law and Ethics
section number: 700
```

Best-practice direction is to separate catalog course identity from semester-specific offerings.

Recommended future tables:

```text
departments
- id
- code
- name
- active

courses
- id
- department_id
- number
- title
- active

course_offerings
- id
- course_id
- program_semester_id
- section_number
- source_code
- active
- archived_at
```

For `PHPM-633-700`, the data would become:

```text
departments.code = "PHPM"
departments.name = "Public Hlth Pol & Mgmt"
courses.number = "633"
courses.title = "Health Law and Ethics"
course_offerings.section_number = "700"
course_offerings.source_code = "PHPM-633-700"
```

Why split `courses` and `course_offerings`:

- the catalog course `PHPM-633 Health Law and Ethics` can exist across many semesters
- section `700` is an offering/semester fact, not the course identity itself
- imports, releases, targets, and reports can later attach to the exact semester offering
- future faculty/instructor, modality, section, and Canvas identifiers have a natural place

The first migration does not need to be perfect. A safe Phase 2 could add these tables, backfill from existing `course_code` strings, and leave old columns in place until reporting has moved.

### Student Lifecycle And Archive Status

Students currently do not have a clear lifecycle state. Graduated or inactive students can still appear in current advisor-facing lists unless every query remembers to filter them manually.

Recommended future fields on `students`:

```text
status: active, graduated, withdrawn, inactive, archived
graduated_at
archived_at
archived_by_id
archive_reason
```

Recommended behavior:

- active students appear in current semester advisor/admin worklists
- graduated and archived students stay visible in historical records but are hidden from default current workflows
- admins can intentionally include archived students with a filter
- advisor dashboards show only current active advisees by default
- historical survey, feedback, import, and competency records remain intact

Do not delete graduated students. Keep them for audit, FERPA-sensitive records, and longitudinal reporting.

### Advisor Assignments

`students.advisor_id` stores the current advisor assignment. Phase 4 adds `student_advisor_assignments` as the historical record.

Implemented history table:

```text
student_advisor_assignments
- id
- student_id
- advisor_id
- starts_on
- ends_on
- primary
- assigned_by_id
- created_at
- updated_at
```

This allows the app to answer:

- who is this student's current advisor?
- who advised this student during Spring 2026?
- which students should this employed advisor see now?
- which historical advisees should remain visible only in records?

The current `students.advisor_id` remains as a cached/current pointer during migration.

### Semester Lifecycle

`program_semesters` currently has `name` and `current`. That is enough for basic selection but not enough for archiving, release governance, or default current/historical filtering.

Recommended future fields:

```text
starts_on
ends_on
status: planned, current, closed, archived
closed_at
archived_at
```

Recommended behavior:

- only one semester should be `current`
- closed semesters remain reportable
- archived semesters are hidden from default operational screens
- imports and survey assignments should remain attached to their original semester

### Import Review Versus Reportable Evidence

The current dry-run import workflow stores preview evidence and ratings in the same tables used after commit, and downstream code relies on `GradeImportBatch.reportable` to exclude preview batches.

This is workable, but future contributors need to be careful.

Recommended long-term direction:

- keep `grade_import_batches` and `grade_import_files` as workflow/provenance
- keep pending/correction rows as import review data
- make committed/reportable competency evidence explicit
- do not let preview-only rows leak into student dashboards or exports

## Recommended Target Read Model

Long-term, pages like My Competencies, Student Overview, Admin Competencies, Survey Records, exports, and heatmaps would be simpler if they read from one canonical competency evidence model.

Possible future table:

```text
competency_evidences
- id
- student_id
- competency_id
- program_semester_id
- source_type: self, advisor, course
- score
- target_score
- target_type: program_goal, course_target
- course_offering_id
- survey_id
- survey_assignment_id
- feedback_id
- grade_import_batch_id
- observed_at
- released_at
- metadata
```

This table should not necessarily replace every source table immediately. It can start as a derived/read model and later become canonical after confidence is high.

## Phase 2 Migration Candidates

These were selected as the safest next schema moves because they are additive and can be rehearsed against a local production copy. Items 1-6 were implemented as additive foundations on 2026-05-20. Items 7-8 remain the gradual application cutover.

1. Add `status`, `graduated_at`, `archived_at`, `archived_by_id`, and `archive_reason` to `students`.
2. Add semester lifecycle fields to `program_semesters`.
3. Add `departments`, `courses`, and `course_offerings`.
4. Add nullable `competency_id` to `competency_target_levels`, `grade_competency_evidences`, `grade_import_pending_rows`, and `grade_competency_ratings`.
5. Add nullable `course_offering_id` to `grade_competency_evidences`, `grade_import_pending_rows`, and possibly `grade_import_files`.
6. Backfill from the local production copy and produce validation counts.
7. Update code to prefer ids while keeping old columns as compatibility fallbacks.
8. Only later add stricter non-null constraints or remove old columns.

## Backfill Validation Checklist

Before any production migration is trusted, run these checks on a local production copy.

- every `grade_competency_evidences.competency_title` matches a `competencies.title`
- every `grade_competency_ratings.competency_title` matches a `competencies.title`
- every `competency_target_levels.competency_title` matches a `competencies.title`
- every parseable `course_code` maps to a department/course/offering
- invalid course codes are listed for admin review, not silently dropped
- no reportable course ratings are lost after backfill
- preview/dry-run batches stay excluded from student-facing pages
- archived/graduated students disappear from current advisor dashboards
- archived/graduated students remain visible through explicit historical records/search
- current semester behavior remains unchanged until semester status filtering is intentionally enabled

## Do Not Do This In One Step

Avoid a one-shot migration that renames tables, deletes columns, and rewrites app behavior at the same time.

Use this sequence instead:

1. Add new tables/columns.
2. Backfill local production copy.
3. Validate counts and unmatched rows.
4. Update reads to prefer new fields with old fallbacks.
5. Update writes.
6. Run in production with old data still intact.
7. Retire old columns only after a stable release cycle.
