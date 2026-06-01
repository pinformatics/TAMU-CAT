# Gary V6 QA Checklist

## Purpose

This checklist covers the new and changed functionality for the V6 Fall 2026 release of TAMU CAT.

Use it for manual testing before Gary or another tester signs off. Mark anything that is missing, confusing, broken, or different from the expected behavior.

## Test Setup

- [ ] Test in the deployed app and locally if possible.
- [ ] Use at least one admin account, one advisor account, and two student accounts.
- [ ] Include one advisor with assigned advisees and one advisor with no advisees.
- [ ] Include one current student and one graduated or archived student.
- [ ] Test at least two semesters, such as Fall 2025 and Spring 2026.
- [ ] Test one semester with committed course competency data.
- [ ] Test one semester with no committed course competency data.
- [ ] Test one course competency release date in the future and one release date in the past.
- [ ] Download and open each export file after testing.
- [ ] Check desktop and a narrow/mobile viewport for the major student pages.

Recommended smoke-test order:

1. Student survey completion
2. Student My Competencies
3. Student Profile, Settings, Notifications, and FAQ
4. Advisor dashboard, advisee records, reports, and notifications
5. Admin survey builder and preview
6. Admin grade import workflow
7. Admin program configuration
8. Admin competencies matrix
9. Reports and exports
10. People management and student overview

## Student Survey Completion

Check the real student survey page and the admin survey preview page. They should behave the same except preview must not save data.

- [ ] Survey page spacing is readable and compact.
- [ ] Save Progress works and does not conflict with final Submit.
- [ ] Autosave prompts appear while completing a survey.
- [ ] Autosave prompt changes state when answers are edited, autosaved, or fail to save.
- [ ] Final Submit opens a modal with these choices: go back to editing, save and exit, submit.
- [ ] Save and exit keeps the survey incomplete.
- [ ] Submit marks the survey complete only after required validation passes.
- [ ] Preview submit runs the same validation as the real survey.
- [ ] Preview submit shows the same modal behavior as the real survey.
- [ ] Preview submit does not save any response data to the database.
- [ ] Error messages are clear and point the user to the highlighted questions.
- [ ] Floating warning or success messages are readable, opaque, and closable with the X button.

Employment branching:

- [ ] "Are you currently employed?" initially hides all child questions.
- [ ] Selecting Yes shows these child questions in order:
  - [ ] If yes, where are you employed? (name and address)
  - [ ] What is your title?
  - [ ] How many hours per week do you work on average?
  - [ ] How flexible are your work hours?
- [ ] Selecting No hides those child questions again.
- [ ] Hidden child questions are not required for submission.
- [ ] If those child questions are manually marked required in survey builder, they are required only when Yes is selected.
- [ ] "Other" under work-hours flexibility shows a text box.
- [ ] The "Other" text answer saves with the selected answer.

Assessment reflection questions:

- [ ] Reflection questions are hidden until an actual Assessment dropdown option is selected.
- [ ] Reflection questions appear directly after the related Assessment question.
- [ ] Reflection questions are not required unless manually configured that way.
- [ ] Clearing the Assessment selection hides the related reflection question again.

## Student Dashboard And Navigation

- [ ] Student dashboard cards fit without awkward wrapping.
- [ ] Notifications in the student dashboard do not grow indefinitely.
- [ ] Student dashboard only shows unread notifications in the compact notification area.
- [ ] FAQ appears in the student navigation.
- [ ] Navbar remains in one row or gracefully compresses at narrower widths.
- [ ] Recent or unread notifications appear on hover like the user profile and translation menus.
- [ ] Clicking the notification menu keeps it open long enough to use.
- [ ] Notification menu shows unread notifications only.
- [ ] Notification menu has a maximum number of visible items.
- [ ] Translation menu still opens, loads, and is readable.

## Student Notifications

Page: `/notifications`

- [ ] Page is dense, readable, and not overly spaced out.
- [ ] Read notifications have clear styling and are easy to distinguish from unread notifications.
- [ ] Visiting the notifications page marks unread notifications as read.
- [ ] The "Related" column is not shown.
- [ ] Open button appears only when the item can actually be opened.
- [ ] Past-due or invalid survey notifications do not show an Open button.
- [ ] Survey-assignment messages do not say who assigned the survey.
- [ ] Notification copy is plain and clear for students.
- [ ] Notification settings respect the email feature flag.
- [ ] Send email controls are hidden unless email notifications are enabled.
- [ ] Notification settings appear as toggles.

Notification message examples to verify:

- [ ] New competency survey assigned.
- [ ] Competency survey updated.
- [ ] Survey unassigned.
- [ ] Course competency results released.
- [ ] Export ready, if async exports are enabled later.
- [ ] Reminder for incomplete surveys, if reminders are enabled.

## Student Profile And Settings

Pages:

- `/student_profile`
- `/student_profile/edit`
- `/settings`
- `/account`
- `/account/edit`

Check that:

- [ ] Student Profile looks polished and consistent with the rest of the app.
- [ ] Student Profile has only one edit button.
- [ ] The top duplicate edit button is removed.
- [ ] Student Profile Edit uses the same visual layout style as Student Profile.
- [ ] Settings uses the Student Profile layout style.
- [ ] Settings does not show the old account identity block.
- [ ] Settings includes notification settings.
- [ ] Account information lives on `/account`.
- [ ] Account Edit does not duplicate the Settings edit page.
- [ ] Account does not allow users to edit restricted account fields.
- [ ] The Settings button label says Edit where appropriate.
- [ ] Cohort shows only the year, not "Class of YYYY".

## Student My Competencies

Page: `/student_competencies`

Core display:

- [ ] Page is easy to read and navigate.
- [ ] Student can view competencies by semester.
- [ ] Student can view all semesters at once.
- [ ] Timeline or trend visuals render correctly.
- [ ] Student self-assessment competencies are shown.
- [ ] Advisor legacy competencies are shown if they exist.
- [ ] Advisor competencies are clearly labeled as legacy or retiring.
- [ ] Course-derived competencies are shown.
- [ ] Course target competencies are shown.
- [ ] Program target competencies are shown for the correct semester.
- [ ] Course target and end-of-program target are visually distinguishable.
- [ ] Domain-level averages are shown.
- [ ] Strongest domains, lowest domains, and biggest growth areas are summarized.
- [ ] "What changed since last semester?" summaries are understandable.
- [ ] Trend lines show source type where available: self, course, advisor, target.
- [ ] Below-target competencies are highlighted.
- [ ] Missing data, unreleased data, and no course evidence have distinct indicators.
- [ ] Last updated timestamp appears for each competency source.
- [ ] Student-facing interpretation guide is plain language.
- [ ] Print-friendly layout works for advising meetings.

Release-date rules:

- [ ] Course competency data remains hidden before the release date.
- [ ] Course competency data appears after the release date.
- [ ] If no release date exists, course results show immediately.
- [ ] Embargoed results explain why data is not visible yet.

Exports:

- [ ] Student competency CSV export works.
- [ ] Student competency PDF export works if enabled.
- [ ] Exported data matches the on-screen filters.
- [ ] Export includes the correct semester-specific program targets.
- [ ] Export does not include restricted data the student should not see.

## Advisor Dashboard And Navigation

- [ ] Advisor dashboard no longer shows the large Notifications block below feature cards.
- [ ] Advisor notifications still exist in the navbar.
- [ ] Advisor navbar items match dashboard item order.
- [ ] Advisor navbar includes FAQ.
- [ ] Advisor dashboard subtext for Survey Records uses advisor-scoped counts only.
- [ ] Advisor with no advisees sees zero advisee counts.
- [ ] Advisor with advisees sees only their assigned advisee counts.
- [ ] Advisor reports card subtext is meaningful and not "0 generated".
- [ ] Navbar remains usable at smaller viewport widths.

## Advisor Notifications

Check advisor notification creation and display:

- [ ] Advisor receives a notification when an assigned advisee submits a survey.
- [ ] Advisor receives a notification when an assigned advisee edits a submitted survey.
- [ ] Advisor receives a notification when an admin commits or updates batch competency data related to an assigned advisee.
- [ ] Advisor does not receive notifications for students outside their advisee list.
- [ ] Advisor notification page follows the same read/unread rules as student notifications.
- [ ] Advisor notification copy is clear and action-oriented.

## Advisor Student Views

- [ ] Advisor can open detailed competency view for each assigned advisee.
- [ ] Advisor can compare advisee self-assessment scores with course-derived scores.
- [ ] Advisor sees course target and program target context where available.
- [ ] Advisor sees legacy advisor ratings historically.
- [ ] Legacy advisor ratings are read-only and clearly labeled.
- [ ] Advisor cannot misuse or edit retired numeric advisor competency ratings.
- [ ] Advisor sees a students-needing-attention list if available.
- [ ] Students needing attention are based on missing surveys or below-target competencies.
- [ ] Advisor cannot view student-level FERPA data for non-advisees.

## Admin Dashboard And Navigation

- [ ] Admin dashboard no longer shows the large Notifications block below feature cards.
- [ ] Admin notifications still exist in the navbar.
- [ ] Admin dashboard cards have clear counts and subtext.
- [ ] Admin navigation remains usable at smaller viewport widths.
- [ ] FAQ is available where expected.
- [ ] TAMU CAT short name is used where space is tight.
- [ ] Full name, TAMU Competency Assessment Tracking, appears where there is room.
- [ ] New TAMU CAT icon appears where appropriate.
- [ ] TAMU institutional icon remains where it should remain.

## Program Configuration

Page: `/admin/program_setup`

Workspace tabs:

- [ ] Program setup uses actual tabs, not large card buttons.
- [ ] Tracks, Majors, Cohorts, Semesters, and Target Levels are compact.
- [ ] Surface lists show only the item names and useful status.
- [ ] Internal details such as key, position, and cohort year do not show on the surface.
- [ ] Edit modal shows the detail fields.
- [ ] Edit button opens a modal instead of a separate page.
- [ ] Save, cancel, validation, and close behavior work inside the modal.
- [ ] Track position remains editable even though it is hidden on the surface.
- [ ] Cohort year remains editable even though it is hidden on the surface.

Semester ordering:

- [ ] Program semesters can be ordered correctly.
- [ ] App-wide dropdowns honor semester order.
- [ ] Expected order: Fall 2025, Spring 2026, Fall 2026, Spring 2027.
- [ ] Current semester is clear.
- [ ] Current semester is used by default where appropriate.

Program targets:

- [ ] Program target levels can differ by semester.
- [ ] Student graduation timing does not cause the wrong target semester to be used.
- [ ] Students who stay longer in the program compare against the correct semester's target rules.
- [ ] Copy Target to Current Semester button works.
- [ ] Copying targets does not overwrite unexpected semesters without confirmation.
- [ ] Program target exports fill in target values instead of blank columns.

## Survey Builder

Pages:

- `/admin/surveys`
- `/admin/surveys/:id/preview`
- `/admin/survey_change_logs`
- `/assignments/surveys/:id`

Survey list:

- [ ] Active survey summary count cards are removed if they made the page too bulky.
- [ ] Surveys are collapsed or grouped by semester.
- [ ] Survey filter is easy to use and compact.
- [ ] Copy survey opens a modal instead of a new page.
- [ ] Copy survey can copy surveys to a new semester.
- [ ] Copy survey does not assign people.
- [ ] Copied survey preserves questions, sections, categories, options, required flags, and branching rules.
- [ ] Copied survey uses the selected new semester.

Survey preview:

- [ ] Preview is clickable and behaves like the student survey.
- [ ] Preview supports branching.
- [ ] Preview supports "Other" answer text.
- [ ] Preview supports reflection question reveal rules.
- [ ] Preview validates required and invalid answers.
- [ ] Preview shows the submit modal.
- [ ] Preview never saves response data.

Assignments:

- [ ] Student UIN is its own column.
- [ ] Student email is its own column.
- [ ] Assignment page stays readable with many students.

Change logs:

- [ ] Survey change log no longer uses the awkward nowrap table-title styling.
- [ ] Change log filter is compact and useful.
- [ ] Change log table remains readable.

Advisor competency retirement:

- [ ] Advisor text feedback remains visible.
- [ ] Advisor numeric dropdown is no longer displayed where it should be retired.
- [ ] Advisor numeric rating is no longer required for feedback submission.

## Grade Import And Batch Workflow

Pages:

- `/admin/grade_import_batches`
- `/admin/grade_import_batches/:id`

Upload and validation:

- [ ] Canvas import accepts the expected export file.
- [ ] Column-mapping preview appears before import commit.
- [ ] Admin can confirm Canvas columns before import.
- [ ] Result columns map to course competency results.
- [ ] Mastery Points columns map to course target levels.
- [ ] Missing or malformed columns produce clear diagnostics.
- [ ] Missing students produce clear diagnostics.
- [ ] Missing courses produce clear diagnostics.
- [ ] Missing competencies produce clear diagnostics.
- [ ] Bad rows do not block the whole file if partial import is supported.
- [ ] Failed or pending rows can be downloaded as a correction file.
- [ ] Import notes can be saved.
- [ ] Course-code normalization handles inconsistent Canvas course names where supported.
- [ ] Duplicate uploads warn clearly.
- [ ] Duplicate uploads do not create duplicate evidence or ratings.

Review and commit:

- [ ] Admin can review imported rows before commit.
- [ ] Admin can only commit after approval when approval is required.
- [ ] Missing target levels warn before commit.
- [ ] Imported target levels are compared to configured program targets.
- [ ] Admin sees warning when imported target levels differ from configured program targets.
- [ ] Import can be locked or finalized after advisor review if enabled.
- [ ] Commit creates course evidence and derived ratings correctly.
- [ ] Rollback or delete has confirmation language.
- [ ] Rebuild derived ratings button works after fixing an import.
- [ ] Import history shows course, semester, uploader, and commit or rollback status.
- [ ] Admin alerts appear for committed imports with no semester assigned.

Sample files:

- [ ] Successful Canvas sample import works.
- [ ] Pending student match sample behaves as expected.
- [ ] Duplicate upload sample warns as expected.
- [ ] Bad file sample shows useful errors.

## Course Targets And Release Dates

Course targets:

- [ ] Each course competency can have a course-level target.
- [ ] Course target is separate from end-of-program target.
- [ ] Course target appears in student survey side-by-side views where enabled.
- [ ] Course target appears in advisor side-by-side views where enabled.
- [ ] Target met or not met indicators appear per imported course competency.
- [ ] Aggregate target performance by course and semester is correct.
- [ ] Target coverage report identifies courses or competencies with no target.
- [ ] Historical target version tracking works if target levels change after imports.

Release dates:

- [ ] Admin can set course grade release date in the admin dashboard.
- [ ] Admin can bulk edit course release dates by semester.
- [ ] Release-date audit trail records who changed the date and when.
- [ ] Students cannot see unreleased course competency data.
- [ ] Advisors and admins see appropriate release status.
- [ ] Reports can filter by release status.

## Competency Matrix

Page: `/admin/competencies`

- [ ] Page format is polished and readable.
- [ ] Filters are remembered when returning to the matrix.
- [ ] Sticky or quick-jump domain navigation works if present.
- [ ] Filtered CSV export works.
- [ ] CSV export is one student per row.
- [ ] CSV has separate headers for each competency data point.
- [ ] CSV includes self, advisor legacy, course, course target, and program target fields where available.
- [ ] Program target columns are filled for the correct current or selected semester.
- [ ] Program target rules respect each student's correct semester.
- [ ] Advisor legacy ratings do not override course-derived competency ratings.
- [ ] Semester filtering is consistent with student competencies, reports, and exports.

## Reports

Page: `/reports?report_tab=dashboard`

General:

- [ ] Program dashboard is the default first tab.
- [ ] Reports page uses tabs so the page is not too long.
- [ ] Course Target Attainment, Cohort Comparison, and Student by Domain Heatmap are organized together.
- [ ] Heatmaps are readable and can show details.
- [ ] Student/Course Heatmap supports show-details behavior.
- [ ] Course Contribution Report collapses by course.
- [ ] Each report tab has a download option.
- [ ] Each download opens successfully.
- [ ] Exported report data matches current filters.
- [ ] Charts are exportable for program review meetings where supported.

Student Profile report tab:

- [ ] Tab is named Student Profile.
- [ ] Tab matches the Reports page style.
- [ ] No random white blocks appear in name columns.
- [ ] Email is its own column.
- [ ] UIN is its own column.
- [ ] Year is its own column.
- [ ] Cohort shows only the number, not "Class of".
- [ ] Course Evidence, Targets Met, Below Target, and Met Rate columns are removed from this tab if not needed.
- [ ] Student profile export includes profile, Google Sites, and program-review fields.
- [ ] Export includes student information such as name, year, cohort, and Google Site address.

Advisor FERPA rules:

- [ ] Advisors can open program-wide reports that do not expose restricted student details.
- [ ] Advisors see only their own advisees in student-level report data.
- [ ] Advisors cannot export student-level data for non-advisees.
- [ ] Admins can export program-wide student-level data if authorized.

Specific reports:

- [ ] Cohort comparison across semesters works.
- [ ] Course-level report shows which competencies each course contributes to.
- [ ] Competency heatmap works by student, course, track, and semester.
- [ ] Program-level course competency dashboard works by semester, track, and class year.
- [ ] Course target attainment report works.
- [ ] Self-assessment vs course-derived comparison works.
- [ ] Course-code and release-status filters work.

## Survey Records

Pages:

- `/survey_responses`
- role-specific survey record pages

- [ ] Export Excel works.
- [ ] Export opens in Excel or another spreadsheet tool.
- [ ] Actions that were inside the "..." menu are now visible as separate buttons in the student row.
- [ ] Buttons remain on one row without wrapping badly.
- [ ] Student record page has one toolbar, not duplicate toolbars.
- [ ] Survey response PDF export is denser but readable.
- [ ] PDF export includes the expected questions, answers, sections, and metadata.
- [ ] Advisor sees only allowed advisee records.
- [ ] Admin sees all expected records.

## Student Overview

Page: `/student_overviews`

- [ ] Current students and graduated students are separated.
- [ ] Back button and Survey Records placement are swapped as requested.
- [ ] Log on or login label is removed from student overview if present.
- [ ] Class year is its own column.
- [ ] Class year does not show "Class of".
- [ ] Data download button is present.
- [ ] Download opens and contains the expected overview data.
- [ ] Students without track, class year, advisor, or UIN show dashboard warnings where expected.
- [ ] Graduated or archived students do not pollute current-student operational counts.

## People Management

Page: `/people_management`

- [ ] Page is denser without losing key information.
- [ ] Member information remains readable.
- [ ] Student information remains readable.
- [ ] Role controls still work.
- [ ] Advisor assignment controls still work.
- [ ] Track and class-year controls still work.
- [ ] Warnings or confirmations are clear for sensitive changes.

## Student Records And Portfolio

- [ ] Student records include competency snapshot where expected.
- [ ] Portfolio export includes competency summary.
- [ ] Portfolio export includes course target attainment.
- [ ] Advisor notes are tied to competency review meetings.
- [ ] One student full competency history export works.
- [ ] One-click export for all advisees assigned to an advisor works.
- [ ] Advisor export contains only assigned advisees.

## Notifications And Email Feature Flag

- [ ] In-app notifications work when email is disabled.
- [ ] Email notification controls are hidden when the email feature flag is false.
- [ ] Email delivery does not run unless the required environment variables are set.
- [ ] If email is enabled in a test environment, TAMU email notification sends to the expected address.
- [ ] Reminder emails before survey close dates send only when enabled.
- [ ] Audit log records sent email notifications if email is enabled.
- [ ] Notification preferences save correctly.
- [ ] Notification preferences are role-appropriate.

## Data Quality And Maintenance

- [ ] Admin cleanup tools exist for legacy imports without semester values.
- [ ] Reconciliation queue exists for pending imported rows.
- [ ] Archive process exists for old students after graduation.
- [ ] Old advisor competency fields have an archive or retirement policy.
- [ ] Test/sample data resembles production Canvas files.
- [ ] Real Canvas export validation checklist exists.
- [ ] Known bad Canvas strings, domains, and competency names are handled or flagged.
- [ ] Integer validation catches non-integers.
- [ ] Integer validation catches values outside allowed min and max.
- [ ] "Do you mean ___?" suggestions appear if supported.

## Security And Compliance

- [ ] FERPA-sensitive exports are access-restricted.
- [ ] Exporting student-level competency data includes confirmation language.
- [ ] Competency exports are audit logged.
- [ ] Course release date changes are audit logged.
- [ ] Grade import rollback and delete actions are audit logged.
- [ ] Admin import and export pages respect session timeout checks.
- [ ] Advisors cannot access admin-only routes.
- [ ] Students cannot access advisor-only or admin-only routes.
- [ ] Impersonation or view-as modes do not bypass FERPA restrictions.

## Documentation And Training

- [ ] PI/admin Fall competency workflow guide is present and accurate.
- [ ] Advisor quick-start guide is present and accurate.
- [ ] Student FAQ is updated for My Competencies and surveys.
- [ ] Canvas export preparation guide is present.
- [ ] Semester release checklist is present.
- [ ] Troubleshooting guide exists for failed Canvas imports.
- [ ] Technical handoff explains environment variables and database setup.

## Regression Checks

- [ ] Login and logout work for all roles.
- [ ] Admin dashboard loads.
- [ ] Advisor dashboard loads.
- [ ] Student dashboard loads.
- [ ] Existing surveys still load.
- [ ] Existing submitted survey responses still display.
- [ ] Existing exports still download.
- [ ] Existing reports still load.
- [ ] Existing grade imports still display.
- [ ] Existing student profiles still display.
- [ ] Existing account and settings pages still display.

## Optional Or Future V2 Items

Mark these as "available", "deferred", or "not in this release".

- [ ] Canvas API integration optional sync mode.
- [ ] CSV fallback remains available if Canvas API sync is not enabled.
- [ ] AI-assisted syllabus ingestion is available only if intentionally enabled.
- [ ] Syllabus ingestion proposes assignment-to-competency maps with confidence scores.
- [ ] Syllabus ingestion has approve or edit workflow.
- [ ] Benchmark/report integration supports source filters.
- [ ] Cohort and competency trend views support program review.
- [ ] Decision dashboard helps evaluate retirement of manual advisor ratings.

## Issue Log Template

Use this format when reporting defects:

```text
Title:
Role:
Page or URL:
Test data used:
Steps:
Expected:
Actual:
Screenshot or export file:
Severity: blocker / high / medium / low
Notes:
```

## Signoff

- [ ] Student workflow signoff
- [ ] Advisor workflow signoff
- [ ] Admin workflow signoff
- [ ] Reports and exports signoff
- [ ] Import workflow signoff
- [ ] FERPA and permissions signoff
- [ ] Final release-readiness signoff
