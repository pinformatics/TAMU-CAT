# Admin Walkthrough

## Purpose

This is the practical page-by-page walkthrough for the admin role.

Use it when:

- onboarding a new admin owner
- demoing the app
- sanity-checking the most important workflows after changes

## Suggested smoke-test order

1. `Admin Dashboard`
2. `People Management`
3. `Program Configuration`
4. `Survey Builder`
5. `Grade Import Batches`
6. `Competencies`
7. `Survey Records`
8. `Reports`

## Admin Dashboard

The admin dashboard is the launch point for operational work.

Check that:

- the main cards render
- navigation links work
- recent notifications and summary counts load

## People Management

Use this area for:

- member role changes
- student advisor assignment
- student track / assignment-group changes

Tabs:

- `Members`
- `Students`

Check that:

- role changes save
- self-role changes are blocked
- student assignment controls only appear for admins

## Program Configuration

This combines:

- program structure
- competency targets

Sections:

- `Tracks`
- `Majors`
- `Cohorts`
- `Semesters`
- `Competency Targets`

Check that:

- create/edit/delete actions work
- active/inactive states display correctly
- target levels save under the correct program context

## Survey Builder

Use this area to:

- create surveys
- manage questions
- edit settings and availability
- review survey audit/change history

Check that:

- active and archived surveys both load
- question create/edit flows work
- preview and availability changes do not break assignments

## Grade Import Batches

This is the admin workspace for course-derived competency imports.

Supported formats:

- mapping workbook with grade sheet + mapping sheet
- direct competency CSV / XLSX / XLSM

Recommended workflow:

1. upload as `dry run`
2. inspect `File Results`
3. inspect `Pending Student Matches`
4. inspect `Derived Competency Ratings`
5. inspect `Evidence Preview`
6. commit only when correct

Important behaviors:

- duplicate protection suppresses repeat imports
- dry runs are hidden from downstream course-rating views
- committed batches can be rolled back and recommitted
- unmatched students can be stored as pending rows

If a batch shows no evidence:

- check duplicate-suppressed counts first
- then check row-level errors

## Competencies

Use this area to compare:

- self ratings
- advisor ratings
- course-derived ratings

Filters include:

- student search
- competency checkbox select
- track
- class
- advisor
- domain
- semester

Check that:

- domain accordions expand/collapse
- course ratings only appear from reportable batches
- semester filtering is clear to the operator

## Survey Records

Use this area to review semester-by-semester survey progress.

Check that:

- search and semester grouping work
- review links open
- exports still work
- advisor feedback and imported course-derived values remain separate

## Reports

Use reports for program-level analysis and exports.

Check that:

- filters load
- charts/cards render
- exports still succeed

## Common admin mistakes

### Importing the same file twice

Expected result:

- rows are suppressed as duplicates
- later preview sections can look empty

### Forgetting to commit a dry run

Expected result:

- batch preview looks correct
- course ratings do not appear in competencies or downstream views

### Rolling back a committed batch

Expected result:

- the batch is hidden from downstream views
- recommit is available for soft-rolled-back batches

## Fast operator checklist

When something looks wrong, check these first:

1. Is the batch still a `dry run`?
2. Was the same file already imported?
3. Are student identifiers present?
4. Are there row-level parse errors?
5. Is the batch `rolled_back`?
