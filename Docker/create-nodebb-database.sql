-- NodeBB PostgreSQL database initialization
--
-- Run this while connected as the PostgreSQL administrator.
--
-- IMPORTANT:
-- Replace CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD before execution, OR
-- use the safer interactive method documented in README.md.

CREATE ROLE nodebb WITH LOGIN PASSWORD 'CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD';
CREATE DATABASE nodebb OWNER nodebb;

-- Optional hardening: keep the application role from creating databases
-- or other PostgreSQL roles.
ALTER ROLE nodebb NOCREATEDB NOCREATEROLE NOSUPERUSER;
