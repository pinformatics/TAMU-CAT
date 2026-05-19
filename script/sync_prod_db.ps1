param(
  [string]$App = "mha501",
  [string]$HerokuDatabase = "DATABASE_URL",
  [string]$LocalDatabase = "health_development",
  [string]$DbService = "db",
  [string]$DbUser = "dev_user",
  [string]$DbPassword = "dev_pass",
  [string]$RestoreClientImage = "postgres:17",
  [string]$BackupFile = (Join-Path $env:TEMP "mha501-prod-latest.dump"),
  [switch]$SkipConfirm,
  [switch]$PersistApiKey,
  [switch]$UseLatestBackup
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
  }
}

function Require-Command {
  param([string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found on PATH."
  }
}

function Set-HerokuApiKey {
  if ($env:HEROKU_API_KEY) {
    return
  }

  $secureKey = Read-Host "Paste Heroku API key for read-only prod backup download" -AsSecureString
  $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
  )

  if ([string]::IsNullOrWhiteSpace($plainKey)) {
    throw "HEROKU_API_KEY is required."
  }

  $env:HEROKU_API_KEY = $plainKey

  if ($PersistApiKey) {
    [Environment]::SetEnvironmentVariable("HEROKU_API_KEY", $plainKey, "User")
    Write-Host "Saved HEROKU_API_KEY to the current Windows user environment."
  }
}

function Confirm-LocalDrop {
  if ($SkipConfirm) {
    return
  }

  Write-Host ""
  Write-Host "This will DROP and recreate the local Docker database '$LocalDatabase'." -ForegroundColor Yellow
  Write-Host "Production app '$App' is only read/downloaded; production DB data is not modified." -ForegroundColor Yellow
  $answer = Read-Host "Type DROP LOCAL DB to continue"

  if ($answer -ne "DROP LOCAL DB") {
    throw "Aborted. Local database was not changed."
  }
}

function Wait-ForPostgres {
  Write-Host "Waiting for local Postgres service '$DbService'..."

  for ($attempt = 1; $attempt -le 30; $attempt++) {
    docker compose exec -T $DbService pg_isready -U $DbUser -d postgres | Out-Null
    if ($LASTEXITCODE -eq 0) {
      return
    }
    Start-Sleep -Seconds 2
  }

  throw "Local Postgres did not become ready."
}

Require-Command "docker"
Require-Command "heroku"

Set-HerokuApiKey
Confirm-LocalDrop

Write-Host "Starting local Postgres in detached mode..."
Invoke-Checked docker @("compose", "up", "--detach", $DbService)
Wait-ForPostgres

if (-not $UseLatestBackup) {
  Write-Host "Capturing a fresh Heroku backup for app '$App'..."
  & heroku pg:backups:capture $HerokuDatabase --app $App
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Explicit capture for '$HerokuDatabase' failed. Retrying with Heroku's default database attachment..." -ForegroundColor Yellow
    & heroku pg:backups:capture --app $App
  }
  if ($LASTEXITCODE -ne 0) {
    throw @"
Heroku backup capture failed.

Check:
- HEROKU_API_KEY is valid: heroku auth:whoami
- app name is correct: heroku apps:info --app $App
- the app has a Postgres database: heroku pg:info --app $App
- your Heroku account has permission to create/download backups for this app

You can also retry with the latest existing backup:
  .\script\sync_prod_db.ps1 -UseLatestBackup
"@
  }
} else {
  Write-Host "Using the latest existing Heroku backup for app '$App'."
}

if (Test-Path $BackupFile) {
  Remove-Item -LiteralPath $BackupFile -Force
}

Write-Host "Downloading Heroku backup to $BackupFile..."
Invoke-Checked heroku @("pg:backups:download", "--app", $App, "--output", $BackupFile)

Write-Host "Dropping and recreating local database '$LocalDatabase'..."
Invoke-Checked docker @("compose", "exec", "-T", $DbService, "psql", "-U", $DbUser, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$LocalDatabase' AND pid <> pg_backend_pid();")
Invoke-Checked docker @("compose", "exec", "-T", $DbService, "dropdb", "-U", $DbUser, "--if-exists", $LocalDatabase)
Invoke-Checked docker @("compose", "exec", "-T", $DbService, "createdb", "-U", $DbUser, $LocalDatabase)

Write-Host "Copying backup into Docker container..."
Invoke-Checked docker @("compose", "cp", $BackupFile, "${DbService}:/tmp/prod.dump")

Write-Host "Restoring production backup into local database '$LocalDatabase'..."
& docker compose exec -T $DbService pg_restore -U $DbUser -d $LocalDatabase --no-owner --no-acl --clean --if-exists /tmp/prod.dump
if ($LASTEXITCODE -ne 0) {
  Write-Host "Container pg_restore could not read the backup. Retrying with $RestoreClientImage pg_restore..." -ForegroundColor Yellow
  $restoreArgs = @(
    "run", "--rm",
    "--network", "container:$DbService",
    "-e", "PGPASSWORD=$DbPassword",
    "-v", "${BackupFile}:/tmp/prod.dump:ro",
    $RestoreClientImage,
    "pg_restore",
    "-h", "127.0.0.1",
    "-U", $DbUser,
    "-d", $LocalDatabase,
    "--no-owner",
    "--no-acl",
    "--clean",
    "--if-exists",
    "/tmp/prod.dump"
  )
  $restoreOutput = & docker @restoreArgs 2>&1
  $restoreExitCode = $LASTEXITCODE
  $restoreOutput | ForEach-Object { Write-Host $_ }

  if ($restoreExitCode -ne 0) {
    $restoreText = ($restoreOutput | Out-String)
    $onlyTransactionTimeoutWarning =
      $restoreText -match 'unrecognized configuration parameter "transaction_timeout"' -and
      $restoreText -match 'errors ignored on restore:\s*1'

    if ($onlyTransactionTimeoutWarning) {
      Write-Host "Restore completed with only the expected PostgreSQL version compatibility warning for transaction_timeout." -ForegroundColor Yellow
    } else {
      throw "Command failed with exit code ${restoreExitCode}: docker $($restoreArgs -join ' ')"
    }
  }
}
Invoke-Checked docker @("compose", "exec", "-T", $DbService, "rm", "-f", "/tmp/prod.dump")

Write-Host ""
Write-Host "Local database '$LocalDatabase' now contains a copy of Heroku app '$App'." -ForegroundColor Green
Write-Host "Start the app with: docker compose up web css" -ForegroundColor Green
