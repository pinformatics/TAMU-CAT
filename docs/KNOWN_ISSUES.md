# Known Issues

No active release-blocking issues are known in the repository as of the latest V6 hardening pass.

The notes below are resolved risks and operational guardrails retained for handoff context.

## Grade imports

### Resolved: direct competency files without real student identifiers

The direct competency format expects:

- `Student SIS ID`
- or `Student ID`

If those values are blank, the importer now stages rows as pending student matches when `Student name` is present.

Current behavior:

- rows with `Student SIS ID` or `Student ID` continue to match normally
- rows with only `Student name` are staged with `student_identifier_type = student_name`
- pending rows reconcile by exact student name when the student record exists

### Resolved: legacy course ratings without an import semester

`Admin > Competencies`, reports, and student competency views now use `grade_import_batches.program_semester_id` when a semester filter is applied.

Current behavior:

- committed imports without a selected semester remain visible only in unfiltered/all-semester contexts
- admins can assign or repair the batch semester from the batch detail page
- semester-filtered competency views only include reportable imports for the selected semester

### Partially resolved: grade import processor size

[app/services/grade_imports/batch_processor.rb](../app/services/grade_imports/batch_processor.rb) handles:

- batch orchestration
- file format detection
- direct competency import
- Canvas import
- narrow import
- mapping parsing
- duplicate protection

Current mitigation:

- file routing and failure diagnostics have been extracted into focused internal services
- parser behavior is covered by direct competency, Canvas, duplicate suppression, commit, rollback, and display tests
- additional parser extraction can continue incrementally without changing the public processor contract

## UI / admin surface area

### Operational note: admin still has the densest workflow surface

The admin experience is much better organized than before, but it still has the most complex operational surface in the system.

High-complexity areas:

- grade imports
- survey builder
- reports
- competencies view

Guardrail:

- keep admin workflow changes covered by controller/service tests and manual smoke testing

## Testing coverage

The highest-risk areas now have dedicated automated coverage:

- grade imports
- pending reconciliation
- competencies filtering
- dry run commit / rollback

## Data and environment

### Operational note: seeded local data may not reflect production behavior

Many admin/import workflows behave best against a realistic production clone because:

- seeded students are limited
- import matching depends heavily on real UINs / IDs / accounts

Guardrail:

- use the generated/sample import files for parser validation
- use a production-like clone before final release signoff when validating real Canvas exports

## Documentation dependency

The README points to the GitHub wiki for broader documentation. Repo docs have been updated for the V6 import and competency behavior; keep wiki pages synchronized when deployment/admin workflows change.
