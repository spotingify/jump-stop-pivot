# Business Rules — Jump Stop Pivot

> **Status:** describes behaviour **as implemented** on 2026-10-29, not as intended.
> Where code and intent appear to disagree, the rule states what the code does and
> links to an entry in [open-issues.md](open-issues.md).
>
> Rule IDs are stable — reference them in PRs and tickets. When behaviour changes,
> update the rule in the same PR.

Paths are relative to the repo root. `api/` = Go API, `app/` = admin SPA, `ui/` = public Next.js site.

---

## 1. Identity & access

### BR-AUTH-001 — Every request has an identity
The Firebase middleware resolves exactly one identity per request, in this order:
1. `?token=<share JWT>` query param → **share-token user** (`ShareTokenUser=true`, scoped to one entity).
2. `Authorization: Bearer <Firebase ID token>` (or `?auth=` query param) → **Firebase user**; if the token carries `integration: true` it is an **integration user** with `scopes`.
3. Otherwise → the shared **public user** (`UserID = "public-user"`, `PublicUser=true`).

Source: [api/pkg/auth/firebase_helper.go:41-126](../../api/pkg/auth/firebase_helper.go#L41-L126)

### BR-AUTH-002 — "Authenticated" checks admit the public user
`auth.RequestAuthCheck` returns `true` whenever *any* user is on the context — including the public user. No handler in `api/internal` checks `PublicUser`. Endpoints therefore rely on SQL role checks (BR-ROLE-*) to reject anonymous callers. → [OI-SEC-01](open-issues.md#oi-sec-01)

Source: [api/pkg/auth/base.go:89-96](../../api/pkg/auth/base.go#L89-L96)

### BR-AUTH-003 — `X-API-KEY` is an optional gate, not an identity
If `X-API-KEY` is present it must equal `TEMP_API_KEY`, else `403`. If absent, the request passes. A valid key does **not** set a user. Used by the Next.js server actions.

Source: [api/pkg/middleware/apikey.go](../../api/pkg/middleware/apikey.go)

### BR-AUTH-004 — Middleware order
Panic recovery → IP block → User-Agent block → unknown-route rejection → CORS → rate limit (1 req/s per IP, burst 50) → request log → Firebase/share-token identity → API key.

Source: [api/pkg/api/server.go](../../api/pkg/api/server.go) `RegisterMiddleware`

---

## 2. Roles & sharing

Every league, team, player and game has a `*_sharing` table mapping `firebase_uid → role`.

### BR-ROLE-001 — Roles
| Role | Read | Update | Delete | Manage sharing | Write stats |
|---|---|---|---|---|---|
| `owner` | ✓ | ✓ | ✓ | ✓ (league only enforced) | ✓ |
| `editor` | ✓ | ✓ | — | — | ✓ |
| `viewer` | ✓ | — | — | — | — |
| `share-token` (JWT only) | ✓ (that game) | — | — | — | ✓ |

Update requires `role IN ('owner','editor')`; delete requires `role = 'owner'` — enforced in SQL.
Source: `league_store.go:96,424`, `team_store.go:81,240`, `game_store.go:116,748` in [api/internal/league/](../../api/internal/league/)

### BR-ROLE-002 — Players: update and delete are owner-only
Unlike other entities, `UpdatePlayer` and `DeletePlayer` require `owner` (editors cannot edit players).
Source: [player_service.go:109-128, 318-339](../../api/internal/league/player_service.go#L109)

### BR-ROLE-003 — Creator becomes owner
Creating a league, team, player or game inserts a sharing row with `role = 'owner'` for the creator.
Source: [league_service.go:98-102](../../api/internal/league/league_service.go#L98-L102), `CreateGameWithSharing` in `game_store.go`

### BR-ROLE-004 — Sharing propagates down from the league
- Creating a game copies the parent league's sharing rows onto the game (`CreateGameWithSharing`).
- Sharing a league with a user (`ShareLeagueWithRelated`) also grants the same role on all of the league's teams, players and games. Unsharing removes them.
- League share/unshare runs **asynchronously** (goroutine, 30 s timeout) after the request returns `200`. Failures are only logged.

Source: [league_service.go:319-376](../../api/internal/league/league_service.go#L319-L376)

### BR-ROLE-005 — League sharing is by email, owner-only
`POST /v1/leagues/{id}/sharing` takes an `email`, resolves it to a Firebase UID (must already exist), and requires the caller to be the league `owner`. Default role is `viewer`.
Listing league sharings is also owner-only.

Source: [league_service.go:319-404](../../api/internal/league/league_service.go#L319-L404)

### BR-ROLE-006 — Team / player / game sharing has no owner check
`POST|DELETE /v1/{teams|players|games}/{id}/sharing` take a raw `firebaseUid` + `role` and write directly to the sharing table. **No ownership check is performed** and the role is caller-chosen (upsert). → [OI-SEC-01](open-issues.md#oi-sec-01)

Source: [game_handler.go:552-591](../../api/internal/league/game_handler.go#L552-L591), [team_service.go:188-216](../../api/internal/league/team_service.go#L188), [player_service.go:341-370](../../api/internal/league/player_service.go#L341)

### BR-SHARE-001 — Share links (game only)
- Only a game `owner` or `editor` can generate a share link.
- The link is an HS256 JWT (`SHARE_TOKEN_SECRET`) with `entityType="game"`, `entityId`, and `role` (default `share-token`).
- Expiry = `SHARE_TOKEN_EXPIRY_HOURS` (default **4 h**, minimum 1 h).
- Tokens are stateless: there is no revocation list.
- A share-token user can only act on the game named in the token; any other game → `403`.

Source: [game_service.go:409-443](../../api/internal/league/game_service.go#L409), [api/pkg/sharetoken/sharetoken.go](../../api/pkg/sharetoken/sharetoken.go), `validateShareTokenForGame` in [game_stats_handler.go:27-32](../../api/internal/league/game_stats_handler.go#L27-L32)

---

## 3. Credits, free tier & plans

### BR-CRED-001 — Free-tier allowances
| Action | Free allowance | Counted as | Cost beyond allowance |
|---|---|---|---|
| Create league | **1** | `league_sharing` rows where user is `owner` | **1 000** credits |
| Claim player profile card | **1** | `player_profile_claim` rows for user | **100** credits |
| Create game | **30** | `game_sharing` rows where user is `owner` | **20** credits |
| Game Stats Pro | 10 | *(defined, not used)* | 25 |

`GamesIncludedWithLeague = 100` is defined but not referenced.
Source: [api/internal/credits/credits_model.go:15-35](../../api/internal/credits/credits_model.go#L15-L35), `GetUsageSummary` in [credits_store.go:204](../../api/internal/credits/credits_store.go#L204)

### BR-CRED-002 — Allowance counts are "owned rows", not "things created"
Usage is counted from the sharing tables, so deleting a league/game frees a slot, and a league shared to you as `owner` counts against your allowance. Games auto-shared as owner via league propagation also count.

### BR-CRED-003 — Deduction happens before creation, without refund
For league, game and player-claim, credits are deducted in their own transaction **before** the entity is created. If creation then fails, the credits are not refunded. → [OI-BIZ-03](open-issues.md#oi-biz-03)

Source: [league_service.go:71-81](../../api/internal/league/league_service.go#L71-L81), [game_service.go:82-92](../../api/internal/league/game_service.go#L82-L92), [player_service.go:60-79](../../api/internal/league/player_service.go#L60)

### BR-CRED-004 — Balance can never go negative
`user_credits.balance` has `CHECK (balance >= 0)`. Deduction locks the row (`SELECT … FOR UPDATE`) and returns `ErrInsufficientCredits` if `balance < amount`. Every change writes a `credit_transactions` row (negative = spend, positive = purchase).
Source: [credits_store.go:43-100](../../api/internal/credits/credits_store.go#L43)

### BR-CRED-005 — Credit packages (AUD)
| ID | Name | Price | Credits |
|---|---|---|---|
| `starter` | Starter Pack | $9.99 | 300 |
| `season` | Season Pass | $29.99 | 1 000 |
| `assoc` | Association | $79.99 | 3 000 |

The public pricing page advertises different figures. → [OI-BIZ-01](open-issues.md#oi-biz-01)
Source: [credits_model.go:62-66](../../api/internal/credits/credits_model.go#L62-L66)

### BR-CRED-006 — Purchases are credited by Stripe webhook
- Checkout creates a Stripe Checkout Session (`mode=payment`) with metadata `firebase_uid`, `token_amount`, `package_type`.
- Only `checkout.session.completed` events are processed. Signature verified with HMAC-SHA256; events older than **5 minutes** are rejected.
- Credits are added and a `purchase` transaction is recorded with the Stripe session ID.
- There is no idempotency guard on `stripe_session_id`. → [OI-BIZ-02](open-issues.md#oi-biz-02)

Source: [credits_service.go:73-224](../../api/internal/credits/credits_service.go#L73)

### BR-PLAN-001 — Plans
- One plan row per user (`user_plan.firebase_uid UNIQUE`). Default name `free`.
- `features` is a string list. The only feature consumed today is `leagues_premium`. The admin app uses it to **skip the client-side credit check** when creating a league. The API does **not** check plans: the server still applies BR-CRED-001.
- A plan is active when `active_from <= now < active_to` (or `active_to IS NULL`). A worker reconciles the `active` flag on startup and every **8 h**.

Source: [user_store.go:259-280](../../api/internal/user/user_store.go#L259), [app/app/routes/league.list.tsx:48-51](../../app/app/routes/league.list.tsx#L48-L51), [plan_activity_worker.go](../../api/internal/user/plan_activity_worker.go)
→ [OI-SEC-03](open-issues.md#oi-sec-03), [OI-BIZ-04](open-issues.md#oi-biz-04)

---

## 4. Leagues

### BR-LEAGUE-001 — Required fields and defaults
- `name` required.
- `status` defaults to `draft` on create **and** on update if omitted (DB default is `active`, but the service always sets it).
- `startDate` defaults to now (UTC) on create.
- `season` defaults to the current `YYYY-MM` on create and update if omitted.

Source: [league_service.go:63-125](../../api/internal/league/league_service.go#L63-L125)

### BR-LEAGUE-002 — Default league on first sign-in
`POST /v1/users/me` creates the `app_user` record if it's missing. If the user has no leagues, it also creates "*\<Name\> Default League*" and stores its ID in `app_data.defaultLeagueId`. This league consumes the user's 1 free league (BR-CRED-001).
Source: [user_service.go:91-140, 211-229](../../api/internal/user/user_service.go#L211)

### BR-LEAGUE-003 — Public listings show active leagues only
"Active" endpoints (`/v1/leagues/active`, `/v1/teams/active`, `/v1/players/active`, `/v1/games/active`, `/v1/games/stats-enabled`) only return data from leagues with `status = 'active'`. These feed the public site.

### BR-LEAGUE-004 — Deleting a league cascades
Deleting a league deletes its teams, players (via `league_id`), games, stats and all sharing rows (`ON DELETE CASCADE`). Deleting a team sets `player.team_id` and `game.home/away_team_id` to `NULL`.
Source: [api/migrations/1_create_tables.up.sql](../../api/migrations/1_create_tables.up.sql)

---

## 5. Quick Game

### BR-QUICK-001 — One-shot league + teams + game
`POST /v1/leagues/quick-game` creates, in **one transaction**, any of these that are not supplied by ID: a league, home and away teams with players, and a game. Sharing is propagated.

Defaults:
- League name → first letters of up to 3 words of the user's display name + `'s League` (e.g. "John Michael Doe" → "JMD's League"), else "Quick League".
- Team names → "Home Team" / "Away Team".
- Game name → "\<home\> vs \<away\>".

Source: [league_service.go:256-313](../../api/internal/league/league_service.go#L256-L313)

---

## 6. Games & scores

### BR-GAME-001 — Required fields
`name` and `leagueId` are required. Teams are optional (nullable).
Source: [game_service.go:71-95](../../api/internal/league/game_service.go#L71-L95)

### BR-GAME-002 — There is no game status
A game has no status/lifecycle field (scheduled/live/final). "Live" vs "past" is inferred from `date_time` by the UI. `stats_enabled` (default `true`) is the only state flag.

### BR-GAME-003 — Scores are derived from player stats (background)
Every **1 minute** the score worker recomputes `home_score` / `away_score` for every game where:
- `stats_enabled = true`, **and**
- `date_time <= now() + 2 days`, **and**
- a `game_stats` row exists.

Each score is the sum of `points` across stat entries, attributed by the player's **current** `team_id`. Manually entered scores on such games are overwritten.
→ [OI-BIZ-05](open-issues.md#oi-biz-05)

Source: [game_store.go:1028-1057](../../api/internal/league/game_store.go#L1028-L1057)

### BR-GAME-004 — Stats writes require `stats_enabled`
All stat/coach-bench writes return `ErrStatsDisabled` (`403`) when `stats_enabled = false`.

---

## 7. Live stat recording

### BR-STAT-001 — Data shape
- **Player stats:** one entry per player per game (no per-period breakdown on the server): points, rebounds, assists, steals, blocks, fouls, technicalFouls, flagrantFouls, turnovers, plus a snapshot of playerName/playerNumber.
- **Coach/bench stats:** per-period entries with possession arrow, home/away technical fouls, and per-period home/away fouls and time-outs.

Source: [game_stats_model.go](../../api/internal/league/game_stats_model.go)

### BR-STAT-002 — Who can write stats
- Firebase user: `owner` or `editor` on the game.
- Share-token user: role `owner`, `editor` or `share-token`, for the token's game only.
- Delete stats: `owner` only.

Source: [game_stats_service.go:96-421](../../api/internal/league/game_stats_service.go#L96)

### BR-STAT-003 — Two write modes
- **Upsert (`PUT` / `upsert_stats`):** replaces the whole snapshot. Last writer wins.
- **Merge (`PATCH` / `merge_stats`):** sends **signed increments** per field. The server row-locks (`FOR UPDATE`, `lock_timeout = 2s`), adds each increment to the stored value, and clamps at **0**. Players not in the delta are untouched; unknown players are added. This mode lets multiple statisticians record concurrently without overwriting each other.

Source: [game_stats_store.go:109-225](../../api/internal/league/game_stats_store.go#L109)

### BR-STAT-004 — Coach/bench merge replaces
Merging coach/bench stats **replaces** the entries array entirely (it is not merged per period).
Source: `MergeGameCoachBenchStats` in [game_stats_store.go](../../api/internal/league/game_stats_store.go) (~line 338)

### BR-STAT-005 — Client recording rules (admin statsheet)
- Taps are debounced **2 s** before sending a `merge_stats` delta computed as `local − last server-acknowledged`.
- Unconfirmed changes are kept in `localStorage` under `stat-pending-{gameId}` until the server acknowledges them. Records older than **24 h** are discarded.
- A stat cannot go below 0. Decrementing a team foul in a period with zero team fouls is rejected with a message ("Home has no fouls to deduct in Q2").
- Periods 1–4 are quarters; period > 4 is labelled OT.
- Remote updates are rebased onto local pending changes rather than overwriting them.

Source: [app/lib/hooks/useStatSheetSync.ts](../../app/lib/hooks/useStatSheetSync.ts), [app/lib/statTransaction.ts](../../app/lib/statTransaction.ts), [app/app/context/statsheet.context.tsx:170-240](../../app/app/context/statsheet.context.tsx#L170-L240), [app/STATSHEET_SYNC.md](../../app/STATSHEET_SYNC.md)

---

## 8. Standings & leaders

### BR-STAND-001 — Standings calculation
For each team in the league, over **all** games in the league:
- **Played** +1 per game the team appears in.
- **W/L** by comparing scores. An equal score (including 0–0) counts as played but neither a win nor a loss.
- **PF/PA/Diff** summed from scores.
- **Win %** = wins / played × 100, rounded to 1 decimal.

**Sort:** wins ↓, point differential ↓, team name ↑. Position = rank after sort.

Future/unplayed games (0–0) count as played. → [OI-BIZ-06](open-issues.md#oi-biz-06)

Source: [game_service.go:305-403](../../api/internal/league/game_service.go#L305-L403)

### BR-STAND-002 — Player averages (background)
Every **60 minutes** the player-stats worker recomputes for every player in any `game_stats`:
`games_played = count of distinct games with an entry`, and per-game averages (2 dp) for points, rebounds, assists, steals, blocks, fouls and turnovers. Games with all-zero entries still count as played.
Source: `UpdatePlayerAverages` in [player_store.go:1209](../../api/internal/league/player_store.go#L1209)

### BR-STAND-003 — Stat leaders
Per league, for each of the 7 per-game categories, the **top 5** players by average (descending). Ties have no defined order. Note that fouls and turnovers are ranked "most is first".
Source: [player_service.go:389-460](../../api/internal/league/player_service.go#L389)

---

## 9. Players

### BR-PLAYER-001 — CSV import
- Multipart upload, max **10 MB**. A header row is required; columns are matched case-insensitively. A `name` column is required.
- Rows with an empty name are skipped and reported. Optional: number, position, team.
- A team named in the CSV is looked up by name within the league, or created.
- Import runs in one transaction with up to 3 retries on serialization/deadlock errors.

Source: [league_handler_public.go:338+](../../api/internal/league/league_handler_public.go#L338), [player_store.go:1032+](../../api/internal/league/player_store.go#L1032)

### BR-PLAYER-002 — Profile claim
- Any signed-in user can claim any unclaimed player profile (`player_profile_claim.player_id UNIQUE`).
- Claiming an already-claimed profile → `ErrAlreadyClaimed`.
- Claims beyond the free allowance cost credits (BR-CRED-001). No verification ties the claimant to the real player. → [OI-BIZ-07](open-issues.md#oi-biz-07)

Source: [player_service.go:60-95](../../api/internal/league/player_service.go#L60), [player_claim_store.go](../../api/internal/league/player_claim_store.go)

---

## 10. Integrations (developer API)

### BR-INT-001 — Registration
Any signed-in user can register an integration with a name and scopes. The server generates `client_id` and a `jsp_`-prefixed 32-byte secret. The secret is stored bcrypt-hashed and shown **once**.
Source: [integrations/service.go:43-94](../../api/internal/integrations/service.go#L43)

### BR-INT-002 — Token exchange
`clientId` + `clientSecret` → Firebase custom token for UID `integration:<uuid>`, with claims `integration=true`, `ownerId` and `scopes`. The custom token is exchanged for an ID token and refresh token (1 h expiry). Inactive integrations are rejected.
Source: [integrations/service.go:96-161](../../api/internal/integrations/service.go#L96)

### BR-INT-003 — Scopes are not enforced
Scopes are stored and embedded in the token, but no endpoint checks them. An integration token acts with the same permissions as any Firebase user whose UID is `integration:<uuid>`. → [OI-SEC-04](open-issues.md#oi-sec-04)

### BR-INT-004 — User provisioning
An integration token can call `POST /v1/integrations/users/provision` with an email. The server finds **or creates** the Firebase user, ensures an `app_user` row exists, and returns tokens **for that user**. → [OI-SEC-02](open-issues.md#oi-sec-02)
Source: [integrations/service.go:163+](../../api/internal/integrations/service.go#L163)

### BR-INT-005 — Revocation
Revoking deletes the integration and disables its Firebase user (owner-only).

---

## 11. Donations (Buy Me a Coffee)

### BR-COFFEE-001 — Tiers
Default tiers (AUD): $5 "Buy me a coffee", $10 "two coffees", $15 "Buy me lunch". Checkout is through Stripe and no credits are granted.
Source: [api/internal/coffee/coffee_model.go:44-48](../../api/internal/coffee/coffee_model.go#L44-L48)

---

## 12. Platform limits

| Rule | Value | Source |
|---|---|---|
| Per-IP rate limit | 1 req/s, burst 50 | `server.go` |
| HTTP read/write timeout | 15 s | `server.go` |
| WebSocket ping / pong timeout | 30 s / 10 s | `game_stats_ws_handler.go` |
| Stripe webhook max age | 5 min | `credits_service.go` |
| Share-token expiry | 4 h default | `config.go` |
| Integration ID-token expiry | 1 h | `integrations/service.go` |
