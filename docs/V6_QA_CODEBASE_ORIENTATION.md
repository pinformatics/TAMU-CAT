# V6 QA Codebase Orientation

Last reviewed: 2026-06-08

This guide is for a QA reviewer or developer who has not worked in the codebase before. It maps the main V6 QA checklist areas to the code paths that usually control them.

## Rails Structure

This is a Rails app. Controllers live in `app/controllers`, views live in `app/views`, shared UI partials live mostly in `app/views/shared`, models live in `app/models`, and domain workflow objects live in `app/services`. Most V6 behavior is not isolated to one controller; the same data often appears in admin pages, advisor pages, reports, student pages, and exports.

## Grade Import

Grade import starts in `app/controllers/admin/grade_import_batches_controller.rb`. The controller receives uploads, shows previews, handles approval/commit/rollback, and serves import exports. The parsing, matching, diagnostics, target warnings, and commit behavior are in `app/services/grade_imports`. For direct competency imports, `Result` is treated as the student result and `Mastery Points` is treated as the course target. Committed evidence is stored in grade import evidence/rating models and then reused by reports, student competencies, competency matrix, and exports.

## Course Catalog And Course Targets

The V6 course schema is folded into `db/migrate/20260520160000_add_phase_two_data_model_foundations.rb`. Course catalog records use `Department`, `Course`, and `CourseOffering`. Configured course-level targets use `CourseCompetencyTarget`. If dev or Heroku has an old database that already marked the folded migration as run before the course target tables were added, reset that dev database and rerun migrations rather than adding a second migration file.

Admins can also check `Admin Dashboard -> Maintenance -> Data Health` for V6 schema readiness. If a folded-migration table such as `course_competency_targets` is missing, fix the database state before debugging higher-level import/report behavior.

For command-line checks, run `bin/rails v6:readiness`. On Heroku, use `heroku run rails v6:readiness -a mha-dev-eaa62d47718a`. If dev needs to be reset from production-like data without changing production, copy production into dev and then migrate dev:

```bash
heroku pg:copy mha501::DATABASE_URL DATABASE_URL --app mha-dev-eaa62d47718a --confirm mha-dev-eaa62d47718a
heroku run rails db:migrate -a mha-dev-eaa62d47718a
heroku run rails v6:readiness -a mha-dev-eaa62d47718a
```

## Program Configuration

Program Configuration is managed by `app/controllers/admin/program_setups_controller.rb` and the partials under `app/views/admin/program_setups`. The page is tab-based: tracks, majors, cohorts/program years, semesters, program competency targets, and course targets. Surface cards are intentionally compact, while detail fields such as position and target levels live in modal edit forms.

## Survey Builder

Admin survey setup is in `app/controllers/admin/surveys_controller.rb` and `app/views/admin/surveys`. Copying a survey should copy structure only: sections, categories, questions, options, required flags, and branching. It should not copy student/advisor assignments. The service object `app/services/surveys/copy_to_semester.rb` is the first place to inspect if copied surveys lose structure.

## Survey Completion And Preview

Student survey completion is primarily controlled by `app/controllers/surveys_controller.rb`, survey response models/services, and shared JavaScript in `app/javascript/application.js` plus `app/javascript/controllers/survey_autosave_controller.js`. Shared behavior for branching and validation is intentionally reused by real completion and admin preview. Preview should validate and show the same modals as a real survey but should not persist final response data.

## Survey Branching

Survey branching rules are centralized through shared survey rule code, especially `app/services/survey_question_rules.rb`, with front-end behavior wired through survey JavaScript. Parent answers determine whether child questions appear. Required validation should follow the question's configured required setting, not a hard-coded branch rule.

## Notifications

Notifications are represented by `app/models/notification.rb` and created from workflow jobs/services such as survey notification jobs and grade-import-related logic. They render in `app/views/notifications` and in the shared navbar notification menu. In-app notification preference is stored on the user; when disabled, new notifications should not appear as unread navbar items.

## Email Notifications

Email notification delivery is intentionally feature-flagged. `app/jobs/notification_email_delivery_job.rb` checks `EMAIL_NOTIFICATIONS_ENABLED` before sending. This means in-app notifications can be tested without enabling outbound email. If Gary is testing email, confirm the feature flag and SMTP/TAMU email settings are intentionally enabled in that environment.

## Navigation And Translation

Role-specific navbar partials live under `app/views/shared`, including student, advisor, and admin navbars. Translation uses the Google Translate wrapper in `app/javascript/application.js` and the shared translate partial. The app does not use a paid AI translation API.

## Student Competencies

Student competency data is assembled by service objects such as `app/services/student_competency_dashboard.rb`. This area combines self-assessment, course-derived evidence, uploaded course targets, program targets, and legacy advisor ratings. Target comparison must use the correct semester, track, and class/program year for the student.

## Competency Matrix

The competency matrix is under `app/controllers/admin/competencies_controller.rb`, `app/services/admin/competency_matrix.rb`, and `app/views/admin/competencies`. Although it has an admin namespace for historical reasons, advisors can access scoped versions. The export should match the filtered matrix and use one student per row with expanded score/target columns.

## Reports

Reports are controlled by `app/controllers/reports_controller.rb`, report services under `app/services/reports`, and the reports view. The same filter parameters should drive on-screen charts/tables and exports. Excel exports should include raw data where expected, while PDF exports are presentation-oriented.

## Student Profile Export

Student profile/program review exports are in `app/services/student_portfolio_exporter.rb` and related report export paths. This export should include identity fields, track/year/advisor, Google Sites URL, and course evidence summary fields. It should not re-add removed columns such as Cohort unless the product requirement changes.

## Survey Records

The current list route is `/survey_records`, backed by `StudentRecordsController`. Legacy paths such as `/student_records` and `/survey_responses` redirect or remain available for compatibility. If a list export is wrong, first check whether the controller and exporter are using the same filtered relation.

## Student Overview And Advisor Notes

Student overview pages are handled by staff/student overview controllers and views. They combine profile details, current/graduated status, survey history, competency history, warnings, and advisor notes. Advisor confidential notes should be tied to the correct student and should not be visible to students.

## People Management

People Management is handled by `DashboardsController` and the people management views. It manages members, roles, students, advisors, track/year updates, and lifecycle status. Sensitive role changes should have clear confirmation language because they affect app access.

## Account And Settings

Account pages and settings pages are separate read/edit flows. `/account` and `/settings` should be read-only summaries, while `/account/edit` and `/settings/edit` contain editable fields. Shared side navigation appears through account/settings partials.

## Security And FERPA

Role access is enforced in controllers and by scoped relations. Admin routes should not expose admin behavior to advisors or students. Advisor views that show student-level data must scope to assigned advisees. Student-level exports should include FERPA confirmation language before download.

## Testing

Most coverage is Minitest. Controller tests live in `test/controllers`, model tests in `test/models`, and service tests in `test/services`. For V6 work, good focused test targets are grade import batches, target warning analyzer, student competencies, reports exports, notifications, survey branching, and survey autosave/submit behavior.
