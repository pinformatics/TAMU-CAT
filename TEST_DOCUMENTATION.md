# Test Suite Documentation

## Overview

This document summarizes the test suite for TAMU Competency Assessment Tool. The suite covers model behavior, controller access rules, integration workflows, system-level UI checks, and high-risk Fall competency workflows such as imports, reports, exports, release dates, and student/advisor competency views.

## Test Structure

The `test/` directory is organized into:

- `models/`: Active Record validations, associations, lifecycle behavior, and scopes.
- `controllers/`: request/response behavior, redirects, authorization, exports, and admin workflows.
- `integration/`: multi-step user workflows that cross controllers and models.
- `system/`: browser-driven UI checks through Capybara.
- `services/`: import processing, reports, dashboards, notifications, and export helpers.
- `fixtures/`: stable YAML records shared across tests.
- `test_helper.rb`: test configuration and shared helpers.

## Running Tests

Run all tests locally when Ruby is available:

```bash
ruby run_tests.rb
```

Run all tests through Docker, which is the preferred onboarding path:

```bash
docker compose run --rm -T -e RAILS_ENV=test web ruby run_tests.rb
```

Run a focused file or folder:

```bash
bin/rails test test/models
bin/rails test test/controllers/admin/grade_import_batches_controller_test.rb
bin/rails test test/services/student_competency_dashboard_test.rb
```

Run with coverage:

```bash
ruby run_tests.rb -c
```

## High-Value Smoke Slices

For competency/import changes, run this focused slice before the full suite:

```bash
bin/rails test \
  test/services/student_competency_dashboard_test.rb \
  test/controllers/student_competencies_controller_test.rb \
  test/controllers/admin/grade_import_batches_controller_test.rb \
  test/services/grade_imports/batch_processor_test.rb \
  test/services/reports/course_competency_report_test.rb \
  test/services/course_competency_release_notifier_test.rb
```

For role/access changes, prioritize:

```bash
bin/rails test test/controllers/dashboards_controller_test.rb test/controllers/admin
```

## Test Data Notes

- Some models use nonstandard primary keys, especially `students.student_id`, `advisors.advisor_id`, and `admins.admin_id`.
- Import tests often create temporary workbooks and CSVs; keep cleanup in `teardown`.
- Production-like import validation is strongest against a sanitized production clone because student matching depends on real UINs, accounts, and course naming patterns.
- Keep fixtures small and predictable. Prefer factories or explicit records inside tests when a scenario needs special state.

## Common Failure Areas

- Missing or mismatched fixture associations.
- Devise authentication helpers omitted from controller/integration tests.
- Course import rows missing canonical competency links after parser changes.
- Semester filters that include self/advisor data but accidentally omit reportable course imports.
- Tests relying on host Ruby when Docker should be used.

## CI Expectations

CI should run Rails tests, RuboCop, Brakeman, and importmap audit before merge. Locally, the Docker command above is the fastest way to confirm the Rails suite without installing Ruby on the host.

Updated: 2026-05-26
