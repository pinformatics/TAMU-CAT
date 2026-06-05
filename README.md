# TAMU Competency Assessment Tracking

Need deeper walkthroughs for environment variables, setup screenshots, or deployment runbooks? Jump into the [project wiki](https://github.com/rockey1006/MHA-Survey-Portal/wiki) for extended guides.

## Table of Contents

1. [Project Title & Description](#project-title--description)
2. [Requirements (Internal & External Components)](#requirements-internal--external-components)
3. [External Dependencies](#external-dependencies)
4. [Environmental Variables / Files](#environmental-variables--files)
5. [Installation & Setup](#installation--setup)
6. [Usage](#usage)
7. [Features](#features)
8. [Current Admin Areas](#current-admin-areas)
9. [Handoff](#handoff)
10. [Documentation](#documentation)
11. [Credits & Acknowledgements](#credits--acknowledgements)
12. [Third-Party Libraries](#third-party-libraries)
13. [Contact Information](#contact-information)

## Project Title & Description

**TAMU Competency Assessment Tracking** is a Ruby on Rails application that streamlines the Texas A&M Master of Health Administration (MHA) survey lifecycle. Students complete required assessments, advisors monitor cohorts, and administrators orchestrate the program—each via secure, role-aware dashboards with feedback loops and analytics.

## Requirements (Internal & External Components)

| Layer | Requirements |
| --- | --- |
| **Internal components** | Ruby `3.4.6`, Rails `8.0.3`, Bundler, all gems in [`Gemfile`](Gemfile), Node.js (optional for tooling), Minitest, RuboCop. |
| **External components** | PostgreSQL `17` for the Docker dev stack, Docker Desktop, Git, optional Heroku account for deployment & review apps. |

## External Dependencies

| Dependency | Purpose |
| --- | --- |
| Docker Desktop | Reproducible local + CI stack |
| Heroku CLI | Pipeline & review app management |
| Git / GitHub Desktop | Version control workflows |
| Google Cloud Console | OAuth credentials for TAMU SSO |
| mkcert (optional) | Local HTTPS certificates |

## Environmental Variables / Files

| Variable | Description |
| --- | --- |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` | Override local Postgres settings. |
| `DATABASE_URL` | Full connection string (CI/production). |
| `RAILS_MASTER_KEY` | Unlocks encrypted credentials files. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `OAUTH_REDIRECT_URI` | Google OAuth client settings. |
| `ENABLE_ROLE_SWITCH` | QA-only impersonation toggle. |
| `PORT` | Custom dev server port (defaults to `3000`). |

Encrypted credentials live in `config/credentials/*.yml.enc`; request the `config/master.key` value from a maintainer through a secure channel when onboarding. The key is intentionally ignored and should not be committed.

## Installation & Setup

```bash
git clone https://github.com/rockey1006/MHA-Survey-Portal.git
cd MHA-Survey-Portal/
```

### Recommended setup: Docker

```bash
docker compose run --rm web bin/rails db:prepare
docker compose up --build
```

Then open:

```text
http://localhost:3000
```

This is the recommended setup path for handoff and onboarding because it does not require Ruby `3.4.6` to be installed on the host machine.

Use Docker if:

- `bin/setup` fails with `ruby not found in PATH`
- `bin/setup` fails with `gem: command not found`
- you want the most reliable path to a working local environment

### Option A – local Ruby setup

```bash
bin/setup
```

Runs bundle install, prepares the `tamu_cat_development` database, executes migrations, and seeds demo data.

Important:

- this only works if Ruby `3.4.6` is installed locally
- if the host machine does not have Ruby or Bundler, use Docker instead

### Option B – manual

```bash
gem install bundler
bundle install
bin/rails db:create db:migrate db:seed
bin/dev
```

If you use custom Postgres credentials, set `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_HOST`, and `DATABASE_PORT` (see `config/database.yml`).

➡️ Detailed screenshots and troubleshooting tips live in the wiki’s [Getting Started](https://github.com/rockey1006/MHA-Survey-Portal/wiki/Getting-Started) article—use it if you need more context than the quick steps below.

### Deep-dive checklist

1. **Verify toolchain** – `ruby -v` ⇒ `3.4.6`; `psql --version` ⇒ `17.x`. Install via rbenv/asdf/Homebrew/Windows installers as needed.
2. **Create dev DB role** *(one-time)*

   ```sql
   CREATE ROLE dev_user WITH LOGIN PASSWORD 'dev_pass';
   ALTER ROLE dev_user CREATEDB;
   ```

3. **Install gems**

   ```bash
   bundle config set --local path 'vendor/bundle'
   bundle install
   ```

4. **Prepare database**

   ```bash
   bin/rails db:prepare
   bin/rails db:seed
   ```

5. **Launch services** – `bin/dev` (Rails + CSS build) and optional `bin/rails solid_queue:start` for background jobs.
6. **Troubleshoot** – Missing master key? request it. PG auth errors? verify the role. Legacy Webpacker warnings? clear `tmp/` and rerun `bin/setup`.

### Docker workflow

```bash
docker compose run --rm web bin/rails db:prepare
docker compose up --build
```

### Optional: sync local DB from Heroku production

Use this when you need production-like student/import data locally instead of seeded demo data. The script downloads a Heroku Postgres backup from app `mha501`, drops only the local Docker development database, and restores the backup into local Postgres.

Windows PowerShell:

```powershell
.\script\sync_prod_db.ps1
docker compose up web css
```

Linux/macOS Bash:

```bash
chmod +x script/sync_prod_db.sh
script/sync_prod_db.sh
docker compose up web css
```

The scripts prompt for `HEROKU_API_KEY` if it is not already exported. To save the key to your Windows user environment, run:

```powershell
.\script\sync_prod_db.ps1 -PersistApiKey
```

On Linux/macOS, export the key in your shell profile instead:

```bash
export HEROKU_API_KEY="paste-key-here"
```

Important:

- production DB data is not modified
- the local `tamu_cat_development` database is dropped and recreated
- use `-UseLatestBackup` / `--use-latest-backup` to skip capturing a fresh Heroku backup and download the latest existing backup
- use `-SkipConfirm` / `--skip-confirm` only for trusted local automation

- Repository mounts into the app container for live reloads.
- Run tests with `docker compose run --rm web ruby run_tests.rb`.
- Docker should be treated as the default setup path unless the maintainer already has Ruby `3.4.6` working locally.
- Postgres data persists across restarts via the named Docker volume `db-data`.
   - To guarantee a completely clean DB (no leftover/non-seeded records): `docker compose down --volumes --remove-orphans`.
   - Then re-run: `docker compose run --rm -T web bin/rails db:prepare`.
- Seeding behavior: in non-production, `db/seeds.rb` may generate demo/sample data unless disabled.
   - To seed ONLY baseline data (no demo/sample generated responses/users): `docker compose run --rm -T -e SEED_DEMO_DATA=0 web bin/rails db:prepare`.
- OneDrive tip: exclude `vendor/bundle` to prevent sync conflicts during builds.

### Common local setup failure

If you run:

```bash
bin/setup
```

and see errors like:

```text
ruby not found in PATH
gem: command not found
```

that means the host machine does not have the Ruby toolchain installed.

In that case, switch to Docker:

```bash
docker compose run --rm web bin/rails db:prepare
docker compose up --build
```

## Usage

- **Local development** – `bin/dev`, browse <http://localhost:3000>, sign in with seeded accounts (see `db/seeds.rb`).
- **Testing** – `ruby run_tests.rb`, `ruby run_tests.rb --type models`, or `docker compose run --rm web ruby run_tests.rb --coverage`.
- **Background jobs** – `bin/rails solid_queue:start` in a second terminal.
- **Deployment** – Heroku review apps + staging pipeline configured via [`app.json`](app.json); promote staging → production through the Heroku dashboard.
- **CI** – GitHub Actions defined in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) execute RuboCop plus the Minitest suite for every push/PR.

## Features

- **Role-aware dashboards** – tailored Student, Advisor, and Admin experiences with Google OAuth gating.
- **Survey lifecycle management** – build questions, assign by track, collect responses, attach evidence, archive submissions.
- **Feedback & notifications** – advisors review student work, trigger reminders, and view audit trails.
- **Analytics & reporting** – KPI cards, filters, PDF/Excel exports via `Reports::DataAggregator` and `CompositeReportGenerator`.
- **Course competency imports** – faculty-facing batch import workspace with dry run, commit, rollback, duplicate protection, pending unmatched student staging, and provenance-preserving derived course ratings.
- **Accessibility controls** – persistent text scaling, high-contrast mode, translation + TTS helpers.
- **Automation** – Solid Queue jobs drive assignment, due, overdue, and completion alerts.

## Current Admin Areas

The main admin workflows in the current application are:

- **People Management** – manage members and student assignments from one workspace.
- **Program Configuration** – manage tracks, majors, cohorts, semesters, and competency target levels.
- **Survey Builder** – create and maintain surveys, questions, and availability settings.
- **Grade Import Batches** – process mapping workbooks and direct competency exports.
- **Competencies** – compare self, advisor, and course-derived ratings side by side.
- **Survey Records** – review survey progress and exports by semester.
- **Reports** – program-level visualizations and exports.

## Handoff

If you are onboarding to this project or taking over maintenance, start here:

1. [`docs/HANDOFF.md`](docs/HANDOFF.md)
2. [`docs/TECHNICAL_HANDOFF.md`](docs/TECHNICAL_HANDOFF.md)
3. [`docs/ADMIN_WALKTHROUGH.md`](docs/ADMIN_WALKTHROUGH.md)
4. [`docs/ARCHITECTURE_MAP.md`](docs/ARCHITECTURE_MAP.md)
5. [`docs/GRADE_IMPORTS.md`](docs/GRADE_IMPORTS.md)
6. [`docs/PERMISSIONS_AUDIT.md`](docs/PERMISSIONS_AUDIT.md)
7. [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md)
8. [`docs/NEXT_STEPS.md`](docs/NEXT_STEPS.md)

Important operational notes:

- course-imported competency ratings are intentionally separate from advisor feedback
- `Grade Import Batches` supports both mapping workbooks and direct competency CSV/Excel imports
- direct competency imports use `mastery points` as the competency level
- unmatched import rows are staged for later reconciliation instead of being discarded
- repeated uploads are protected by duplicate suppression

## Documentation

The GitHub Wiki is the authoritative knowledge base:

- [Project Overview](https://github.com/rockey1006/MHA-Survey-Portal/wiki/Project-Overview)
- [Architecture](https://github.com/rockey1006/MHA-Survey-Portal/wiki/Architecture)
- [Getting Started](https://github.com/rockey1006/MHA-Survey-Portal/wiki/Getting-Started)
- [Student / Advisor / Administrator playbooks](https://github.com/rockey1006/MHA-Survey-Portal/wiki)
- [System Administration & Deployment](https://github.com/rockey1006/MHA-Survey-Portal/wiki/System-Administration)

`/about` in the app links directly to these articles. Update the wiki to keep in-app help accurate.

Repo-local handoff docs:

- [`docs/README.md`](docs/README.md)
- [`docs/HANDOFF.md`](docs/HANDOFF.md)
- [`docs/TECHNICAL_HANDOFF.md`](docs/TECHNICAL_HANDOFF.md)
- [`docs/GRADE_IMPORTS.md`](docs/GRADE_IMPORTS.md)
- [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md)
- [`docs/NEXT_STEPS.md`](docs/NEXT_STEPS.md)

## Credits & Acknowledgements

- **Program sponsor** – Texas A&M School of Public Health (MHA leadership).
- **Faculty mentors** – Carla Stebbins, Ruoqi Wei, Hye Chung Kum.
- **Engineering team** – see git history for contributors.
- **AI contributions** – GitHub Copilot Chat powered by **GPT-5.1-Codex (Preview)** assisted with refactors, documentation wording, and linting suggestions; humans reviewed all commits before merge.

## Third-Party Libraries

- Rails 8, ActiveRecord, ActionCable – core framework.
- Devise + `omniauth-google-oauth2` – authentication & TAMU SSO.
- Tailwind CSS + custom tokens – design system.
- Stimulus + Turbo – interactive components.
- Chart.js + Propshaft – analytics visualization pipeline.
- Solid Queue / Solid Cache / Solid Cable – background jobs & caching.
- WickedPDF + RubyXL – PDF/Excel exports.
- GitHub Copilot Chat (GPT-5.1-Codex Preview) – AI pair-programming resource.

## Contact Information

- **Primary contact**: Tee Li — <rainsuds@tamu.edu>
- **Faculty advisor**: Pauline Wade — <paulinewade@tamu.edu>
- **Issues & pull requests**: please open items directly in this GitHub repository.

Last updated: 2026-05-26
