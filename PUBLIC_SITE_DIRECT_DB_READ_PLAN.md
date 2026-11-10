# Plan: Public site (`ui/`) reads Postgres directly instead of the Go API

> Status: **implemented, not deployed.** Written 2026-11-08, implemented 2026-11-09. All decisions (D1–D5) are made; see [Decisions](#decisions).
> What was built, what changed on the way, and what's left: [Implementation notes](#implementation-notes).
>
> Scope: **read-only, `ui/` only.** The Next.js site will only run `SELECT`s. Any future
> need to write to the database is out of scope and gets its own assessment (see
> [Future writes](#future-writes-out-of-scope)).

## Context

The public site (`ui/`, jumpstoppivot.com) is a Next.js 16 App Router app, built
`output: 'standalone'` and run as a Node container on Coolify. Every page and route
handler gets its data from the Go API (`api/`) over HTTP, through
`ui/lib/fetch-client.ts`, using `API_URL` + `API_KEY`.

When the Go API is down, the public site is down too, even though Postgres is still up
and holds all the data the site needs. The goal is to remove the Go API from the
public site's read path: the Next.js server reads Postgres directly through a `pg` pool,
and live updates arrive as notifications that trigger a read from Postgres.

### What changes and what doesn't

| Part | Change |
|---|---|
| `ui/` (Next.js public site) | **Migrated.** Reads go to Postgres; SSE becomes notification-only |
| `app/` (statistician SPA) | **Untouched.** Keeps reading and writing through the Go API |
| `api/` (Go API) | **No code changes to its behaviour.** Only a smaller pool size (see [Connection budget](#connection-budget)). The read-only role is created by hand, not by a migration |
| Redis pub/sub published by the API | Unchanged. `ui/` only treats the messages as "something changed" signals |

`ui/` stays on Next.js. A static SPA can't connect to Postgres, so the earlier idea in
`PUBLIC_SITE_SPA_MIGRATION_PLAN.md` (moving `ui/` to a Vite SPA) conflicts with this plan
and is not pursued alongside it.

---

## Phase 0: Confirm the root cause first

"The API goes down" can mean several things, and the fix differs. Before writing any
code, look at the Coolify logs and container restarts for the last outages and answer:

| If the outage is… | Does this plan help? |
|---|---|
| The Go API process crashing/OOM, a bad deploy, or a hung API container | **Yes.** The site keeps serving reads. |
| The API's pool exhausting Postgres connections (see below) | **Partly.** The site needs its own reserved connections, or it fails too. |
| Postgres itself down or overloaded | **No.** Both paths fail. Fix Postgres instead. |
| The host / Coolify / Traefik down | **No.** Everything on that host is down. |
| The API rate-limiting the UI (429s) | **Yes**, but a smaller fix exists: exempt the UI's API key. |

### Finding: connection headroom is already tight

`api/pkg/postgres/config.go` sets `MaxConns = 97`. The `postgres:18-alpine` service in
`docker-compose.yml` doesn't set `max_connections`, so it uses the default of **100**.
Postgres also reserves 3 of those for superusers. Under load, the API alone can use
every regular connection. If the UI adds its own pool, the UI and the API will fight
for connections. **This could also be a cause of the current outages**, so check it
in Phase 0. Any rollout must fix it first (see [Connection budget](#connection-budget)).

---

## What the site reads today (inventory)

All of the reads go through 7 action files in `ui/actions/`. Each one maps to a store
method in the Go API. The "Logic to port" column lists everything that is **not** a plain
`SELECT` and must be rewritten in TypeScript.

| UI function (`ui/actions/…`) | API route | Go source | Logic to port |
|---|---|---|---|
| `game.getGame` | `GET /v1/games/{id}` | `GameStore.GetGameByID` | none (joins team/league names) |
| `game.getGameStats` | `GET /v1/games/{id}/stats` | `GameStatsStore.GetGameStats` | `entries` is JSONB; no row → empty entries, not 404 |
| `game.getGamePlayers` | `GET /v1/games/{id}/players` | `game_stats_handler.go` | check handler for how it merges home/away rosters |
| `game.getGameCoachBenchStats` | `GET /v1/games/{id}/coach-bench-stats` | `GameStatsStore.GetGameCoachBenchStats` | JSONB in `game_coach_stats`, per-team (migration 4) |
| `game.getAllGames` | `GET /v1/games/active` | `GameStore.GetAllActiveLeagueGames` | `l.status != 'draft'`; count + page |
| `game.getGamesByLeague` | `GET /v1/leagues/{id}/games` | `GameService.GetGamesByLeague` | also fetches league name; 404 if league missing |
| `game.getGamesStatsEnabled` | `GET /v1/games/stats-enabled` | `GameStore.GetActiveStatsEnabledGames` | draft filter |
| `league.getLeagues` | `GET /v1/leagues/active` | `LeagueStore.GetAllActiveLeagues` | draft never public; ordering active → completed → archived; `status` validation |
| `league.getLeague` | `GET /v1/leagues/{id}` | `LeagueStore.GetLeagueByID` | none |
| `league.getLeagueTeams` | `GET /v1/leagues/{id}/teams` | `TeamStore` (`team_store.go:489`) | none |
| `league.getLeaguePlayers` / `player.getPlayersByLeague` | `GET /v1/leagues/{id}/players` | `PlayerStore.GetPlayersByLeague` | none |
| `league.getLeagueStandings` | `GET /v1/leagues/{id}/standings` | `GameService.GetStandingsByLeague` | **Yes:** W/L/PF/PA, forfeits skipped, penalty points, win %, sort (wins, diff, name), positions |
| `league.getLeagueStatLeaders` | `GET /v1/leagues/{id}/stat-leaders` | `PlayerStore.GetLeagueStatLeaders` | reads precomputed `*_per_game` columns |
| `player.getAllPlayers` | `GET /v1/players/active` | `PlayerStore.GetAllActiveLeaguePlayers` | draft filter |
| `player.searchPlayers` | `GET /v1/players/search` | `PlayerStore.SearchPlayers` | `ILIKE`; escape `%`/`_` |
| `player.getPlayer` | `GET /v1/players/{id}` | `PlayerStore.GetPlayerByID` | none |
| `player.getPlayersByTeam` | `GET /v1/teams/{id}/players` | `PlayerStore.GetPlayersByTeam` | none |
| `player.getPlayerGameHistory` | `GET /v1/players/{id}/games` | `GameStatsStore.GetPlayerGameHistory` | `jsonb_array_elements` lateral join; paging is done in the handler |
| `playerLink.getPlayerCareer` | `GET /v1/player-links/players/{id}/career` | `PlayerSeasonService.GetCareer` | **Yes:** linked-profile CTE, frozen snapshot vs live totals (`playerStatTotalsSQL`), API-side cache |
| `team.getTeams` / `getAllTeams` / `searchTeams` / `getTeam` | `GET /v1/teams…` | `TeamStore` | draft filter on `/active` |
| `metric.getGlobalMetrics` | `GET /v1/metrics` | `MetricsStore.GetPlatformMetrics` | four `COUNT(*)`s; cache it |
| `coffee.getTiers` / `createCheckout` | `/v1/coffee/*` | `internal/coffee` | **Stays on the API.** Stripe + a write; see below |

Also in the TypeScript side, unchanged: `computeScore`, `getTeamStats`, the today-first
sort in `getAllGames`, and `ui/lib/standings.ts`.

All paginated responses use the shape from `api/pkg/utils/pagination.go`
(`limit/page/skip/totalPages/totalResults/nextPage`). Port it once as a helper.

### Things the Go API does that the site depends on, but that stay in the API

These are **writes** done by background workers. They keep running in the API. When the
API is down they stop, so the site serves slightly stale derived data. It does not go down.

- `ScoreWorker`: fills `game.home_score/away_score` from `game_stats`.
- `PlayerStatsWorker`: fills `player.games_played`, `*_per_game` (used by stat leaders and player cards).
- `playerlink` worker: writes `player_season_stats` snapshots when a league is completed.

Stat entry (the `app/` statistician SPA) writes through the API. If the API is down, no new
stats are recorded, but the public site still shows everything recorded so far.

### Visibility rules to keep exactly

The public API uses `RequestAuthCheckForPublicForm`, so the UI always reads as an
anonymous user. The `LEFT JOIN *_sharing … firebase_uid = @firebaseUID` joins return a
`user_role` that is always empty for the UI, so **drop those joins**. The rules that do
matter:

- List endpoints (`/active`, `stats-enabled`) hide leagues with `status = 'draft'` and
  everything under them.
- Career hides draft leagues except the player's own row.
- **Search: drafts excluded (D4, a deliberate change from the API).** Today
  `SearchPlayers` and `SearchTeams` don't filter drafts, so draft players and teams show up
  in the site's search (`ui/app/players/page.tsx` uses `searchPlayers`). The new stores add
  `l.status IS DISTINCT FROM 'draft'`. `IS DISTINCT FROM` keeps rows with no league
  (`league_id` NULL), as the API does today; a plain `<>` would drop them. The parity script
  must expect this difference.
- **Get-by-ID: still works by direct link.** `GetGameByID`, `GetLeagueByID`, `GetTeamByID`
  and `GetPlayerByID` don't filter drafts, and the new stores keep that, so a link shared
  while a league is being set up still opens. Detail pages for draft data get
  `robots: { index: false }` in `generateMetadata`, so search engines don't index them either.
  (Quick games create their league as `active`, not `draft`, so they aren't affected.)
- The sitemap only uses list reads (`getLeagues`, `getAllGames`, …), which already exclude drafts.

---

## Target architecture

```
Browser ──► Next.js server (ui/)
              ├── ui/server/*  ──► ui/lib/db/pool.ts ──► Postgres  (pg Pool, read-only role)
              ├── live SSE     ──► Redis pub/sub (notifications only, published by the API)
              └── fetchClient  ──► Go API (coffee only)
```

### Same read pattern as the Go API: `pg` Pool + store/service

The Go API reads with a **pgx pool** (`api/pkg/postgres`) and splits each domain into a
**store** (SQL + row mapping) and a **service** (business logic). `ui/` copies that
shape with [`pg`](https://node-postgres.com/) (node-postgres) and its `Pool`, so the two
codebases read the same way and a Go store method has one obvious TypeScript twin.

**Pool settings mirror `api/pkg/postgres/config.go`:**

| pgx (`config.go`) | Go value | `pg.Pool` option | UI value |
|---|---|---|---|
| `MaxConns` | 97 | `max` | **10** (see connection budget) |
| `MinConns` | 0 | (no minimum in `pg`; idle clients are closed) | default |
| `MaxConnLifetime` | 5m | `maxLifetimeSeconds` | 300 |
| `MaxConnIdleTime` | 1m | `idleTimeoutMillis` | 60_000 |
| `ConnectTimeout` | 5s | `connectionTimeoutMillis` | 5_000 |
| `HealthCheckPeriod` + `PrepareConn` ping | 1m / ping | (none in `pg`) | rely on `maxLifetimeSeconds` + `pool.on('error')` |
| `QueryExecModeSimpleProtocol` | on | (see below) | parameterized queries only |

`pg`-specific rules:
- **`pool.on('error', …)` is required.** Without it, an idle client that loses its
  connection (Postgres restart, network blip) throws an unhandled error and crashes the
  Next.js process. Log it, don't exit.
- Use parameterized queries (`pool.query(text, values)`), never string concatenation.
  `pg` sends them as unnamed statements, which works behind PgBouncer in transaction
  mode, like the API's simple-protocol setting. Don't use named prepared statements (`name:`).
- Array parameters: pass `string[]` and cast in SQL (`= ANY($1::uuid[])`), the same as
  the API does in `playerlink_career_store.go`.
- Type parsing, so output matches the API's JSON: `COUNT(*)` and `bigint` come back as
  strings, so cast `::int` in SQL. JSONB comes back already parsed. `timestamptz` comes back
  as `Date`, so convert it to the same ISO string the API sends (or register a type parser).
- Keep one pool on `globalThis`, as `ui/lib/redis.ts` does, so dev hot reload doesn't leak
  connections. Every server module starts with `import 'server-only'`.
- The role sets `statement_timeout`; also set `statement_timeout` / `query_timeout` on the
  pool as a second guard.

### Folder layout (inside `ui/`)

`ui/` doesn't follow the Vite SPA layout from the global conventions. This mirrors the Go
`pkg/postgres` + `internal/<domain>/<domain>_store.go|_service.go` split, in `ui/`'s
TypeScript naming:

```
ui/lib/db/
├── pool.ts                   # pg Pool (mirror of api/pkg/postgres/config.go), type parsers, error handler
├── pagination.ts             # port of api/pkg/utils/pagination.go
├── errors.ts                 # NotExistsError / InvalidRequestError, uuid parsing, action error mapping
├── zero.ts                   # Go zero values in JSON (uuid.Nil, zero time)
└── memo.ts                   # in-process TTL cache with single-flight
ui/lib/live/
├── notification.ts           # Redis message → {"type": …} notification
├── game-notifier.ts          # one shared Redis subscriber per process, fan-out per game
├── coalesce.ts               # client: turn bursts of notifications into few reads
└── useLiveGame.ts            # client hook: EventSource + /live reads + safety poll
ui/lib/game-stats.ts          # computeScore / getTeamStats (moved out of actions; client-safe)
ui/server/
├── game/
│   ├── game.store.ts         # GameStore + GameStatsStore reads (game, game_stats, game_coach_stats, history, live)
│   └── game.service.ts       # standings, league games + name, existence checks, live snapshot cache
├── league/
│   ├── league.store.ts       # LeagueStore reads, team_penalty, league status
│   └── league.service.ts     # status validation, response shaping
├── player/
│   ├── player.store.ts       # PlayerStore reads, search (draft filter), stat leader rows
│   └── player.service.ts     # stat leader categories, team info, response shaping
├── team/team.store.ts        # TeamStore reads
├── playerlink/
│   ├── playerlink.store.ts   # port of PlayerSeasonStore.GetCareerRows / GetLiveTotals
│   └── playerlink.service.ts # port of PlayerSeasonService.GetCareer
└── metric/metric.store.ts    # MetricsStore.GetPlatformMetrics
```

Each store function has a comment naming the Go method it copies (for example
`// Port of api/internal/league/game_store.go GetGameByID`), so a reviewer changing one
side can find the other. Domains with no business logic have no service file; the action
calls the store directly.

### Layers and request flow

Every read goes down the same stack: **page → action → service → store → pool → Postgres**.
The page is the entry point, not the component: pages are server components, so they call the
actions and hand the data to components as props. Client components never query the database;
they only render props, and the live-game client fetches through an API route that enters the
same stack at the service layer.

```
                         BROWSER
 ┌───────────────────────────────────────────────────────────────────────┐
 │  HTML from the server            Client components ('use client')     │
 │                                  e.g. GameDetailClient + useLiveGame  │
 └───────▲──────────────────────────────┬────────────────────┬───────────┘
         │ rendered HTML                │ EventSource        │ fetch
         │ (server data as props)       │ (notifications)    │ (data)
═════════╪══════════════════════════════╪════════════════════╪════════════ Next.js server (ui/)
         │                              ▼                    ▼
 ┌───────┴──────────────────┐   app/api/games/[id]/   app/api/games/[id]/
 │ PAGE  (server component) │   stream/route.ts       live/route.ts
 │ app/**/page.tsx,         │          │                    │
 │ opengraph-image.tsx,     │          ▼                    │
 │ api/*-image/route.tsx    │   lib/live/game-notifier      │
 │  → renders components/*  │   (1 Redis subscriber         │
 └───────┬──────────────────┘    per process) ◄── Redis     │
         │ call                    pub/sub (API publishes)  │
         ▼                                                  │
 ┌──────────────────────────┐                               │
 │ ACTION  actions/*.ts     │  server-only, React cache(),  │
 │                          │  uuid parsing, errors →       │
 │                          │  "X not found" for notFound() │
 └───────┬──────────────────┘                               │
         ▼                                                  │
 ┌──────────────────────────┐                               │
 │ SERVICE server/<domain>/ │  business logic: standings,   │
 │   <domain>.service.ts    │  stat leaders, existence  ◄───┘
 │                          │  checks, memo caches
 └───────┬──────────────────┘
         ▼                      (domains with no logic: the action
 ┌──────────────────────────┐    calls the store directly)
 │ STORE  server/<domain>/  │  SQL + row → API JSON shape
 │   <domain>.store.ts      │  (one function per Go store method)
 └───────┬──────────────────┘
         ▼
 ┌──────────────────────────┐
 │ POOL   lib/db/pool.ts    │  pg Pool (max 10), type parsers,
 │                          │  timeouts, pool.on('error')
 └───────┬──────────────────┘
         ▼ read-only role jsp_public_read (DATABASE_URL_READONLY)
 ════════════════════════════
   Postgres  (shared with the Go API, which still does every write)
```

| Layer | Lives in | Does | May import |
|---|---|---|---|
| Client component | `components/*` (`'use client'`), `lib/live/useLiveGame.ts` | Renders props; live games subscribe to `/stream` and read `/live` | types, `lib/game-stats.ts`, `lib/live/coalesce.ts`. **Never** actions, services, stores or `lib/db` (all `server-only`) |
| Page / route handler | `app/**/page.tsx`, `opengraph-image.tsx`, `app/api/**/route.ts(x)` | Reads params, calls actions, `notFound()` on "not found", renders components | actions (`/live` calls the game service directly) |
| Action | `actions/*.ts` | Public read API of the site: `cache()`, input parsing, error mapping; same signatures as before the migration | services, stores, `lib/db/*` |
| Service | `server/<domain>/<domain>.service.ts` | Business logic ported from the Go services, memo caches | stores of any domain, `lib/db/*` |
| Store | `server/<domain>/<domain>.store.ts` | SQL and row mapping, nothing else | `lib/db/pool.ts`, `lib/db/zero.ts` |
| Pool | `lib/db/pool.ts` | One `pg.Pool` per process | `pg` |

Calls only go **down** the stack. A store never calls a service, and a service never calls an
action.

**The `ui/actions/*` function signatures and return types don't change.** Only their
bodies change: they call `ui/server/*` instead of `fetchClient`. Pages and components
don't change (apart from the live-game client, below). The error strings stay the same
(`"Game not found"` etc.), because pages match on them to call `notFound()`.

### One code path, no fallback (D5)

There is no `DATA_SOURCE` switch and no fallback to the API. Each action's body is
replaced outright with the store/service call, and the `fetchClient` reads are deleted in
the same change. Only the coffee actions keep using `fetchClient`.

Because there's no switch to flip back, confidence has to come before the deploy:
- The parity script (Phase 4) compares the new stores against the **running API over
  HTTP**, so it doesn't need the old code path inside `ui/`.
- Rollback is redeploying the previous `ui` image in Coolify. That works as long as the
  Go API is still running, and nothing in this plan removes it.

---

## Live games: SSE becomes notification-only

### Today

`GameDetailClient.tsx` opens **two** `EventSource`s per viewer:

- `/api/games/[id]/stream`: creates **a new Redis connection per viewer**, sends a
  snapshot (via the API) on connect, then forwards the API's Redis messages on
  `game:{id}:updates` as-is. Those messages carry the **full stats entries**
  (`publishStatsUpdate`) or `{finished}` (`publishGameFinished`).
- `/api/games/[id]/coach-stream`: **polls the Go API every 3s per viewer**. The API
  already publishes coach updates on `game:{id}:coach-updates`
  (`publishCoachStatsUpdate`), but nothing in `ui/` subscribes to it.

### Target

The SSE stream only says *what* changed. The client then reads the current state, and
that read comes from Postgres. No game data travels over SSE.

```
statistician app ─► Go API ─► Postgres (write)
                        └──► Redis PUBLISH game:{id}:updates / :coach-updates   (unchanged)
                                  │
ui Node process: ONE shared Redis subscriber ─► fan-out to SSE clients of that game
                                  │   event: {"type":"stats"} | {"type":"coach"} | {"type":"status"}
browser ◄─ SSE (one per viewer) ──┘
   └─► GET /api/games/[id]/live ─► single-flight + 1s micro-cache ─► Postgres
```

**Server: one SSE route** `/api/games/[id]/stream` (the `coach-stream` route is deleted).

- **One Redis subscriber per Node process**, shared by every viewer, instead of one per
  viewer. Keep a `Map<gameId, Set<listener>>`. Subscribe to `game:{id}:updates` and
  `game:{id}:coach-updates` when the first viewer of a game connects; unsubscribe when the
  last one leaves.
- Map the API's messages to notifications, **ignoring their payload otherwise**:
  - `game:{id}:updates` with a `finished` key → `{"type":"status"}`
  - `game:{id}:updates` otherwise → `{"type":"stats"}`
  - `game:{id}:coach-updates` → `{"type":"coach"}`

  The API doesn't change. Slimming the API's payloads later is optional; `ui/` won't depend on them.
- On connect, send `{"type":"sync"}` so the client reads once (this replaces the
  initial snapshot the route sends today).
- Send an SSE comment (`: ping`) every 25s so Traefik/proxies don't close idle streams.

**New read route:** `GET /api/games/[id]/live`. One SQL round trip returns everything
the live view needs:

```sql
SELECT g.stats_enabled,
       COALESCE(gs.entries, '[]'::jsonb)  AS entries,
       gs.updated_at                      AS stats_updated_at,
       COALESCE(gc.entries, '[]'::jsonb)  AS coach_entries,
       gc.updated_at                      AS coach_updated_at
FROM game g
LEFT JOIN game_stats gs       ON gs.game_id = g.id
LEFT JOIN game_coach_stats gc ON gc.game_id = g.id
WHERE g.id = $1
```

- **Single-flight + 1s micro-cache per game** inside the Node process. When one stat tap
  notifies 200 viewers, they cause about one query, not 200.
- `Cache-Control: no-store`.
- The existing `/api/games/[id]` JSON route isn't used by any component (only SSE URLs are);
  delete it or make it this route.

**Client (`GameDetailClient.tsx`):**

- One `EventSource` instead of two.
- Any notification → `refresh()`, which fetches `/live` and sets `entries`, `coachEntries`
  and `isLive` (from `stats_enabled`).
- `refresh()` coalesces: at most one request in flight; a notification that arrives during
  a request schedules exactly one more after it, at least ~1s apart.
- Also `refresh()` on `EventSource` `onopen` (covers events missed during a reconnect)
  and on `visibilitychange` back to visible.
- **Safety poll:** while `isLive`, refresh every 30s even with no notifications. Redis pub/sub
  is fire-and-forget, so a missed message would otherwise leave the page stale.

**Rate limiting:** `ui/middleware.ts` allows 60 requests/min per IP on `/api/*`. At a gym,
many viewers share one public IP over Wi-Fi, and notification-driven reads would hit that
limit. Today this didn't matter because the data rode on the SSE stream. Give `/live` its own
higher limit, or exempt it and rely on the micro-cache plus client coalescing.

**When the API is down:** nothing is being written, so there are no notifications to
miss. Viewers keep the last state, and a refresh still renders from Postgres.

**When Redis is down:** the SSE route fails to subscribe, so the client relies on the 30s
safety poll. Pages still render, because they don't need Redis.

---

## Database access and safety

### Read-only role (enforced by Postgres, not by convention)

The role is **created by hand** once per environment with the script below. It is not a
migration, so the API's migration user doesn't need `CREATEROLE` and nothing about the
role lives in `api/migrations/`.

#### Script: create `jsp_public_read`

The script is also saved as [`docs/sql/create_public_read_user.sql`](sql/create_public_read_user.sql).
It's plain SQL, so it runs in psql or in a GUI query tool (pgAdmin, DBeaver, ...). Run it as a
superuser or as the owner of the tables (the role the API's migrations run as), connected to
the app database. With psql, from the repo root:

```sh
psql "postgres://<admin_user>@<host>:5432/<db>" -f docs/sql/create_public_read_user.sql
```

For the local Docker database (`docker-compose.yml` exposes Postgres on port 5433):

```sh
psql "postgres://basketball@localhost:5433/basketball" -f docs/sql/create_public_read_user.sql
```

In pgAdmin: open the Query Tool on the app database, paste the script, and run it as a whole
(F5), not one statement at a time.

The script runs in one transaction, so if any statement fails nothing is changed. It creates
the role **without a password**; set one in the next step.

```sql
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
```

Notes:
- It's safe to run again: it updates the role if it exists, and grants are idempotent.
- Table names were checked against `api/migrations/` on 2026-11-08. If a later migration
  adds a table the site must read, add a `GRANT SELECT` for it and run that line by hand.
  New tables are **not** readable by default, on purpose.
- The database name differs per environment, so the `GRANT CONNECT` uses `current_database()`.

#### Set the password

The role can't log in until it has a password. The password goes into a connection URL, so it
must be URL-safe (letters and digits only), or it has to be percent-encoded in
`DATABASE_URL_READONLY`.

- **psql (preferred):** connect as admin and run

  ```
  \password jsp_public_read
  ```

  psql asks for it twice and hashes it before sending it, so the plain password never appears
  in a file, in shell history or in the Postgres logs.
- **pgAdmin:** Object Explorer → *Login/Group Roles* → `jsp_public_read` → *Properties* →
  *Definition* → *Password* → *Save*. pgAdmin sends the password in an `ALTER ROLE` statement,
  so it can show up in the Postgres logs if statement logging (`log_statement = ddl` or `all`)
  is on. Don't type `ALTER ROLE ... PASSWORD '...'` in the Query Tool either: that also ends up
  in pgAdmin's query history.

#### Check it worked

Connect as the new user (psql asks for the password):

```sh
psql "postgres://jsp_public_read@<host>:5432/<db>"
```

```sql
SELECT current_user,
       current_setting('default_transaction_read_only') AS read_only,
       current_setting('statement_timeout')             AS stmt_timeout;
SELECT count(*) FROM game;
SELECT count(*) FROM app_user;
UPDATE game SET name = name WHERE false;
```

Expected: `read_only = on`, `stmt_timeout = 5s`, the `game` count works, `app_user` fails
with `permission denied`, and the `UPDATE` fails (`cannot execute UPDATE in a read-only
transaction` or `permission denied`).

#### Connect `ui/` (D3)

Put the password only in the `ui` app's environment variables in Coolify:

```
DATABASE_URL_READONLY=postgres://jsp_public_read:<password>@<host>:5432/<db>?sslmode=<mode>
```

It's a server-only variable (no `NEXT_PUBLIC_` prefix), so it never reaches the browser.
`<host>` is the Postgres service name on the Coolify network, not a public address.

#### Rotate the password or remove the user

- **Rotate:** as admin, set a new password (see "Set the password"), update the Coolify
  variable, and redeploy `ui/`.
- **Remove** (as admin):

  ```sql
  REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM jsp_public_read;
  REVOKE USAGE ON SCHEMA public FROM jsp_public_read;
  DO $$ BEGIN EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM jsp_public_read', current_database()); END $$;
  DROP ROLE jsp_public_read;
  ```

This means a bug or a SQL injection in the UI cannot write, cannot read
`app_user`/credits/plans/sharing/integrations tables, and cannot run long queries.

### Direct table access, not views (D2)

The role reads the tables directly, so live reads always see the latest committed data.
The draft filters live in the store SQL.

Views stay an option for later, mainly to absorb schema changes. Note on performance: a plain
view is expanded into the query by Postgres, so it is never faster than the same SQL
against the tables. A **materialized** view can be faster, but it only changes when refreshed,
so it can't be used for live data. If a bottleneck shows up, look first at indexes
(see [Load](#load-the-api-had-caches-the-ui-must-add-its-own)) and caching. Consider a
materialized view only for slow, non-live reads such as metrics or career totals.

### Connection budget

| Consumer | Today | Proposed |
|---|---|---|
| Go API pool (`MaxConns`) | 97 | **60**, override with `DB_MAX_CONNS` (done) |
| UI pool (`max`) | 0 | **10**, override with `DB_POOL_MAX` (`CONNECTION LIMIT 15` on the role) |
| Superuser reserve, migrations, psql | 3 | 3+ |
| Postgres `max_connections` | 100 (default) | 100, or raise to 150 |

The UI pool can be small. Each page makes a few short queries, the live route is
single-flighted per game, and Next.js serves everything from one Node process. Lowering the
API's `MaxConns` is the one change to the API's code.

### Load: the API had caches, the UI must add its own

Today repeat reads are absorbed by the API's caches (ristretto/Redis in `pkg/caching`,
e.g. 'career' in `playerlink_career_service.go`). With direct reads, every page view hits
Postgres. Mitigations, in order of value:

1. Caching, kept to what the API already did, since the data must stay live (D2):
   - React `cache()` on every action, so one request (`generateMetadata` + page + OG image)
     runs each read once.
   - In-process TTL caches (`ui/lib/db/memo.ts`): metrics 5 min, career 1 min (the API cached
     5 min but dropped entries on link/status changes, which `ui/` can't see), live game 1 s.
   - Lists, standings and stat leaders are read fresh, as before. Add caching here only if
     Postgres load shows it's needed.
2. Check the indexes these queries need (`game.league_id`, `player.league_id`,
   `player.team_id`, `team.league_id`, `game.date_time`). The API runs the same queries,
   so they probably exist. Confirm with `EXPLAIN` on production-size data.
3. `GetPlayerGameHistory` scans every `game_stats` row's JSONB array, with no index on
   `playerId`. It's the most expensive query. Cache it, and consider a GIN index later
   (that would be an API-side migration).

### Network and secrets (Coolify)

- The `ui` container must join the network Postgres is on (`coolify_net` locally).
  Postgres must not be exposed publicly for this.
- New env var in the `ui` app's Coolify settings: `DATABASE_URL_READONLY` (see D3 above).
  Runtime only: don't tick "Build Variable", so the password isn't baked into the image. The
  build doesn't need the database.
- Local dev: `docker-compose.yml`'s `ui` service builds `DATABASE_URL_READONLY` from
  `PUBLIC_READ_DB_PASSWORD` in `.env`.
- Optional: `DB_POOL_MAX` (default 10) for the `ui` pool, `DB_MAX_CONNS` (default 60) for the API.
- `REDIS_URL` is already set for `ui/`.
- `API_URL`/`API_KEY` stay, for coffee only.

---

## Other special cases

- **OG images and share images** (`opengraph-image.tsx`, `api/*-image`): they call the
  same actions. The `api/*-image` routes were on the **edge** runtime, where `pg` can't run;
  they now use `runtime = "nodejs"`.
- **`sitemap.ts`**: same actions; read fresh like before.
- **Coffee** (`/v1/coffee/tiers`, `/v1/coffee/checkout`): **stays on the API.** Checkout
  creates a Stripe session (an external write) and tiers is config. When the API is down,
  the pricing/coffee UI should hide the button rather than error. `getTiers` already
  returns `[]` on failure; check the UI handles that gracefully.

---

## Phases

There's no runtime switch (D5), so everything is built and checked on a branch and goes to
production as one `ui` deploy.

### Phase 0: Investigate (no code) — **to do, by you**
- Find the root cause of the recent outages (see the table above).
- Confirm production Postgres `max_connections`, whether there's a pooler, and whether the
  `ui` container can reach Postgres on the Coolify network.

### Phase 1: Database prep (done first) — **code done; role and env to do**
- Lower the API's `MaxConns` (or make it configurable) and deploy the API.
- Create `jsp_public_read` by hand with the [script](#script-create-jsp_public_read) in each
  environment (local, production), and run the checks.
- Add `DATABASE_URL_READONLY` to the `ui` app in Coolify (D3). Nothing uses it yet.

### Phase 2: UI data layer — **done**
- `ui/lib/db/*` (`pg` Pool), `ui/server/<domain>/*` stores and services.
- Port the simple reads first (get-by-id, lists, metrics), then standings, history and career.
- Replace each action body with the store/service call and delete its `fetchClient` read.
  `fetch-client.ts` stays, for coffee only.
- Draft search filter and `noindex` on draft detail pages (D4).
- Keep `"use server"` only on `coffee.actions.ts`. The other action files are plain
  server modules, which is right for DB code: they must not become callable server actions.

### Phase 3: Live games, notification-only SSE — **done**
- Shared Redis subscriber + merged `/stream` route; delete `/coach-stream` and the unused
  `/api/games/[id]` route.
- `/api/games/[id]/live` with single-flight + micro-cache; rate-limit change.
- `GameDetailClient.tsx`: one `EventSource`, coalesced `refresh()`, safety poll.

### Phase 4: Verify before deploying — **partly done** (see [Implementation notes](#implementation-notes))
- **Parity check** (`ui/test/parity/parity.test.ts`, `pnpm parity`): for a sample of real IDs (games, leagues,
  teams, players, including draft, forfeited, no-stats and linked-profile cases), call the
  running Go API over HTTP and the new stores, and deep-diff the JSON. Run it against a
  production snapshot. **The diff must be empty** apart from the expected D4 change (no
  draft rows in search results).
- **Unit tests** (Vitest; `ui/` has no test runner today):
  - standings: ties, forfeits, penalties, zero games
  - pagination edge cases
  - career: frozen vs live totals
  - mapping Redis messages to notifications
  - `refresh()` coalescing
  - draft filter in search
- **Live test:** run the branch locally against the snapshot plus the real API and Redis.
  Record stats from `app/` on a test game with several browser tabs open. Check every
  tab updates, and that Postgres sees about one `/live` query per notification, not one
  per tab.
- **Resilience test:** with the API container stopped, every public page still renders
  and coffee hides itself. With Redis stopped, live pages fall back to the safety poll.

### Phase 5: Deploy — **to do**
- Deploy `ui/`. Watch Postgres connections (`pg_stat_activity` by role), the slow query log,
  page latency and error logs for a few days.
- Rollback: redeploy the previous `ui` image in Coolify (the Go API is still running).

---

## Implementation notes

Implemented 2026-11-09. Nothing is committed or deployed.

### What changed in `api/`

- `pkg/postgres/config.go`: `MaxConns` default 97 → **60**, overridable with `DB_MAX_CONNS`
  (+ `config_test.go`). No other API change; the API keeps publishing to Redis as before.

### What changed in `ui/`

- New `ui/lib/db/`, `ui/lib/live/` and `ui/server/` (layout above).
- `ui/actions/*` (except coffee) now call `ui/server/*`. Signatures, return shapes and error
  messages are unchanged. They're wrapped in React `cache()`. `getTeams` and `searchTeams`
  were deleted: nothing used them (so D4 only applies to player search).
- `computeScore`/`getTeamStats` moved to `ui/lib/game-stats.ts`, because the client component
  `GameDetailClient.tsx` imported them from the (now server-only) game actions.
- Live: `/api/games/[id]/stream` is notification-only; `/api/games/[id]/live` is new;
  `/coach-stream` and the unused `/api/games/[id]` route are deleted; `GameDetailClient.tsx`
  uses `useLiveGame`. `/live` is exempt from the per-IP limit in `middleware.ts`.
- D4: player search leaves out draft leagues; draft league/game/team/player pages get
  `robots: noindex, nofollow` (new `isDraftLeague` action).
- Types: `Team.firebaseUid`/`League.firebaseUid` optional (the API never sent them),
  `Team.photoUrl`, `League.forfeitPenaltyPoints`, `TeamStanding.winPercentage`,
  `GetPlayersResponse.team` optional, `GameLiveSnapshot` replaces `GameStreamFrame`.
- `pg` added; `vitest` added with `pnpm test`, `pnpm test:db`, `pnpm parity`.

### Found during implementation

- **Pages would have been frozen at build time.** `/`, `/leagues`, `/players`, `/standings`,
  `/teams` and `/sitemap.xml` had no `dynamic` setting; they were dynamic only because
  `fetch(..., { cache: "no-store" })` opts out of prerendering. A `pg` query doesn't, so the
  build prerendered them (and in Docker, with no database, they'd have been empty forever).
  They now set `dynamic = "force-dynamic"`.
- **Edge runtime:** the share-image routes ran on edge, where `pg` doesn't work (see above).
- **Timestamps:** the columns are `timestamp` (no time zone). `pg` would parse them as local
  time; a type parser returns them exactly as the API's JSON does (`2025-02-01T18:30:00Z`).
  `numeric` (per-game averages) and `bigint` (counts) are parsed to numbers.
- **Stat leader ties:** Go sorts with an unstable sort, so the API's order between tied players
  isn't defined. `ui/` keeps ties in name order. The parity check compares accordingly.
- **Empty lists:** the API sends `null` for some empty lists (e.g. a league with no teams);
  `ui/` sends `[]`.

### Verified

- `pnpm test`: 58 unit tests (pagination, memo, errors, type parsers, notifications, shared
  subscriber, coalescing, standings, stat leaders, search filter, career).
- `pnpm test:db`: 24 integration tests on a fresh Postgres 18 built from
  `api/migrations/1_create_tables.up.sql`, with the role created by the docs script and
  fixtures in `ui/test/db/fixtures.sql`. Covers every read, the D4 rules, and that the role
  can't write or read `app_user`/`game_sharing`. Needs `TEST_DATABASE_ADMIN_URL` (an admin
  that can create a database and a role). It creates and drops its own database and a
  randomly named role, so it never touches `jsp_public_read`.
- The docs script itself, run with `psql -f` twice (idempotent, password prompt works), and
  the "Check it worked" queries.
- `pnpm build` with no database env, then `pnpm start` against the test database: every page,
  OG image and share image returned 200 with data; unknown/invalid ids 404; draft pages
  `noindex`; SSE sent `sync`/`stats`/`coach`/`status` to two viewers over **one** Redis
  subscription, which was dropped when they left; 200 concurrent `/live` reads cost 3 queries.
- `tsc` and `eslint` clean; `go build ./...` and `go test ./pkg/postgres/` pass.

### Not verified yet (needs your environment)

- **Parity against the real API and data:** `API_URL=… API_KEY=… DATABASE_URL_READONLY=… pnpm parity`
  against a production snapshot (Phase 4). This is the check that must pass before deploying.
- Recording stats from `app/` with several tabs open (Phase 4 live test).
- Production `max_connections`, pooler, and network reachability (Phase 0).

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Schema changes in `api/` silently break UI queries | High: public pages 500 | Run `pnpm test:db` (stores against a freshly migrated DB) in CI and before API deploys that touch the schema; put `pnpm parity` on the API's deploy checklist. Views remain an option if this keeps happening (D2) |
| Business logic drifts (standings rules change in Go, not in TS) | Medium: wrong standings | Port with tests; "Port of …" comments on both sides. Or move the standings calculation into a SQL view/function both sides use |
| Connection exhaustion | High: both API and site down | Connection budget above; role `CONNECTION LIMIT`; small UI pool |
| Notification storm during a busy game | Medium: DB load, 429s | Single-flight + micro-cache on `/live`; client coalescing; `/live` rate limit |
| Missed Redis messages leave live pages stale | Low | Refresh on reconnect and on tab focus; 30s safety poll |
| Unhandled `pg` idle-client error crashes Next.js | High | `pool.on('error')` handler (required) |
| Extra Postgres load without API caches | Medium | Next.js caching; `statement_timeout` |
| UI gains DB credentials | Medium | Read-only role with SELECT on public tables only |
| Postgres is the real cause of outages | High: no benefit | Phase 0 |
| A bug reaches production with no switch to flip back (D5) | Medium | Phase 4 parity, resilience and live tests before deploy; rollback by redeploying the previous image |

## Decisions

All decided 2026-11-08/09.

- **D1.** `ui/` stays on Next.js and is the only thing migrated; `app/` is untouched.
- **D2.** The read-only role reads **tables directly**, for live data. Revisit only if a
  bottleneck shows up, keeping in mind that plain views aren't faster than the tables they read.
- **D3.** The read-only user is created by hand with the script in this doc. Its password
  lives only in the `ui` app's Coolify environment variables (`DATABASE_URL_READONLY`).
- **D4.** Draft data is **not searchable**: player/team search excludes draft leagues, and
  draft detail pages are `noindex`. Direct links to draft pages still open.
- **D5.** **No fallback** and no `DATA_SOURCE` switch: one code path, checked before deploy.

## Future writes (out of scope)

This plan grants `SELECT` only, and the role is `default_transaction_read_only`. If the site
ever needs to write (e.g. a contact form, page-view counts, coffee records), assess it
separately. Points to consider then:

- Writes that need business rules, auth, Stripe, Firebase or Redis notifications should
  stay in the Go API. Splitting them across two codebases would duplicate those rules.
- A small, isolated write could use a separate role with `INSERT` on one table only,
  never by widening `jsp_public_read`.
- Any write path must handle the API being down (queue, or fail gracefully).
