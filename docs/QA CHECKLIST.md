# V6 QA Retest Checklist 3.0

Date: June 10, 2026

Purpose: This checklist focuses on the latest 3.0 retest items after the V6 QA 2.0 fixes. It is intended for the reviewer to verify the newest behavior in the deployed dev app and flag anything that still needs follow-up.

## Pre-Test Setup

- [ ] Confirm the reviewer is testing the latest V6 3.0 build on the Heroku dev app.
- [ ] Confirm migrations have been run on the dev app.
- [ ] Confirm the survey assignment completion backfill has been run after any prod-to-dev database copy.
- [ ] Confirm `v6:readiness` passes on the dev app.
- [ ] Test with at least one student, one advisor, and one admin account or impersonated role.

## Student Overview

Pages:

- `/student_overviews`
- `/student_overviews/:id`

Checks:

- [ ] Missing student information appears in the overview stats/warnings area.
- [ ] Missing UIN, track, program year, and advisor are clearly visible.
- [ ] Missing information uses the red reusable status tag.
- [ ] UIN appears on its own line under the student name where expected.
- [ ] Current students and graduated students remain separated.
- [ ] Student Overview download/export still works.
- [ ] Advisor users only see assigned advisees in student-level views.

## Survey Records And Advisor Feedback Autosave

Pages:

- `/survey_records`
- Completed survey response pages opened from Survey Records
- Advisor/admin feedback form for a completed student survey

Checks:

- [ ] Survey Records page loads without legacy route confusion.
- [ ] Unassigned status uses the red reusable status tag.
- [ ] Track and program year labels do not show extra `Track:` or `Program year:` text in the row display.
- [ ] Advisor feedback toolbar is sticky like the student survey toolbar.
- [ ] Advisor feedback Save button is beside Cancel.
- [ ] Advisor feedback autosave message appears beside the Cancel/Save area.
- [ ] Advisor feedback autosave runs while editing feedback fields.
- [ ] Advisor feedback manual Save works without leaving or refreshing the page.
- [ ] Advisor feedback final Submit shows a confirmation modal before submitting.
- [ ] Student survey responses are read-only when an advisor/admin is giving feedback.
- [ ] Read-only student response fields look visually read-only, not like editable controls.
- [ ] Confidential advisor notes section is visible where expected.
- [ ] Confidential advisor notes save correctly.
- [ ] Confidential advisor notes are not visible to the student.

With **Enable advisor numeric ratings** on:

- [ ] Advisor numeric score fields are visible.
- [ ] Existing real advisor score values prefill when editing.
- [ ] Empty advisor score values stay empty when no real values exist.
- [ ] Autosave saves numeric ratings, text feedback, and confidential notes.
- [ ] Submit saves numeric ratings, text feedback, and confidential notes.

With **Enable advisor numeric ratings** off:

- [ ] Advisor numeric score fields are hidden.
- [ ] Autosave still saves text feedback and confidential notes.
- [ ] Submit still saves text feedback and confidential notes.
- [ ] Hidden numeric rating fields do not create fake/default advisor scores.

Access control:

- [ ] Students cannot access the feedback route.
- [ ] Non-faculty/non-advisor users cannot access advisor feedback routes.
- [ ] Unauthorized feedback access redirects or shows a clear access-denied message.

## Mobile

Pages to spot-check in Chrome device view:

- Student Dashboard
- My Competencies
- Survey Records
- Student Overview
- Advisor Dashboard
- Admin Dashboard
- Reports dashboard
- Program Configuration

Checks:

- [ ] Mobile navbar opens and closes reliably.
- [ ] Mobile navbar links are clickable.
- [ ] Top navigation does not split into unusable rows.
- [ ] All wide tables scroll horizontally instead of breaking the page.
- [ ] All charts are visible on mobile.
- [ ] Charts that are too wide are scrollable on mobile.
- [ ] Report dashboard charts are readable in mobile view.
- [ ] My Competencies charts are not cut off.
- [ ] Sticky/floating toolbars do not block form fields on mobile.

## Exports

Checks:

- [ ] All CSV exports open with readable column headers.
- [ ] All Excel exports open with readable sheet names and column headers.
- [ ] Excel sheets avoid ambiguous duplicate names such as `Survey (1)` when semester context is available.
- [ ] Exports include current filters when the page has filters.
- [ ] Student-level exports show FERPA confirmation language before download.
- [ ] Survey Records export includes expected student, survey, completion, and feedback fields.
- [ ] Student Overview export includes expected student profile fields.
- [ ] Reports Excel exports include raw data as well as summary/chart data where applicable.
- [ ] Exported values are not visually truncated in normal spreadsheet viewing.
- [ ] Exports do not include retired/legacy fields unless intentionally retained.

## PDF

Checks:

- [ ] Survey response PDF is readable and professionally formatted.
- [ ] Survey response PDF is compact without losing key details.
- [ ] Survey response PDF includes advisor feedback when feedback exists.
- [ ] Survey response PDF omits blank advisor rating sections when no advisor rating exists.
- [ ] Survey response PDF includes the completed survey target summary stats card.
- [ ] Survey response PDF does not include the removed `ANSWERED 25/44` progress block.
- [ ] Dashboard/report PDF export is readable.
- [ ] Dashboard/report PDF export includes the expected charts.
- [ ] PDF content does not overlap or cut off on normal page sizes.

## Notifications Rework

Pages:

- `/notifications`
- Navbar unread notifications menu
- Settings notification preferences

Checks:

- [ ] Notification preferences save correctly.
- [ ] Turning off in-app notifications hides unread items from the navbar and notification center.
- [ ] Turning in-app notifications back on restores notification display.
- [ ] Visiting `/notifications` marks unread notifications as read.
- [ ] Read notifications have clear styling.
- [ ] Navbar only shows unread notifications.
- [ ] Navbar notification list has a reasonable maximum size.
- [ ] Notification Open button only appears when the linked item can still be opened.
- [ ] Survey assigned notification is clear and does not name the assigning user.
- [ ] Survey unassigned notification appears only the first time a survey is unassigned.
- [ ] Advisor receives a notification when an advisee submits a survey.
- [ ] Advisor receives a notification when an advisee edits a submitted survey.
- [ ] Advisor receives notifications for later survey edits, not only the first edit.
- [ ] Advisor receives a notification when admin commits or updates batch data related to assigned advisees.
- [ ] Advisor does not receive student-level notifications for non-advisees.
- [ ] Student receives a notification when advisor/admin feedback is newly submitted.
- [ ] Student receives a notification when advisor/admin feedback is revised and the content actually changed.
- [ ] Duplicate notifications are not created for the same event when dedupe rules should apply.
- [ ] Notification text is clear, student-facing where appropriate, and does not expose unnecessary internal details.

## Program Configuration UI

Page:

- `/admin/program_setup`

Checks:

- [ ] Page layout is compact and readable.
- [ ] Workspace areas use tabs instead of large card buttons.
- [ ] Create actions open in modals.
- [ ] Edit actions open in modals.
- [ ] Modal layout is clean and consistent with the app style.
- [ ] Modal Save, Cancel, validation, and close behavior work correctly.
- [ ] Track position remains editable inside the modal.
- [ ] Cohort/program year position remains editable inside the modal.
- [ ] Surface cards do not show internal keys/positions unless intentionally edited.
- [ ] Drag-and-drop reorder works for tracks.
- [ ] Drag-and-drop reorder works for cohorts/program years.
- [ ] After reorder, the modal position values reflect the new order.
- [ ] Semester order is honored in dropdowns app-wide.
- [ ] Only one current semester can be selected at a time.
- [ ] Semester modal does not show duplicate "Make current semester" controls.
- [ ] Course Targets tab loads without a 500 error.
- [ ] Course target controls remain usable after the UI changes.

## Final Regression

- [ ] Run the model/controller test suite.
- [ ] Run system tests that cover survey completion, advisor feedback, notifications, reports, and Program Configuration if available.
- [ ] Run Brakeman.
- [ ] Run RuboCop or project lint checks if used before release.
- [ ] Confirm the Heroku dev app has the expected branch/build deployed.
- [ ] Confirm the reviewer's failed 2.0 checklist items were either fixed or intentionally moved out of scope.
