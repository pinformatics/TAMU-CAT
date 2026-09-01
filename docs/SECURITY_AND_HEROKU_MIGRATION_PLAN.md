# Security and Heroku Migration Plan

This note is for the GitHub repo move, Google OAuth secret exposure, and upcoming Heroku app migration.

## Exposed Google OAuth Secret

Treat the published Google OAuth client secret as compromised.

1. In Google Cloud Console, create a replacement OAuth client secret or create a new OAuth client for the new Heroku app URLs.
2. Update every active Heroku app's config vars:
   - `GOOGLE_OAUTH_CLIENT_ID`
   - `GOOGLE_OAUTH_CLIENT_SECRET`
   - any app-specific OAuth redirect URL setting
3. Restart/recreate the affected apps after config changes.
4. Verify Google sign-in on each app.
5. Revoke/delete the old exposed client secret after the replacement is live.
6. Remove any committed helper script or documentation that contains real secrets. Keep only placeholder examples.

Do not rely on deleting the file or rewriting Git history as the only fix. Once a secret has been public, rotation is required.

## Repository Migration

Use `pinformatics/TAMU-CAT` as the canonical repo once the current report/import fixes are merged.

1. Confirm the new repo default branch, branch protections, collaborators, and secret scanning are enabled.
2. Move open work from the old repo into GitHub Issues/Projects on the new repo.
3. Update local remotes so `origin` points to the lab-owned repo, keeping the old repo as `legacy-origin` only if historical access is still needed.
4. Remove any committed environment scripts with live credentials before pushing new work.
5. Store live credentials only in Heroku config vars, GitHub Actions secrets, or a TAMU-approved password/secrets manager.

## Heroku Data Migration

The Heroku Postgres data contains real student data. Preserve it with a backup-first, verify-before-cutover process.

1. Inventory the three current Heroku apps and identify which one is production, development, and any staging/review app.
2. Pause or schedule a write freeze before copying production data.
3. Capture a fresh Heroku Postgres backup from the source app.
4. Keep a local/off-platform copy of the backup long enough to verify the migration.
5. Provision the new Heroku app and database under the lab-owned account/team.
6. Set required config vars on the new app, including `RAILS_MASTER_KEY`, OAuth credentials, mail settings, and storage settings.
7. Restore the captured backup into the new database.
8. Deploy the same commit to the new app, then run `bin/rails db:migrate`.
9. Run smoke checks:
   - Google OAuth login
   - admin grade import review
   - missing assessments review
   - MHA Program Analytics export
   - student portfolio PDF export
   - advisor meeting recap workflow
10. Compare source and target counts for critical tables:
    - users/students/advisors
    - surveys/questions/responses
    - advisor feedback and meeting recaps
    - grade import batches/files/evidence/derived ratings
    - Active Storage blobs/attachments
11. Cut over only after checks pass. Keep the old app/database available read-only until the team signs off.

If file uploads are stored on Heroku local disk, move Active Storage to durable shared storage before relying on worker dynos or migrating apps.

## Rails Migration Cleanup

Do not condense or squash existing Rails migration files before moving the real data. Existing Heroku databases may still need the full migration history.

After all old apps are retired and the lab-owned Heroku app is the only maintained deployment, it is reasonable to create a schema baseline for future clean installs. Keep a tagged archive of the pre-baseline repo state.
