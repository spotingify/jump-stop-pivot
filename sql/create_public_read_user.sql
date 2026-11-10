-- Creates the read-only Postgres user for the public site (ui/).
-- See docs/PUBLIC_SITE_DIRECT_DB_READ_PLAN.md, "Read-only role".
--
-- Plain SQL, so it runs in psql or in a GUI query tool (pgAdmin, DBeaver, ...).
-- Run it as a superuser or the owner of the tables, connected to the app database:
--   psql "postgres://<admin_user>@<host>:5432/<db>" -f docs/sql/create_public_read_user.sql
--
-- It runs in one transaction: if any statement fails, nothing is changed.
-- It does not set a password. Set it afterwards (see the plan doc, "Set the password"),
-- so the password never appears in this file.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jsp_public_read') THEN
    CREATE ROLE jsp_public_read LOGIN CONNECTION LIMIT 15;
  ELSE
    ALTER ROLE jsp_public_read LOGIN CONNECTION LIMIT 15;
  END IF;
END
$$;

DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO jsp_public_read', current_database());
END
$$;

GRANT USAGE ON SCHEMA public TO jsp_public_read;

GRANT SELECT ON
  public.league,
  public.team,
  public.player,
  public.game,
  public.game_stats,
  public.game_coach_stats,
  public.team_penalty,
  public.player_link_claim,
  public.player_season_stats
TO jsp_public_read;

ALTER ROLE jsp_public_read SET default_transaction_read_only = on;
ALTER ROLE jsp_public_read SET statement_timeout = '5s';
ALTER ROLE jsp_public_read SET idle_in_transaction_session_timeout = '10s';

COMMIT;
