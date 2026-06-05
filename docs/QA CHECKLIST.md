# V6 QA Retest Checklist 2.0

Date: June 5, 2026

Purpose: This list keeps only the items that did not pass, were unclear, or need another verification pass after the V6 2.0 fixes. Passed 1.0 items were removed so Gary can focus on retesting.

## Grade Import

- [ ] Upload `Outcomes-26_SPRING_PHPM_633_700__HEALTH_LAW__ETHICS.csv` and confirm students match correctly.
- [ ] Upload `Outcomes-26S-PHPM-601.csv` and confirm students match correctly.
- [ ] Upload `2026_comp.xlsx` and confirm the import page does not crash.
- [ ] Confirm a folder upload with mixed valid and invalid files does not crash the whole batch.
- [ ] Confirm invalid files can be reviewed, corrected, removed, or left pending without blocking valid files.
- [ ] Confirm `Result` columns are treated as individual student competency results.
- [ ] Confirm `Mastery Points` columns are treated as course target competency levels.
- [ ] Commit one semester of course competency data and confirm the data appears in reports, student competencies, and exports.

## Mobile View

- [ ] Check the major student, advisor, and admin pages in desktop and narrow/mobile viewport.
- [ ] Confirm the mobile navbar uses a hamburger/drawer pattern when space is tight.
- [ ] Confirm the hamburger opens, closes, and links are clickable in Chrome device view.
- [ ] Confirm the top navbar does not split into multiple rows on narrow screens.
- [ ] Confirm Student Dashboard is readable on mobile.
- [ ] Confirm My Competencies is readable on mobile.
- [ ] Confirm Advisor Dashboard is readable on mobile.
- [ ] Confirm Admin Dashboard is readable on mobile.
- [ ] Confirm the My Competencies circle chart is not cut off on mobile.
- [ ] Confirm wide tables scroll horizontally without breaking the page.

## Survey Completion

- [ ] Save Progress saves without leaving or refreshing the survey page.
- [ ] Save Progress does not conflict with final Submit.
- [ ] Cancel or save-on-exit preserves answers when the student returns.
- [ ] Autosave runs after dropdown and multiple-choice changes.
- [ ] Autosave runs less frequently for text/free-response answers.
- [ ] Autosave status in the floating toolbar changes when answers are edited, saved, or fail to save.
- [ ] Manual Save and Autosave use the same save behavior but show different status messages.
- [ ] Manual Save does not create duplicate versions when nothing changed after autosave.
- [ ] Final Submit creates the submitted survey version.
- [ ] Edit Submit creates a new version only when answers changed from the last submitted version.
- [ ] Preview Submit runs the same validation as the real survey.
- [ ] Preview Submit validates required evidence links the same way the real survey does.
- [ ] Preview Submit shows the same confirmation modal as the real survey but does not save data.
- [ ] Real Submit shows the correct confirmation modal.
- [ ] Edit Submit modal does not mention Save Progress if that action is not available.
- [ ] Heads-up messages fade and close automatically after a few seconds.
- [ ] Heads-up message close buttons work.

## Survey Branching

- [ ] Children of "Are you currently employed?" only appear after the responder selects Yes.
- [ ] If Yes is selected, the employment follow-up questions appear in the correct order.
- [ ] If No is selected, employment follow-up questions stay hidden and are not required by page validation.
- [ ] Required behavior follows the survey builder question settings rather than hard-coded rules.
- [ ] "Other" under "How flexible are your work hours?" shows a text box when selected.
- [ ] The "Other" text answer is saved with the rest of the survey response.
- [ ] Reflection questions appear only after a real assessment dropdown option is selected.
- [ ] Reflection questions are optional unless manually marked required in the survey builder.
- [ ] Branching works in student survey completion.
- [ ] Branching works in admin survey preview.

## Navigation Bar And Translation

- [ ] Translation menu opens on hover/click and remains readable.
- [ ] Translation language list loads reliably.
- [ ] Selecting a language translates the page.
- [ ] "Show original" restores English and resets the app dropdown to English.
- [ ] Translation works without any paid AI/API translation feature.
- [ ] FAQ appears in the navbar for students.
- [ ] FAQ appears in the navbar for advisors.
- [ ] FAQ appears in the navbar for admins.
- [ ] Admin Dashboard includes FAQ access where expected.
- [ ] TAMU CAT short name is used where nav space is tight.
- [ ] TAMU Competency Assessment Tracking full name is used where space allows.
- [ ] The new TAMU CAT icon appears where appropriate.
- [ ] The official TAMU icon remains where the app should still show the TAMU icon.

## Notifications

- [ ] Read notifications have clear styling on `/notifications`.
- [ ] Visiting `/notifications` marks unread notifications as read.
- [ ] Unread notifications are the only notifications shown in the navbar menu.
- [ ] Notification navbar menu has a reasonable maximum number of items.
- [ ] Survey assignment notifications do not say which person assigned the survey.
- [ ] Survey unassignment notification appears only the first time a survey is unassigned.
- [ ] Notification Open button appears only when the related item can still be opened.
- [ ] In-app notification preferences can be turned off in Settings.
- [ ] In-app notification preferences save correctly.
- [ ] When in-app notifications are off, unread items do not appear in the navbar or notification center.
- [ ] Advisor receives a notification when an assigned advisee submits a survey.
- [ ] Advisor receives a notification when an assigned advisee edits a submitted survey.
- [ ] Advisor receives notifications for later edits, not only the first edit.
- [ ] Advisor receives a notification when admin commits or updates batch competency data related to assigned advisees.
- [ ] Advisor does not receive notifications for students outside their advisee list.
- [ ] Admin notifications remain available in the navbar but are not duplicated on the admin dashboard.
- [ ] Advisor notifications remain available in the navbar but are not duplicated on the advisor dashboard.

## Email Notification Feature Flag

- [ ] Email notification controls are hidden unless `EMAIL_NOTIFICATIONS_ENABLED` is true.
- [ ] If email is disabled, no email is sent.
- [ ] If email is enabled in a test environment, survey notification email sends to the expected TAMU email address.
- [ ] Reminder emails before survey close dates send only when email notifications are enabled.
- [ ] Sent email notifications are recorded in the audit log when email is enabled.

## Student Competencies

- [ ] My Competencies is easier to read and navigate.
- [ ] Advisor competency ratings are clearly labeled as legacy/retiring near the main graph or score display.
- [ ] Course target competencies are visible when course data includes targets.
- [ ] Course target and end-of-program target are distinguishable in student-facing views.
- [ ] Domain overview colors compare against the correct program target for that student and semester.
- [ ] Graduated students compare against the correct historical target semester.
- [ ] Students who remain in the program longer compare against the correct target rules.
- [ ] Imported course results are collapsed by course where expected.
- [ ] Course result details can still be expanded or inspected.

## Advisor Views

- [ ] Advisor-facing competency views only show assigned advisees when student-level data is shown.
- [ ] Advisor reports honor FERPA restrictions for student-level data.
- [ ] Advisor dashboard navbar order matches dashboard feature card order.
- [ ] Survey Records subtext for advisors reflects only assigned advisee numbers.
- [ ] Advisor account with zero assigned advisees does not show global student counts.
- [ ] Advisor confidential notes are tied to the correct student and survey/competency review.
- [ ] Advisor confidential notes are visible where expected in student overview or survey review.
- [ ] Advisor confidential notes are not visible to students.

## Admin Dashboard And Program Configuration

- [ ] Program Configuration workspace tabs are actual compact tabs, not large card buttons.
- [ ] Edit button opens a modal instead of a separate page.
- [ ] Edit modal shows the detail fields.
- [ ] Save, cancel, validation, and close behavior work inside the modal.
- [ ] Track position remains editable in the modal even though hidden on the surface.
- [ ] Cohort/program year remains editable in the modal even though hidden on the surface.
- [ ] Program semesters can be ordered correctly.
- [ ] Semester dropdowns app-wide honor program semester order.
- [ ] Confirm expected semester order when configured: Spring 2025, Fall 2025, Spring 2026, Fall 2026, Spring 2027.
- [ ] Course target competency configuration appears in Program Configuration if expected.
- [ ] Course target competency edit controls use the same modal pattern as the rest of Program Configuration.

## Survey Builder

- [ ] Active survey summary count cards are removed from Survey Builder if they made the page bulky.
- [ ] Survey filter on `/admin/surveys` is compact and usable.
- [ ] Survey change log filter on `/admin/survey_change_logs` is compact and usable.
- [ ] Survey change log table no longer has awkward nowrap title styling.
- [ ] Copy survey opens a modal instead of a new page.
- [ ] Copy survey works from `/admin/surveys`.
- [ ] Copy survey can copy a survey to a new semester.
- [ ] Copy survey does not assign students or advisors.
- [ ] Copied survey preserves sections.
- [ ] Copied survey preserves categories.
- [ ] Copied survey preserves questions.
- [ ] Copied survey preserves options.
- [ ] Copied survey preserves required flags.
- [ ] Copied survey preserves branching rules.
- [ ] Copied survey uses the selected new semester.
- [ ] Survey assignment page shows student UIN and email as their own columns.
- [ ] Admin survey preview is clickable and submittable without saving data.

## Competency Matrix

- [ ] Filters are remembered when returning to the matrix from another page.
- [ ] Remembered filters do not depend only on the URL staying unchanged.
- [ ] Student Competency Matrix shows domain and all competencies with each score.
- [ ] Removed summary/stat cards do not reappear.
- [ ] Domain jump navigation is no longer treated as a requirement unless it is intentionally restored.
- [ ] Competency matrix CSV export uses one student per row.
- [ ] Competency matrix CSV includes self, advisor, course, course target, and program target values where available.
- [ ] Program Target in the CSV uses the correct semester-specific target rules.

## Reports

- [ ] Program dashboard is the default first tab at `/reports?report_tab=dashboard`.
- [ ] Program dashboard reflects current filters.
- [ ] All report exports honor the filters currently applied on the page.
- [ ] Excel exports include raw data in addition to summary/chart data where applicable.
- [ ] Dashboard PDF export is available at the top of the Dashboard tab.
- [ ] Dashboard PDF export includes all dashboard charts.
- [ ] Duplicate per-module Excel buttons are removed when the top-level download exists.
- [ ] Heatmap column headers stay visible while scrolling.
- [ ] Course heatmap uses the sticky table header format.
- [ ] Course heatmap replaces the old Student/Course Heatmap where expected.
- [ ] Cohort comparison report shows semester context.
- [ ] Domain heatmap/report has filters for student, course, track, and semester where expected.
- [ ] Program-level dashboard supports semester, track, and class year filters.
- [ ] Self-Assessment vs Course-Derived Scores tab is removed from expected testing unless intentionally restored.
- [ ] Exporting student-level competency data shows clear FERPA confirmation language before download.

## Student Profile Export

- [ ] Student Profile export includes profile fields.
- [ ] Student Profile export includes Google Sites URL.
- [ ] Student Profile export includes program-review fields.
- [ ] Student Profile export includes UIN.
- [ ] Student Profile export includes name.
- [ ] Student Profile export includes email.
- [ ] Student Profile export includes track.
- [ ] Student Profile export includes year.
- [ ] Student Profile export includes advisor.
- [ ] Student Profile export does not include the removed Cohort column.
- [ ] Student Profile export includes course evidence summary fields where expected.
- [ ] Student Profile export honors current report filters.

## Survey Records

- [ ] `/survey_records` opens the Survey Records page.
- [ ] `/student_records` redirects or routes correctly to Survey Records.
- [ ] `/survey_responses` does not 404 when used as a legacy list URL.
- [ ] Individual survey response pages still open at the expected response URL.
- [ ] Survey Records Excel export works.
- [ ] Survey Records export honors current filters.
- [ ] Survey Records actions appear as direct buttons in the same row as the student.
- [ ] The extra toolbar/card in student record views is removed.

## Student Overview

- [ ] Student Overview separates current students and graduated students.
- [ ] Student Overview data download button works.
- [ ] Student Overview export honors current filters.
- [ ] Students without track show dashboard warnings where expected.
- [ ] Students without class year/program year show dashboard warnings where expected.
- [ ] Students without advisor show dashboard warnings where expected.
- [ ] Students without UIN show dashboard warnings where expected.
- [ ] Student overview does not show misleading global counts for advisor users.

## People Management

- [ ] People Management is denser without losing key information.
- [ ] Track controls still work.
- [ ] Class year/program year controls are present and work.
- [ ] Promoting a user to admin shows a clear confirmation.
- [ ] Demoting an admin shows a clear confirmation.
- [ ] Sensitive role changes use clear warning language.

## Account And Settings

- [ ] `/account` is read-only.
- [ ] `/account/edit` is the only account edit page.
- [ ] Student account details include editable student profile fields on `/account/edit`.
- [ ] Student account read-only view includes identity and student program details in separate cards.
- [ ] Student profile legacy routes are removed or redirect cleanly.
- [ ] `/settings` is read-only.
- [ ] `/settings/edit` contains editable settings fields.
- [ ] `/settings` has bottom Cancel and Edit buttons.
- [ ] `/settings` does not show an Open Notifications button.
- [ ] Account and Settings share a side tab/navigation area.
- [ ] Account and Settings side tabs appear on separate rows.
- [ ] Sidebar includes Sign Out.
- [ ] In-app notification setting appears only once on Settings.
- [ ] In-app notification toggle can be changed without editing unrelated fields.

## Security And FERPA

- [ ] Advisors cannot access admin-only routes.
- [ ] Advisor access denial redirects gracefully instead of showing a confusing 404 where possible.
- [ ] Students cannot access advisor-only or admin-only routes.
- [ ] Student access denial messages consistently say the page is only available to administrators/advisors where applicable.
- [ ] Advisor pages that show advisor-accessible data but live under `/admin/...` do not expose admin-only behavior.
- [ ] Student-level exports require FERPA confirmation language before download.
- [ ] Admin import and export pages respect the 30-minute inactivity/session timeout.
- [ ] Session timeout applies consistently across roles.

## Documentation And Training

- [ ] PI/admin Fall competency workflow guide is current.
- [ ] Advisor quick-start guide is current.
- [ ] Student FAQ is current.
- [ ] Student FAQ no longer overemphasizes retiring advisor numeric scores.
- [ ] Canvas export preparation guide is current.
- [ ] Semester release checklist is current.
- [ ] Troubleshooting guide for failed Canvas imports is current.
- [ ] Technical handoff has current database, sync, migration, and environment-variable notes.

## Data Quality And Maintenance

- [ ] Admin cleanup tools exist for legacy imports without semester values or equivalent cleanup workflow is documented.
- [ ] Reconciliation queue for pending imported rows works.
- [ ] Pending student match workflow is clear.
- [ ] Duplicate imports do not create duplicate evidence or ratings.
- [ ] Duplicate upload warnings are clear.
- [ ] Bad Canvas strings, domains, or competency names produce actionable validation messages.
- [ ] Integer validation catches non-integers.
- [ ] Integer validation catches values below minimum.
- [ ] Integer validation catches values above maximum.
- [ ] "Do you mean..." suggestions appear where expected for likely import mismatches.
- [ ] Test/sample data matches the three accepted production Canvas formats.

## Final Regression

- [ ] Run the model/controller test suite.
- [ ] Run system tests if available for survey completion, preview, notifications, reports, and import workflows.
- [ ] Run Brakeman.
- [ ] Run RuboCop or project lint checks if used before release.
- [ ] Confirm deployed Heroku dev branch has migrations applied.
- [ ] Confirm V6 2.0 retest build is the version Gary is testing.
