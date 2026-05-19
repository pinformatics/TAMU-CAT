-- Creates the Rails multi-db databases used by config/database.yml.
-- This runs automatically on first container init when db-data is empty.

-- NOTE: CREATE DATABASE cannot run inside a DO block (it requires autocommit).
-- psql's \gexec executes the returned SQL as a top-level statement.

SELECT format('CREATE DATABASE %I', 'tamu_cat_development')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tamu_cat_development')
\gexec

SELECT format('CREATE DATABASE %I', 'tamu_cat_test')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tamu_cat_test')
\gexec

SELECT format('CREATE DATABASE %I', 'tamu_cat_cache')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tamu_cat_cache')
\gexec

SELECT format('CREATE DATABASE %I', 'tamu_cat_queue')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tamu_cat_queue')
\gexec

SELECT format('CREATE DATABASE %I', 'tamu_cat_cable')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tamu_cat_cable')
\gexec
