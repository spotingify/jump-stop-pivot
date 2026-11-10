# Plan: Indexed Migrations (match mini4wd pattern)

> Status: **plan only — not implemented.** Written 2026-10-29.

## Context

Basketball's API uses a legacy single-file migration approach:
`MIGRATION_FILE_PATH` points at `migrations/1_create_tables.up.sql`, and it only
runs if a hard-coded list of tables (`tablesToCheck` in
`cmd/api/init_services.go`) is missing. Files `2_…` through `6_…` are run by hand.

mini4wd's API uses a directory runner (`RunMigrationsFromDir` in
`pkg/postgres/migrations.go`): it applies every `*.up.sql` in `MIGRATIONS_DIR`
in lexicographic order, each in its own transaction, and records it in a
`schema_migrations` table so it never runs twice.

Goal: move basketball to the same pattern. It's part of upgrading basketball's
`pkg/` to match mini4wd while keeping basketball as a separate app (see the
database decision below).

## 1. Migration files

Split the current schema into numbered files in `api/migrations/`, ordered so
every table exists before anything that references it:

| File | Contents | Taken from |
|---|---|---|
| `001_league.up.sql` | `league` and `league_sharing` | 1 |
| `002_team.up.sql` | `team` and `team_sharing` | 1 |
| `003_player.up.sql` | `player` and `player_sharing` | 1 |
| `004_game.up.sql` | `game` and `game_sharing` | 1 |
| `005_game_stats.up.sql` | `game_stats` and `game_coach_stats` | 1 |
| `006_app_user.up.sql` | `app_user` | 1 |
| `007_user_plan.up.sql` | `user_plan` | 1 |
| `008_credits.up.sql` | `user_credits` and `credit_transactions` | 1 and 3 |
| `009_player_profile_claim.up.sql` | `player_profile_claim` | 1 and 3 |
| `010_integrations.up.sql` | `integrations` | 1 |
| `011_forfeit_penalties.up.sql` | `ADD COLUMN IF NOT EXISTS` for the forfeit columns, plus `team_penalty` | 6 |

### Every statement must be safe to run twice

Use `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS` and
`ALTER TABLE … ADD COLUMN IF NOT EXISTS`.

On production the `schema_migrations` table starts empty, so the runner applies
all 11 files once against tables that already exist. Because every statement
is idempotent, that's harmless, and you don't need to insert rows into
`schema_migrations` by hand.

For the same reason, the forfeit columns live **only** in `011` and not in the
`CREATE TABLE` statements in `001` and `004`:

- `league.forfeit_penalty_points`
- `game.status`
- `game.forfeit_team_id`

That way an older database that never ran migration 6 still gets them.

### Left out on purpose

- **`2_premium_subscriber.sql`**: a one-off seed insert with the placeholder
  `REPLACE_WITH_FIREBASE_UID`. It would fail the `user_plan → app_user`
  foreign-key check.
- **`4_coach_bench_stats_per_team.sql`**: a one-time data reshape.
  ⚠️ **Running it again wipes data.** On rows already in the new shape,
  `elem->>'timeOuts'` comes back NULL, so every `homeTimeOuts` and
  `homeTechnicalFouls` value is reset to 0. Production has already run it.
- **`5_uuid_v7.sql`**: the new files already use `uuidv7()` defaults.
- **`1_create_tables.down.sql`**: mini4wd has no down migrations.

### Formatting rules (runner limitations)

The runner removes lines that start with `--`, joins the remaining lines and
splits on `;`. So:

- comments only on their own lines (no `--` comments at the end of a line)
- no `DO $$ … $$` blocks
- no semicolons inside string literals

## 2. Runner (`pkg/postgres/migrations.go`)

Port these from mini4wd as they are:

- `RunMigrationsFromDir`
- `ensureMigrationsTable`
- `appliedMigrations`
- `migrationFiles`: top-level `*.up.sql` only, sorted, subfolders skipped
- `applyMigration`: one transaction per file, recorded in `schema_migrations`

Keep the legacy functions (`RunMigrations`, `RunMigrationsFromFile`, …), as
mini4wd does.

## 3. Wiring

- `pkg/config/config.go`: add `MigrationsDir`, read from `MIGRATIONS_DIR` with
  a default of `./migrations`.
- `cmd/api/init_services.go`: `initMigrations(ctx, pg, migrationsDir)` calls
  `postgres.RunMigrationsFromDir`. Rename the current function to
  `initMigrationsLegacy`.
- `cmd/api/main.go`: pass `cfg.MigrationsDir` instead of `cfg.MigrationFilePath`.

## 4. The old files (decide)

- **(a) Recommended:** move them to `migrations/legacy/`. The runner skips
  subfolders, so they stay for reference. There's no git repo here (only
  `.git.bak`) to recover them from.
- **(b)** Delete them.

## 5. Other references

- `docker-compose.yml`, `api/docker-compose.yml`, `.env`, `api/.env`,
  `DOCKER.md` and `api/README.md`: replace `MIGRATION_FILE_PATH` with
  `MIGRATIONS_DIR`.
- `api/scripts/generate-erd.sh` defaults to `migrations/1_create_tables.up.sql`.
  It needs to read the whole folder, for example by concatenating the
  `migrations/*.up.sql` files in order.
- Docker images (`build/api/Dockerfile`, `build/dist/Dockerfile`) already copy
  all of `migrations/` to `/app/migrations` and run from `/app`, so they need
  no changes.

## 6. Checks

1. **Empty database:** all 11 files apply, and `schema_migrations` has 11 rows.
2. **Copy of production:** all 11 apply with no errors and no data changes.
   Compare row counts per table and a sample of `game_coach_stats.entries`
   before and after.
3. **Restart:** nothing is applied again (the log shows only "Skipping already
   applied migration").

---

## Related decision: where basketball's data lives

Basketball stays a separate app for now, because it uses a different Firebase
project from mini4wd (`jump-stop-pivot` vs `velointerest`), so the
`firebase_uid` values don't match.

**Recommendation:** use mini4wd's Postgres instance, but give basketball its
**own database** (`CREATE DATABASE basketball`), not shared tables.

- **No code changes.** Only `DATABASE_URL` changes. Move the data with
  `pg_dump -Fc` and `pg_restore`.
- **No clashes.** Both apps have `app_user`, `user_plan`, `user_credits` and
  `credit_transactions`. In a shared database, `CREATE TABLE IF NOT EXISTS
  app_user` would quietly reuse mini4wd's table and mix users from the two
  Firebase projects.
- **Separate `schema_migrations` tables**, so `001_*.up.sql` names in the two
  apps can't collide.
- **Separate backups and restores**, and one login role per database.
- **What stays shared:** one instance means shared CPU, memory and disk and
  shared maintenance. Size `MaxConns` for both apps against `max_connections`.
  Both run `postgres:18-alpine`.
- Merging the apps later is a data migration either way (the UIDs need mapping),
  so sharing tables now doesn't make that easier.

### Suggested order

1. Upgrade basketball's `pkg/` to match mini4wd (code only, basketball keeps
   its own database).
2. **This plan:** switch to numbered migrations.
3. Move the data into the separate `basketball` database on mini4wd's instance.
