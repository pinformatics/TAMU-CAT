# Architecture Map

## High-level structure

The app is a Rails application with role-aware dashboards and a few service-heavy domains.

Main layers:

- controllers: request handling and page actions
- models: persistence and associations
- services: reporting, grade imports, and workflow logic
- views: ERB-based UI with shared `c-` CSS component classes

## Main domains

### Authentication and roles

Core role handling is built around `User` plus role-specific profiles such as:

- `Student`
- `Advisor`
- admin users through `User#role`

Dashboards route users into the right workflow area.

### Surveys

Important models:

- `Survey`
- `Category`
- `Question`
- `SurveyAssignment`
- `SurveyResponse`
- `StudentQuestion`
- `Feedback`

Purpose:

- define competency surveys
- assign them to students
- collect self-ratings and other answers
- allow advisor review and feedback

### Reporting

Important code:

- `app/services/reports/data_aggregator.rb`
- `app/controllers/reports_controller.rb`
- `app/views/reports/`
- `app/views/composite_reports/`

Purpose:

- aggregate survey and advisor data
- expose program-level reports
- generate student composite reports

### Grade imports

Important models:

- `GradeImportBatch`
- `GradeImportFile`
- `GradeCompetencyEvidence`
- `GradeCompetencyRating`
- `GradeImportPendingRow`

Important services:

- `app/services/grade_imports/batch_processor.rb`
- `app/services/grade_imports/batch_rating_rebuilder.rb`
- `app/services/grade_imports/pending_row_reconciler.rb`
- `app/services/grade_imports/derived_scorebook.rb`

Purpose:

- ingest faculty file uploads
- create competency evidence
- derive student competency ratings from imported course evidence
- preserve pending unmatched rows for later reconciliation

### Admin competency matrix

Important code:

- `app/controllers/admin/competencies_controller.rb`
- `app/services/admin/competency_matrix.rb`
- `app/views/admin/competencies/index.html.erb`

Purpose:

- show self, advisor, and course ratings side by side
- filter by student and competency context

### Program configuration

Important code:

- `app/controllers/admin/program_setups_controller.rb`
- `app/controllers/admin/target_levels_controller.rb`
- `app/views/admin/program_setups/`

Purpose:

- manage tracks, majors, cohorts, semesters
- manage competency target levels

### Course catalog foundations

Important models:

- `Department`
- `Course`
- `CourseOffering`

Purpose:

- normalize imported course codes such as `PHPM-633-700`
- separate department/course identity from semester section offerings
- provide future attachment points for faculty, Canvas identifiers, release rules, reports, and archive behavior

Current note:

- existing import/reporting code still keeps `course_code` for compatibility
- Phase 2 adds nullable `course_offering_id` references and backfills parseable imports
- Phase 3 course competency reads prefer `competency_id` where available and fall back to source titles

### People management

Important code:

- `app/controllers/dashboards_controller.rb`
- `app/views/dashboards/people_management.html.erb`
- `app/views/dashboards/_people_members_tab.html.erb`
- `app/views/dashboards/_people_students_tab.html.erb`
- `app/models/student_advisor_assignment.rb`

Purpose:

- manage role assignments
- manage student track / group / advisor assignments
- manage student lifecycle status for graduation, archive, inactive, and withdrawal workflows
- bulk-update lifecycle status for selected students
- current operational views default to active/current students
- explicit status filters can include graduated, archived, inactive, withdrawn, or all students where historical review is needed
- advisor assignment changes are stored in `student_advisor_assignments` while `students.advisor_id` remains the current pointer

### Data model health checks

Important code:

- `app/services/data_model_health_check.rb`
- `lib/tasks/data_model_health.rake`
- admin dashboard Data Model Health panel

Purpose:

- surface missing student profile basics
- catch advisor assignment history drift
- validate canonical competency references after imports/backfills
- flag parseable course codes that did not attach to course offerings

## Data flow for competency ratings

### Self ratings

Source:

- student survey responses

Primary data path:

- `StudentQuestion`

### Advisor ratings

Source:

- advisor feedback

Primary data path:

- `Feedback`

### Course ratings

Source:

- grade import batches

Primary data path:

- `GradeCompetencyEvidence`
- `GradeCompetencyRating`

## Important design decisions

### Advisor and course ratings are separate

Imported course ratings should not overwrite advisor feedback.

They are intentionally shown as separate sources in:

- admin competencies view
- student records
- reports where applicable

### Evidence rows are preserved

The app does not collapse raw import evidence away. Derived ratings are built from evidence rows so provenance can be shown later.

### Duplicate protection is intentional

Repeated uploads of the same source data should not generate duplicated evidence or duplicated pending rows.

### Pending unmatched rows are intentional

When a student does not yet exist locally, import rows are staged instead of discarded. They can be reconciled later when the student record exists.

## Files to understand first

- [app/services/grade_imports/batch_processor.rb](../app/services/grade_imports/batch_processor.rb)
- [app/services/admin/competency_matrix.rb](../app/services/admin/competency_matrix.rb)
- [app/services/reports/data_aggregator.rb](../app/services/reports/data_aggregator.rb)
- [app/controllers/admin/grade_import_batches_controller.rb](../app/controllers/admin/grade_import_batches_controller.rb)
- [app/views/admin/program_setups/show.html.erb](../app/views/admin/program_setups/show.html.erb)
- [app/views/dashboards/people_management.html.erb](../app/views/dashboards/people_management.html.erb)
