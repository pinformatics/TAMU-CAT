# Agent Brief

This is the short starting point for AI agents working on the MHA Survey Portal / TAMU Competency Assessment Tool.

## Current Goal

The near-term release goal is to push the development version by Labor Day, September 7, 2026.

Current priority order:

1. Make large grade/course import uploads reliable on Heroku.
2. Apply requested reporting changes after reviewing the current requirements.
3. Keep release docs, smoke checks, and handoff notes short enough for the next engineer to use.

## Project Shape

- Rails app with Docker-based local development.
- Main roles: `student`, `advisor`, `admin`.
- Important admin areas: Grade Import Batches, Reports, Survey Builder, Competencies, Program Configuration, People Management.
- Imported course competency data must stay separate from advisor feedback.
- Dry-run import review is an intentional safety step; do not bypass it unless the user explicitly asks.

## Start Here

Read only what matches the task:

- General setup: [README.md](../README.md)
- Architecture map: [ARCHITECTURE_MAP.md](ARCHITECTURE_MAP.md)
- Grade imports: [GRADE_IMPORTS.md](GRADE_IMPORTS.md)
- Failed imports: [FAILED_IMPORT_TROUBLESHOOTING.md](FAILED_IMPORT_TROUBLESHOOTING.md)
- Reports, known risks, and full handoff context: [TECHNICAL_HANDOFF.md](TECHNICAL_HANDOFF.md)

## Local Workflow

Use Docker by default; the host machine may not have Ruby installed.

Common commands:

```bash
docker compose up -d
docker compose run --rm web bin/rails db:prepare
docker compose run --rm web bin/rails test path/to/test_file.rb
docker compose run --rm web bin/rubocop path/to/file.rb
```

Health check:

```bash
curl http://localhost:3000/up
```

On Windows PowerShell, use `Invoke-WebRequest -UseBasicParsing http://localhost:3000/up`.

## Environment Notes

- Local secrets live in ignored `.env`; never print OAuth/client secrets in output.
- Google OAuth requires `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` inside the Docker `web` container.
- If OAuth env vars change, recreate the container: `docker compose up -d --force-recreate web css`.
- Heroku dev currently has memory pressure around imports. Bigger dyno or separate worker may still be needed after code-level mitigations.
- If using a separate Heroku worker dyno, Active Storage must use durable shared storage such as S3/Azure/GCS; local disk is not shared across dynos.

## Grade Import Context

Important files:

- [app/controllers/admin/grade_import_batches_controller.rb](../app/controllers/admin/grade_import_batches_controller.rb)
- [app/jobs/grade_imports/batch_import_job.rb](../app/jobs/grade_imports/batch_import_job.rb)
- [app/services/grade_imports/batch_processor.rb](../app/services/grade_imports/batch_processor.rb)
- [app/services/grade_imports/file_upload_router.rb](../app/services/grade_imports/file_upload_router.rb)
- [app/services/grade_imports/stale_batch_watchdog.rb](../app/services/grade_imports/stale_batch_watchdog.rb)

Current behavior:

- Uploads are stored on `GradeImportFile#source_file`.
- The background job receives `grade_import_file_ids`, not base64 spreadsheet payloads.
- Canvas outcomes `.xlsx` parsing uses `creek` streaming for lower memory.
- A memory guard can pause and auto-resume large imports.
- A stale-batch watchdog catches dyno kills that bypass Ruby exception handling.

When changing imports, protect:

- duplicate suppression by checksum/source key/import fingerprint
- pending unmatched student rows
- dry-run commit/rollback behavior
- semester scoping on batch-derived course ratings

## Reports Context

Important files:

- [app/controllers/reports_controller.rb](../app/controllers/reports_controller.rb)
- [app/services/reports/data_aggregator.rb](../app/services/reports/data_aggregator.rb)
- [app/services/reports/excel_exporter.rb](../app/services/reports/excel_exporter.rb)
- [app/views/reports/show.html.erb](../app/views/reports/show.html.erb)
- [app/javascript/reports/app.js](../app/javascript/reports/app.js)

When changing reports, verify filters and exports. Course-derived ratings should remain distinguishable from self/advisor ratings.

## Testing Guidance

For a focused change, run the matching test file(s) plus RuboCop on touched Ruby files. Broaden to the full suite when changing shared models, report aggregation, import processing, auth, or migrations.

Useful focused tests:

- `test/jobs/grade_imports/batch_import_job_test.rb`
- `test/services/grade_imports/batch_processor_test.rb`
- `test/controllers/admin/grade_import_batches_controller_test.rb`
- `test/controllers/reports_controller_test.rb`
- `test/services/reports/data_aggregator_*_test.rb`

## Collaboration Notes

- Preserve user changes in the working tree.
- Prefer small, testable changes over broad rewrites before the September 7, 2026 dev push.
- Keep docs short and route to deeper docs instead of duplicating long explanations.
- When summarizing for the team, lead with what changed, what was verified, and what still needs Heroku/dev-app testing.
