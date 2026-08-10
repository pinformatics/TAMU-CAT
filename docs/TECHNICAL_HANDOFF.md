# Technical Handoff

Last reviewed: 2026-05-26

This document summarizes the current operating state of TAMU Competency Assessment Tool for the next technical lead, maintainer, or production administrator. It is based on the repository code, local documentation, and deployment/configuration files currently present in the project.

## Current App Status

### Live / production-ready workflows

- Role-aware authentication and dashboards for `student`, `advisor`, and `admin` users are implemented with Devise and Google OAuth.
- Google sign-in is restricted to TAMU email domains: `@tamu.edu` and `@email.tamu.edu`.
- Student workflows include profile completion gating, survey assignment visibility, progress saving, submission, response viewing, print/PDF-oriented views, and portfolio export.
- Advisor workflows include advisee dashboards, survey assignment review, student detail pages, feedback, and read-only admin impersonation support.
- Admin workflows include:
  - People Management for user role changes, member removal, advisor assignments, student track updates, and assignment group changes.
  - Program Configuration for tracks, majors, cohorts, semesters, and competency target levels.
  - Survey Builder for surveys, sections, questions, legends, previews, archive/activate flows, and audit/change history.
  - Grade Import Batches for mapping workbooks and direct competency CSV/XLSX/XLSM imports.
  - Competencies matrix comparing self, advisor, and course-derived ratings.
  - Survey Records with semester-oriented progress review and exports.
  - Reports with filters, charts, PDF exports, and Excel exports.
  - Maintenance mode management.
- Course-derived competency ratings are intentionally separate from advisor feedback. They are stored through grade import evidence/rating models rather than overwriting survey or feedback data.
- Grade imports support dry runs, commit, rollback, recommit, duplicate suppression, row-level errors, pending unmatched student rows, and derived competency ratings.
- Notifications and assignment automation exist through Active Job jobs such as `SurveyNotificationJob` and `ReconcileSurveyAssignmentsJob`.
- Local development is well-supported through Docker Compose and a local Ruby setup path.
- CI is configured in GitHub Actions for Brakeman, importmap audit, RuboCop, Minitest, and system tests.

### Pending / incomplete operational work

- Continue splitting `GradeImports::BatchProcessor` into smaller parser/router/validator services. File routing and failure diagnostics are already extracted; parser extraction can continue incrementally.
- Add more representative import sample files:
  - successful direct competency import
  - duplicate upload example
  - pending-row example
  - intentionally invalid mapping example
- Improve admin competencies usability with remembered filters, export of filtered matrices, or quick-jump/sticky context.
- Keep repo docs and GitHub wiki docs synchronized. The README treats the wiki as the broader knowledge base.

### Known bugs / risks

- No active release-blocking product bugs are known in the repository.
- Direct competency imports with only `Student name` are staged as pending matches and can reconcile by exact name; `Student SIS ID` or `Student ID` is still preferred for reliable matching.
- Course ratings shown in semester-filtered competency/report views use the import batch semester. Legacy batches without a semester can be repaired from the batch detail page.
- Production keeps `config.active_job.queue_adapter = :inline` app-wide in `config/environments/production.rb` -- most jobs still run synchronously in request flow, and none of the app's other `.perform_later` call sites have been verified running genuinely async in production. The Solid Queue database itself is now migrated (`db/queue_migrate/`), and `config.solid_queue.connects_to` is set globally in `config/application.rb`, so any job class can opt into real async processing individually via `self.queue_adapter = :solid_queue` (see `GradeImports::BatchImportJob`, used for grade-import uploads specifically because large files were exceeding Heroku's 30s router timeout when processed inline). `config/puma.rb` already runs the Solid Queue supervisor in-process when `SOLID_QUEUE_IN_PUMA=true` is set -- no separate worker dyno needed. **This env var must be set on each Heroku app (`heroku config:set SOLID_QUEUE_IN_PUMA=true`) or jobs using the Solid Queue adapter will sit unprocessed.**
- `config/recurring.yml` defines a Solid Queue hourly cleanup task. It only runs once `SOLID_QUEUE_IN_PUMA` is set on that app.
- **Large grade-import files can still crash the dyno on memory (Heroku R14/R15), even in the background job.** Roo parses the entire workbook into memory at once, and a wide Canvas outcomes export (thousands of rows x many outcome columns) can peak well over 1GB during parsing plus row-write -- on `mha-dev`'s Basic dyno (512MB), that's enough to get SIGKILL'd. `GradeImports::BatchProcessor#process_file!` already releases the parsed Roo workbook and forces a GC pass before the row-write phase, and `GradeImports::BatchImportJob` drops each file's base64 payload as soon as it's decoded -- both reduce peak usage but have **not** been enough to prevent crashes on the largest real files seen so far. Since `SOLID_QUEUE_IN_PUMA` runs the Solid Queue worker inside the same process as Puma, a crash here also takes down web traffic (visible to users as a generic "application error" mid-upload), and the worker also competes with live web requests for the same single-core GVL, so pages can hang while a big import is running. Two real fixes were deliberately not taken because they cost more (a bigger dyno) or more engineering risk (rewriting the xlsx parse to stream row-by-row instead of Roo's full in-memory DOM) -- revisit if this keeps recurring.
- `Procfile`'s `release` step now runs `db:prepare` (not `db:migrate`) specifically so a never-before-migrated database like `queue` gets its schema loaded on first deploy, not just pending migrations applied.
- Production SMTP is configured through environment variables. Confirm `APP_HOST`, `APP_PROTOCOL`, `MAILER_FROM`, and the `SMTP_*` settings before relying on email delivery.
- `config.active_storage.service = :local` in production. On Heroku this is not persistent across dyno restarts, so uploads should be moved to S3/GCS/Azure or another durable service before relying on long-term uploaded file retention.
- `config/deploy.yml` is still a Kamal template with placeholder values such as `your-user`, `192.168.0.1`, and `app.example.com`. Do not treat it as production-ready without replacing those values.
- Development Google OAuth credentials are not committed. Set `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` in a local `.env` file or shell environment when local Google sign-in testing is needed.
- Seeded development data is useful but not representative enough for all import behavior. Import validation is most reliable against a sanitized production-like database clone.
- Repository cleanup before handoff removed redirect-only dashboard templates, a duplicate static PDF layout, dated generated import sample outputs, local generated artifacts, and the tracked `config/master.key`. Transfer the Rails master key separately through a secure channel.

## Deployment Workflow

### Current supported paths

The repository contains three deployment-related paths:

- Heroku: most explicit production/review-app workflow through `Procfile` and `app.json`.
- Docker: production image via `Dockerfile`; local stack via `docker-compose.yml`.
- Kamal: scaffolded in `config/deploy.yml`, but still placeholder-based and not production-ready as-is.

### Pre-deploy checklist

1. Confirm the target branch is green in GitHub Actions:
   - Brakeman security scan
   - importmap JavaScript dependency audit
   - RuboCop
   - Rails tests and system tests
2. Confirm secrets are available:
   - `RAILS_MASTER_KEY`, provided out-of-band by a maintainer
   - `GOOGLE_OAUTH_CLIENT_ID`
   - `GOOGLE_OAUTH_CLIENT_SECRET`
   - production database credentials or `DATABASE_URL`
3. Confirm Google OAuth redirect URI matches the production domain.
4. Confirm `ENABLE_ROLE_SWITCH` is unset or disabled in production unless a temporary QA session explicitly requires it.
5. Confirm any expected maintenance window with program stakeholders.
6. Back up the production database before migrations that touch survey responses, grade imports, users, or competency ratings.

### Heroku deployment

The Heroku path is the clearest current deployment workflow.

1. Install and authenticate the Heroku CLI.
2. Confirm the production app has required add-ons:
   - Heroku Postgres
   - a wkhtmltopdf-compatible buildpack or binary path for PDF generation
3. Configure buildpacks in this order:
   - `https://github.com/dscout/wkhtmltopdf-buildpack`
   - `heroku/ruby`
4. Set required config vars:

   ```bash
   heroku config:set RAILS_ENV=production
   heroku config:set RAILS_MASTER_KEY=<master-key>
   heroku config:set GOOGLE_OAUTH_CLIENT_ID=<google-client-id>
   heroku config:set GOOGLE_OAUTH_CLIENT_SECRET=<google-client-secret>
   heroku config:set APP_TIME_ZONE="Central Time (US & Canada)"
   ```

5. Verify Heroku provides `DATABASE_URL`.
6. Deploy from the release branch:

   ```bash
   git push heroku main
   ```

7. Let the Heroku `release` process run:

   ```bash
   bundle exec rails db:migrate
   ```

8. Verify the app boots:

   ```bash
   heroku ps
   heroku logs --tail
   ```

9. Visit `/up` on the production domain and confirm a healthy response.
10. Sign in with a TAMU admin account and smoke-test:
    - Admin dashboard
    - People Management
    - Survey Builder index
    - Grade Import Batches index
    - Competencies index
    - Reports page
11. For review apps, `app.json` runs:

    ```bash
    bundle exec rails db:prepare db:seed
    ```

    Review apps require `RAILS_MASTER_KEY`.

### Docker deployment

The production `Dockerfile` builds a Rails image with Ruby 3.4.6, PostgreSQL client libraries, Thruster, and wkhtmltopdf support.

1. Build the image:

   ```bash
   docker build -t tamu_cat .
   ```

2. Run with required environment variables:

   ```bash
   docker run -d -p 80:80 \
     -e RAILS_MASTER_KEY=<master-key> \
     -e DATABASE_URL=<postgres-url> \
     -e GOOGLE_OAUTH_CLIENT_ID=<google-client-id> \
     -e GOOGLE_OAUTH_CLIENT_SECRET=<google-client-secret> \
     --name tamu_cat tamu_cat
   ```

3. Confirm the container boots and `/up` responds.
4. Confirm persistent storage. The image uses local Active Storage by default, so a production Docker deployment needs either:
   - a mounted persistent volume for `/rails/storage`, or
   - a move to cloud object storage.

### Kamal deployment

Kamal is present but not configured for real production.

Before using Kamal:

1. Replace `service`, `image`, `servers`, `proxy.host`, and `registry.username` in `config/deploy.yml`.
2. Add secrets to `.kamal/secrets`, especially:
   - `RAILS_MASTER_KEY`
   - `KAMAL_REGISTRY_PASSWORD`
   - database credentials if not using an external `DATABASE_URL`
3. Decide whether Solid Queue should run inside Puma with `SOLID_QUEUE_IN_PUMA=true` or as a separate job host.
4. Configure a durable database and durable Active Storage.
5. Run:

   ```bash
   bin/kamal setup
   bin/kamal deploy
   ```

Treat this path as future-ready scaffolding, not the current recommended production path.

### Rollback

For Heroku:

1. Identify the prior release:

   ```bash
   heroku releases
   ```

2. Roll back:

   ```bash
   heroku rollback v<N>
   ```

3. If migrations were destructive or incompatible, restore from a database backup rather than relying only on app rollback.
4. Re-run smoke tests after rollback.

For grade import data issues:

- Prefer the built-in batch rollback/recommit workflow when the problem is isolated to one import batch.
- Do not manually delete import evidence/rating rows in production unless you have confirmed the batch relationships and backed up the database.

## Ongoing Maintenance

### Scheduled tasks

- `config/recurring.yml` defines one production recurring task:

  ```ruby
  SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)
  ```

  Schedule: every hour at minute 12.

- Important caveat: recurring tasks only run while `SOLID_QUEUE_IN_PUMA=true` is set on that Heroku app (see "Known bugs / risks" above) -- the app-wide Active Job adapter itself stays inline.

### Routine checks

- Review GitHub Actions on every push and pull request.
- Run a manual admin smoke test after changes touching:
  - survey assignment
  - survey submission
  - advisor feedback
  - grade imports
  - competencies matrix
  - reports/export code
  - user roles
- Check logs for:
  - OAuth failures
  - CSRF resets
  - pending grade import reconciliation failures
  - PDF/wkhtmltopdf failures
  - slow grade import requests if jobs remain inline
- Verify `/up` health checks after each deploy.
- Keep `db/schema.rb`, `db/cache_schema.rb`, `db/queue_schema.rb`, and `db/cable_schema.rb` in sync after migrations.

### API key / secret rotation

Rotate on maintainer handoff, suspected exposure, or at least once per academic year:

- Google OAuth client secret in Google Cloud Console.
- `RAILS_MASTER_KEY` only with a planned credentials rotation, because all encrypted credentials depend on it.
- Heroku account access and Heroku API tokens.
- Heroku Postgres credentials if exposed.
- Container registry token if using Kamal/Docker registry deploys.
- Any future SMTP, S3/GCS/Azure, or monitoring service credentials.

After rotating Google OAuth credentials:

1. Update production config vars.
2. Update allowed redirect URIs in Google Cloud Console.
3. Test sign-in for all three roles.
4. Remove old OAuth clients/secrets.

### Known technical debt

- `GradeImports::BatchProcessor` should be decomposed.
- Legacy course-derived ratings without an import batch semester should be assigned a semester before relying on semester-filtered views.
- Production background jobs: decision made to keep the app-wide adapter `:inline` and opt individual job classes into Solid Queue (`self.queue_adapter = :solid_queue`) as they're found to need real async processing, rather than flipping every job to async at once with no incremental verification. `GradeImports::BatchImportJob` is the first job to do this. Revisit whether other `.perform_later` call sites (survey notifications, auto-assignment, etc.) should follow the same path.
- Production Active Storage needs durable object storage or explicit persistent volume management.
- Mailer host and SMTP settings should be confirmed in production before depending on email delivery.
- Keep development OAuth credentials out of committed config; use local environment variables for developer-only sign-in testing.
- Admin UI remains the densest surface and needs continued smoke coverage.
- Documentation is split between repo docs and the GitHub wiki; keep both updated when workflows change.

## Dependencies

### Runtime platform

- Ruby `3.4.6`
- Rails `~> 8.0.3`
- PostgreSQL `17` in the Docker development stack; CI uses PostgreSQL `15`
- Puma
- Linux packages for production image:
  - PostgreSQL client
  - font/rendering libraries
  - `wkhtmltopdf`
  - `libvips`

### Key Ruby libraries

- `devise`, `omniauth`, `omniauth-google-oauth2`, `omniauth-rails_csrf_protection` for authentication.
- `pg` for PostgreSQL.
- `propshaft`, `importmap-rails`, `turbo-rails`, `stimulus-rails`, `tailwindcss-rails` for frontend assets/interactivity.
- `view_component` for reusable UI components.
- `solid_cache`, `solid_queue`, `solid_cable` for database-backed cache/jobs/cable.
- `wicked_pdf` and `wkhtmltopdf-binary` for PDFs.
- `caxlsx` and `roo` for Excel import/export.
- `commonmarker` for Markdown rendering.
- `brakeman`, `rubocop`, `rubocop-rails-omakase`, `simplecov`, `capybara`, `selenium-webdriver`, `webmock`, and `factory_bot_rails` for development/test support.

### JavaScript/browser dependencies

Importmap pins include:

- Hotwire Turbo
- Stimulus
- React `18.3.1`
- Chart.js `4.4.5`
- SortableJS `1.15.6`

The app only allows modern browsers through Rails' `allow_browser versions: :modern` setting.

### Environment variables

Required or commonly used:

| Variable | Purpose |
| --- | --- |
| `RAILS_ENV` | Runtime environment, usually `production`, `development`, or `test`. |
| `RAILS_MASTER_KEY` | Unlocks encrypted Rails credentials. Required in production/review apps. |
| `DATABASE_URL` | Production database URL, especially on Heroku. |
| `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth app client ID. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth app client secret. |
| `APP_HOST` | Host used in generated mailer links. |
| `APP_PROTOCOL` | Protocol used in generated mailer links, usually `https`. |
| `APP_TIME_ZONE` | Defaults to `Central Time (US & Canada)`. |
| `MAILER_FROM` | Sender address for app and Devise emails. |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_DOMAIN` | SMTP host settings for production email delivery. |
| `SMTP_USER_NAME`, `SMTP_PASSWORD`, `SMTP_AUTHENTICATION`, `SMTP_ENABLE_STARTTLS_AUTO` | Optional SMTP authentication and TLS settings. |
| `PORT` | Puma port, default `3000`; Heroku sets this automatically. |
| `RAILS_MAX_THREADS` | Puma and Active Record pool sizing. |
| `RAILS_LOG_LEVEL` | Production log level, default `info`. |
| `ENABLE_ROLE_SWITCH` | Enables role switcher outside development/test when set to `1`; keep disabled in production. |
| `WKHTMLTOPDF_PATH` | Optional explicit wkhtmltopdf executable path. |
| `WKHTMLTOPDF_ZOOM` | Optional composite PDF rendering zoom, default `1.0`. |
| `WKHTMLTOPDF_DPI` | Optional composite PDF rendering DPI, default `192`. |
| `COMPOSITE_REPORT_CACHE_MAX_ENTRIES` | In-memory composite report cache entry limit, default `50`. |
| `COMPOSITE_REPORT_CACHE_MAX_BYTES` | In-memory composite report cache size limit, default `250 MB`. |
| `JOB_CONCURRENCY` | Solid Queue worker process count when Solid Queue is active. |
| `SOLID_QUEUE_IN_PUMA` | Enables Puma Solid Queue supervisor plugin when set. |
| `WEB_CONCURRENCY` | Optional Puma worker count. |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` | Local/non-URL PostgreSQL connection overrides. |
| `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_HOST`, `DATABASE_PORT` | Alternate local PostgreSQL connection overrides. |
| `CACHE_DATABASE`, `QUEUE_DATABASE`, `CABLE_DATABASE` | Separate database names when not using `DATABASE_URL`. |
| `SEED_DEMO_DATA` | Controls demo seed data. Defaults enabled outside production, disabled in production. |
| `QUIET_SEEDS` | Suppresses seed output. |

### External services

- Google Cloud Console OAuth client for TAMU Google sign-in.
- PostgreSQL for application data.
- Heroku, if using the current Heroku deployment path.
- GitHub Actions for CI.
- Docker registry and host infrastructure if using Docker/Kamal.
- Optional future durable object storage for Active Storage uploads.
- TAMU SMTP or another production SMTP service for email delivery.

## Admin Access

### How admin privileges work

- `User` is the authenticated account model.
- `User.role` is an enum string: `student`, `advisor`, or `admin`.
- Admin users automatically get an `Admin` profile through `User#ensure_role_profile!`.
- Admin-only controllers under `Admin::` inherit from `Admin::BaseController`, which requires `current_user.role_admin?`.
- Admin role management is available through `People Management`, but the UI blocks changing your own role.
- Admin activity for role and member changes is recorded through `AdminActivityLog` where implemented.

### Creating or transferring admin access

Preferred path:

1. Have the incoming owner sign in once with their TAMU Google account.
2. An existing admin opens `People Management > Members`.
3. Search for the incoming owner's account.
4. Change their role to `admin`.
5. Confirm they can access:
   - `/admin_dashboard`
   - `People Management`
   - `Admin > Program Configuration`
   - `Admin > Grade Import Batches`
6. Keep at least two active admin users before removing or demoting the outgoing owner.

Console fallback:

```ruby
user = User.find_by!(email: "new.owner@tamu.edu")
user.update!(role: "admin")
user.send(:ensure_role_profile!)
```

Use the console fallback only when no current admin can reach People Management.

### Removing or reducing admin access

1. Confirm another active admin can sign in successfully.
2. In `People Management > Members`, change the outgoing user's role to `advisor` or `student`, or remove the member if the account should no longer exist.
3. Do not remove your own account from the UI; the controller blocks self-removal and self-role changes.
4. Rotate shared deployment credentials if the outgoing admin had access to Heroku, GitHub, Google Cloud, production database backups, or Rails credentials.

### Non-app administrative access to transfer

The app role is only one part of operational ownership. Also transfer:

- GitHub repository admin/maintainer access.
- Heroku app and pipeline access.
- Heroku Postgres access and backup permissions.
- Google Cloud OAuth client ownership.
- Domain/DNS ownership for the production host.
- Rails master key storage ownership.
- Any Docker registry/Kamal server access if that path is adopted.
- Wiki/documentation ownership.

### Admin smoke test after transfer

After granting admin access, the incoming owner should verify:

1. Google OAuth sign-in succeeds with a TAMU email.
2. Admin dashboard loads.
3. People Management loads and role counts look sane.
4. Program Configuration loads.
5. Survey Builder index loads.
6. Grade Import Batches index loads.
7. Competencies matrix loads.
8. Reports page loads.
9. Maintenance mode page is accessible.
