# Migration Baseline

The primary application migration history was archived after the production
data transition. The active primary migration is
`db/migrate/20260903170000_baseline_current_schema.rb`.

## Behavior

- Existing databases with the current required tables record the baseline
  without changing data.
- An empty database loads `db/schema.rb`.
- A non-empty database missing required current tables fails before changing
  anything. Restore the archived migrations or complete the missing migration
  work before retrying.
- Archived migrations remain in `db/migrate_archive` for audit and recovery.
- Solid Cache, Solid Queue, and Solid Cable retain separate migration paths.

## Safe rollout

1. Back up every database.
2. Verify the target database has the current required tables.
3. Deploy the baseline code during a maintenance window.
4. Run `bin/rails db:migrate` and verify `schema_migrations`.
5. Run application smoke tests and confirm `/up`.
6. Keep the archive in version control and retain the pre-baseline backup.

Do not use `db:reset` or run the baseline against a non-empty incomplete
database. The baseline is irreversible; recovery uses the database backup and
the archived migration history.