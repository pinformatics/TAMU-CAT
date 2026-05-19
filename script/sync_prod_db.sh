#!/usr/bin/env bash
set -euo pipefail

APP="mha501"
HEROKU_DATABASE="DATABASE_URL"
LOCAL_DATABASE="health_development"
DB_SERVICE="db"
DB_USER="dev_user"
DB_PASSWORD="dev_pass"
RESTORE_CLIENT_IMAGE="postgres:17"
BACKUP_FILE="${TMPDIR:-/tmp}/mha501-prod-latest.dump"
SKIP_CONFIRM=0
USE_LATEST_BACKUP=0

usage() {
  cat <<USAGE
Usage: script/sync_prod_db.sh [options]

Options:
  --app NAME              Heroku app name. Default: mha501
  --heroku-db NAME        Heroku database attachment. Default: DATABASE_URL
  --local-db NAME         Local database name. Default: health_development
  --db-service NAME       Docker Compose Postgres service. Default: db
  --db-user NAME          Local Postgres user. Default: dev_user
  --db-password VALUE     Local Postgres password. Default: dev_pass
  --restore-image IMAGE   pg_restore client image. Default: postgres:17
  --backup-file PATH      Local backup download path. Default: /tmp/mha501-prod-latest.dump
  --use-latest-backup     Download latest existing Heroku backup instead of capturing a fresh one
  --skip-confirm          Do not prompt before dropping local DB
  -h, --help              Show this help

Environment:
  HEROKU_API_KEY must be exported or the script will prompt for it.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP="$2"
      shift 2
      ;;
    --heroku-db)
      HEROKU_DATABASE="$2"
      shift 2
      ;;
    --local-db)
      LOCAL_DATABASE="$2"
      shift 2
      ;;
    --db-service)
      DB_SERVICE="$2"
      shift 2
      ;;
    --db-user)
      DB_USER="$2"
      shift 2
      ;;
    --db-password)
      DB_PASSWORD="$2"
      shift 2
      ;;
    --restore-image)
      RESTORE_CLIENT_IMAGE="$2"
      shift 2
      ;;
    --backup-file)
      BACKUP_FILE="$2"
      shift 2
      ;;
    --use-latest-backup)
      USE_LATEST_BACKUP=1
      shift
      ;;
    --skip-confirm)
      SKIP_CONFIRM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found on PATH." >&2
    exit 1
  fi
}

quote_sql_literal() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\'}"
}

require_command docker
require_command heroku

if [[ -z "${HEROKU_API_KEY:-}" ]]; then
  read -rsp "Paste Heroku API key for read-only prod backup download: " HEROKU_API_KEY
  echo
  export HEROKU_API_KEY
fi

if [[ -z "${HEROKU_API_KEY:-}" ]]; then
  echo "HEROKU_API_KEY is required." >&2
  exit 1
fi

if [[ "$SKIP_CONFIRM" -ne 1 ]]; then
  echo
  echo "This will DROP and recreate the local Docker database '$LOCAL_DATABASE'." >&2
  echo "Production app '$APP' is only read/downloaded; production DB data is not modified." >&2
  read -rp "Type DROP LOCAL DB to continue: " answer
  if [[ "$answer" != "DROP LOCAL DB" ]]; then
    echo "Aborted. Local database was not changed." >&2
    exit 1
  fi
fi

echo "Starting local Postgres in detached mode..."
docker compose up --detach "$DB_SERVICE"

echo "Waiting for local Postgres service '$DB_SERVICE'..."
for _ in $(seq 1 30); do
  if docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" -d postgres >/dev/null

if [[ "$USE_LATEST_BACKUP" -ne 1 ]]; then
  echo "Capturing a fresh Heroku backup for app '$APP'..."
  if ! heroku pg:backups:capture "$HEROKU_DATABASE" --app "$APP"; then
    echo "Explicit capture for '$HEROKU_DATABASE' failed. Retrying with Heroku's default database attachment..." >&2
    if ! heroku pg:backups:capture --app "$APP"; then
      cat >&2 <<ERROR
Heroku backup capture failed.

Check:
- HEROKU_API_KEY is valid: heroku auth:whoami
- app name is correct: heroku apps:info --app $APP
- the app has a Postgres database: heroku pg:info --app $APP
- your Heroku account has permission to create/download backups for this app

You can also retry with the latest existing backup:
  script/sync_prod_db.sh --use-latest-backup
ERROR
      exit 1
    fi
  fi
else
  echo "Using the latest existing Heroku backup for app '$APP'."
fi

rm -f "$BACKUP_FILE"

echo "Downloading Heroku backup to $BACKUP_FILE..."
heroku pg:backups:download --app "$APP" --output "$BACKUP_FILE"

echo "Dropping and recreating local database '$LOCAL_DATABASE'..."
db_literal="$(quote_sql_literal "$LOCAL_DATABASE")"
docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ${db_literal} AND pid <> pg_backend_pid();"
docker compose exec -T "$DB_SERVICE" dropdb -U "$DB_USER" --if-exists "$LOCAL_DATABASE"
docker compose exec -T "$DB_SERVICE" createdb -U "$DB_USER" "$LOCAL_DATABASE"

echo "Copying backup into Docker container..."
docker compose cp "$BACKUP_FILE" "${DB_SERVICE}:/tmp/prod.dump"

echo "Restoring production backup into local database '$LOCAL_DATABASE'..."
if ! docker compose exec -T "$DB_SERVICE" pg_restore -U "$DB_USER" -d "$LOCAL_DATABASE" --no-owner --no-acl --clean --if-exists /tmp/prod.dump; then
  echo "Container pg_restore could not read the backup. Retrying with $RESTORE_CLIENT_IMAGE pg_restore..." >&2
  set +e
  restore_output="$(docker run --rm \
    --network "container:$DB_SERVICE" \
    -e "PGPASSWORD=$DB_PASSWORD" \
    -v "${BACKUP_FILE}:/tmp/prod.dump:ro" \
    "$RESTORE_CLIENT_IMAGE" \
    pg_restore \
    -h 127.0.0.1 \
    -U "$DB_USER" \
    -d "$LOCAL_DATABASE" \
    --no-owner \
    --no-acl \
    --clean \
    --if-exists \
    /tmp/prod.dump 2>&1)"
  restore_status=$?
  set -e
  printf '%s\n' "$restore_output"

  if [[ "$restore_status" -ne 0 ]]; then
    if [[ "$restore_output" == *'unrecognized configuration parameter "transaction_timeout"'* && "$restore_output" =~ errors\ ignored\ on\ restore:[[:space:]]*1 ]]; then
      echo "Restore completed with only the expected PostgreSQL version compatibility warning for transaction_timeout." >&2
    else
      exit "$restore_status"
    fi
  fi
fi
docker compose exec -T "$DB_SERVICE" rm -f /tmp/prod.dump

echo
echo "Local database '$LOCAL_DATABASE' now contains a copy of Heroku app '$APP'."
echo "Start the app with: docker compose up web css"
