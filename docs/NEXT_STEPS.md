# Next Steps

## Priority order

This list is intentionally short. It is meant to help the next owner choose useful work quickly.

## Urgent

No urgent release-blocking follow-up is currently known.

## Recent phase completion

The competency workflow phases through documentation and training are now represented in repo-local docs:

- competency alias lookup and import diagnostics
- course target-met reporting
- import audit logging
- reports and dashboards
- notifications and email workflow
- advisor and portfolio exports
- Fall workflow and training guides

## Completed

### 1. Added smoke tests for grade imports

Covered:

- mapping workbook import
- direct competency import
- duplicate suppression
- pending-row reconciliation
- dry run commit
- rollback

### 2. Added clearer operator guidance on the batch results page

Covered:

- label when a file was detected as direct competency import
- explain why rows are pending versus failed
- call out the semester assigned to reportable course ratings
- allow admins to repair a legacy batch semester after upload

## Next

### 3. Break up `GradeImports::BatchProcessor`

Suggested split:

- file router
- direct competency parser
- Canvas parser
- narrow parser
- mapping parser / validator

Why:

- easier testing
- safer future changes

Status:

- file upload routing and failure diagnostics are extracted
- direct competency rows with only student names now stage as pending rows
- continue splitting direct competency, Canvas, narrow grade, and mapping parsing after the Fall release-critical behavior is stable

### 4. Add more sample import files

Include:

- successful direct competency import with real identifiers
- duplicate-upload example
- pending-row example
- intentionally bad mapping example

Why:

- makes troubleshooting and onboarding much easier

### 5. Improve competencies usability further

Potential improvements:

- sticky domain summary or quick-jump links
- export filtered matrix
- remembered filter state

Why:

- admins use this page to answer targeted questions quickly

## Later

### 6. Continue semester support hardening for course ratings

Semester-filtered course ratings now use `grade_import_batches.program_semester_id`.

Why:

- keeps course, self, and advisor filtering aligned
- batch detail allows operational cleanup for legacy imports without a semester

### 7. Continue admin UI cleanup

Focus on:

- reducing nested containers
- making action language more explicit
- standardizing dense detail pages

Why:

- polish work matters most in the admin experience

### 8. Consolidate cross-source competency logic

Self, advisor, and course competency views now exist in multiple places.

Why:

- reduces duplication
- keeps behavior consistent across reports, student records, and admin competencies
