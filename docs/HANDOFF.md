# Handoff Guide

## Purpose

This document is the quick-start handoff for the next engineer or admin owner of TAMU Competency Assessment Tool.

The app is in a stable place for day-to-day use. The most important areas to understand first are:

- role-based dashboards
- survey lifecycle management
- reporting
- grade import batches
- program configuration
- people management

## Current state

The application supports three main user roles:

- `student`
- `advisor`
- `admin`

The most operationally important admin areas are:

- `People Management`
- `Program Configuration`
- `Survey Builder`
- `Grade Import Batches`
- `Competencies`
- `Student Records`
- `Reports`

## Recommended first read order

1. [README.md](../README.md)
2. [docs/TECHNICAL_HANDOFF.md](TECHNICAL_HANDOFF.md)
3. [docs/ADMIN_WALKTHROUGH.md](ADMIN_WALKTHROUGH.md)
4. [docs/ARCHITECTURE_MAP.md](ARCHITECTURE_MAP.md)
5. [docs/GRADE_IMPORTS.md](GRADE_IMPORTS.md)
6. [docs/PERMISSIONS_AUDIT.md](PERMISSIONS_AUDIT.md)
7. [docs/KNOWN_ISSUES.md](KNOWN_ISSUES.md)
8. [docs/NEXT_STEPS.md](NEXT_STEPS.md)

## Local development

The project can run locally with Docker.

Useful commands:

```bash
docker compose up --build
docker compose exec -T web bin/rails db:prepare
docker compose exec -T web bin/rails runner 'puts :ok'
```

If you need realistic student data for import testing, it is helpful to restore a production backup into local development rather than relying only on seeds.

Important:

- never write directly to production during testing
- use a local restored copy for import validation
- keep `dry run` on until you are ready to publish a batch

## Operational concepts

### Surveys

- surveys are assigned by program context and completed by students
- advisors review responses and provide feedback
- reports aggregate survey and feedback data

### Course competency imports

- grade-derived competency data is separate from advisor feedback
- imported course ratings appear as an additional source
- imports are processed through `Grade Import Batches`

### Program configuration

- program tracks, majors, cohorts, semesters, and competency target levels are managed under `Program Configuration`

### People management

- member role changes and student assignment changes live under `People Management`

## Most important admin workflows

### Grade import workflow

1. open `Admin > Grade Import Batches`
2. upload files
3. run as `dry run`
4. inspect matched rows, pending rows, duplicates, and errors
5. commit the dry run when the results look correct
6. use rollback only if the batch must be fully removed

See [docs/GRADE_IMPORTS.md](GRADE_IMPORTS.md) for details.

### Competencies review workflow

Use `Admin > Competencies` to compare:

- self ratings
- advisor ratings
- course ratings

Filters now support:

- student search
- track
- class
- advisor
- semester
- domain
- multi-select competency checkbox picker

### Student records workflow

Use `Student Records` for semester-by-semester survey review with:

- progress status
- feedback visibility
- advisor feedback / imported course-derived display
- PDF / Excel exports

## Handoff priorities for the next owner

The next owner should verify these workflows early:

1. sign in for each role
2. survey assignment and completion
3. advisor feedback save / edit
4. reports load successfully
5. grade import dry run and commit
6. pending student reconciliation after account creation

## Where business rules live

- survey / competency reporting rules: `app/services/reports/`
- admin competency matrix: `app/services/admin/competency_matrix.rb`
- grade import processing: `app/services/grade_imports/`
- batch import UI: `app/controllers/admin/grade_import_batches_controller.rb`
- people management dashboard: `app/views/dashboards/people_management.html.erb`
- program configuration UI: `app/views/admin/program_setups/`

## Handoff notes

- prefer extending existing `c-` design-system classes instead of adding more one-off Tailwind utility chains
- preserve the separation between advisor feedback and grade-derived competency ratings
- keep duplicate protection and pending-row reconciliation intact when changing import behavior
- when in doubt, test with dry runs and sample files first
