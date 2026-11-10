# Player Profile Linking Plan

Link a user's player profiles across leagues so the public player profile
shows their stats for every season they played. Players request a link
themselves. It needs approval from a league admin (owner or editor), unless
the player has a verification code from the league. League admins can roll
back any link at any time, which guards against unauthorised linking.

**Status (2026-10-29): implemented** as a separate `playerlink` module, with
no changes to the existing league, player, game, team or credits services.
Sections 1–15 describe the design as built. Section 16 is the manual
functional test plan.

## Contents

1. [Current state](#1-current-state)
2. [Core design](#2-core-design)
3. [Decisions](#3-decisions)
4. [Claim lifecycle](#4-claim-lifecycle)
5. [Database changes](#5-database-changes)
6. [Credits flow](#6-credits-flow)
7. [Request justification and anti-spam](#7-request-justification-and-anti-spam)
8. [Verification codes](#8-verification-codes)
9. [Career seasons and frozen snapshots](#9-career-seasons-and-frozen-snapshots)
10. [Emails](#10-emails)
11. [Backend (API)](#11-backend-api)
12. [App front end (`app/`)](#12-app-front-end-app)
13. [Public site (`ui/`)](#13-public-site-ui)
14. [Automated tests](#14-automated-tests)
15. [Order of work](#15-order-of-work)
16. [Functional test plan (manual)](#16-functional-test-plan-manual)

---

## 1. Current state

What existed before, and still exists unchanged:

- A `player` row belongs to a single league. A person who plays in three
  leagues has three unrelated `player` rows.
- The **original claim endpoints** (`GET|POST|DELETE /v1/players/{id}/claim`
  in `internal/league`) link one `player` row to one `firebase_uid` in
  `player_profile_claim`. Claiming takes effect immediately with no approval,
  and credits are deducted at claim time beyond the free tier. These
  endpoints, their table and their credits behaviour are **left untouched**.
- `Player.Seasons` exists in the league model but no backend code fills it.
- League sharing (`league_sharing`, `team_sharing`, `player_sharing`,
  `game_sharing`) decides who can edit what. Linking never reads or writes
  edit permissions beyond checking that a user is a league owner or editor.

## 2. Core design

Player linking is its **own domain**, `api/internal/playerlink`, with its own
tables and routes under `/v1/player-links`. It only *reads* league data
(players, leagues, teams, sharing roles, game stats) and never changes it.

The **user account** is what ties profiles together. A user's career is every
`player` row they hold an approved link on. "Linking profiles between
leagues" means the same user getting approved links on player rows in
several leagues.

A link is not applied immediately. It moves through a status lifecycle
(section 4), and every change is written to an audit log.

**Coexistence with the original claim endpoints:**

- Claims that existed in `player_profile_claim` when the migration ran are
  copied once into `player_link_claim` as approved `legacy` links, so those
  players' careers work straight away.
- `playerlink` refuses to request, approve, redeem or confirm a link on a
  player that **another** user holds through the original endpoint
  (`409 already linked`).
- Both tables share the one free profile link (section 6).
- The original endpoint still links instantly with no approval, and claims
  made through it after the migration are not copied. The app no longer
  calls it. Retiring it is a separate decision.

## 3. Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Who manages links | League **owner and editor** have the same powers: approve, reject, revoke (roll back) and generate verification codes. One shared check: `canManageLeague(leagueID, uid)` in `playerlink`. |
| 2 | Credits | **Approval never touches credits.** Credits are charged only when the player confirms a link that is beyond the free tier. There is no refund logic; revoking a link does not refund it. |
| 3 | Re-requesting | Players can request again as often as they like, with only one pending request per player profile at a time. Each request without a code needs a written justification. |
| 4 | Public seasons | Linked seasons always appear on the public profile. Completed and archived seasons are frozen into a snapshot table, which can become static data later. |
| 5 | Separation | Existing services stay untouched. The feature is a separate module with separate tables and routes (`/v1/player-links`), and does its own credit charging. |

## 4. Claim lifecycle

```
                       ┌─ free tier left ─────────────────────────────► approved (linked)
pending ── approve ────┤
                       └─ beyond free tier ─► awaiting_confirmation ── player confirms + pays ─► approved (linked)
                                                   │
                                                   ├─ player declines ─► cancelled
                                                   ├─ 30 days, no action ─► expired
                                                   └─ admin revokes ─► revoked

pending ── reject ─► rejected            (player may request again)
pending ── player cancels ─► cancelled
approved ── admin revokes ─► revoked     (rollback; no refund)
approved ── player unlinks ─► cancelled
code redeemed ─► same split as "approve" (the code is the admin's approval)
```

Statuses: `pending | awaiting_confirmation | approved | rejected | revoked | cancelled | expired`

Methods: `admin | code | legacy`

Rules:

- Only **one approval per player profile at a time**: a partial unique index
  covers `awaiting_confirmation` and `approved`.
- While one claim is `awaiting_confirmation`, other `pending` requests for the
  same player stay pending. Once that claim is confirmed (`approved`), the
  others are auto-rejected. If it is declined or expires, an admin can approve
  another request.
- A free-tier approval links immediately. Other approvals always need the
  player to confirm, even when their balance is enough, so credits are never
  spent without the player agreeing at that moment.

## 5. Database changes

Migration: `api/migrations/7_player_profile_links.sql`, mirrored into
`1_create_tables.up.sql` (drops in `1_create_tables.down.sql`). It **only adds
tables**; no existing table is altered. The migration runner joins lines, so
the SQL must not use trailing `--` comments. All five tables are in the
runner's `tablesToCheck`, so a database missing them gets them on API
start-up.

### `player_link_claim` (new)

| Column | Type | Notes |
|---|---|---|
| `id`, `player_id`, `firebase_uid` | | `player_id` FK cascade |
| `status` | TEXT NOT NULL | default `'pending'`; CHECK in the status list |
| `method` | TEXT NOT NULL | default `'admin'`; `admin`, `code` or `legacy` |
| `request_note` | TEXT | CHECK `length <= 1000` |
| `decision_note` | TEXT | reviewer's reason for approving, rejecting or revoking |
| `requested_at` | TIMESTAMPTZ | |
| `decided_by` | TEXT | firebase uid of the admin (or `system`) |
| `decided_at` | TIMESTAMPTZ | |
| `approval_expires_at` | TIMESTAMPTZ | set when the claim moves to `awaiting_confirmation` (+30 days) |
| `reminder_sent_at` | TIMESTAMPTZ | |
| `confirmed_at` | TIMESTAMPTZ | |
| `claimed_at` | TIMESTAMPTZ | when the link took effect |
| `credit_transaction_id` | UUID | the credit charge that paid for this link |

- Partial unique index: `(player_id) WHERE status IN ('awaiting_confirmation','approved')`.
- Partial unique index: `(player_id, firebase_uid) WHERE status = 'pending'`.
- Copy of existing claims: `INSERT … SELECT … FROM player_profile_claim ON
  CONFLICT DO NOTHING`, as `status='approved', method='legacy'`, keeping
  their ids, so re-running the migration doesn't duplicate them.

### `player_link_code` (new)

`id, player_id (FK cascade), code_hash, created_by, created_at, expires_at (7 days), used_at, used_by, revoked_at`

There is at most one active code per player: generating a new code revokes
the previous one.

### `player_link_event` (new, audit log)

`id, claim_id (FK to player_link_claim, cascade), action, actor_uid, note, metadata JSONB, created_at`

Actions: `requested, approved, rejected, auto_rejected, code_redeemed, awaiting_confirmation, confirmed, declined, expired, revoked, cancelled`.

### `player_link_attempt` (new)

`id, firebase_uid, player_id, success, created_at`

Used to lock out brute-force code guessing.

### `player_season_stats` (new, frozen seasons)

`player_id (FK cascade), league_id (FK cascade), team_id, season, team_name, league_name, games_played, totals for points/rebounds/assists/steals/blocks/fouls/turnovers, snapshotted_at`

Unique on `(player_id, league_id)`.

## 6. Credits flow

`playerlink` charges credits itself (`ChargeCredits` in
`playerlink_store.go`), inside its own transactions. It uses the same SQL as
the credits module (`user_credits` balance row locked `FOR UPDATE`, a debit
row in `credit_transactions` with reason `player_profile_slot`), and the
shared constants `credits.FreeTierPlayerProfileCard` (1) and
`credits.CostPlayerProfileCard` (100). The credits package itself is not
changed.

- **Free tier:** a user's linked profiles are counted across both tables:
  approved `player_link_claim` rows plus original `player_profile_claim`
  rows, as distinct players. The profile being linked is left out of the
  count, so linking one the user already holds is never charged.
- **Request:** no charge and no balance check. The claim modal tells the
  player what a link costs beyond the free tier.
- **Approve or redeem a code**, in one transaction:
  1. Lock the claim row and check that it is `pending`.
  2. Refuse if another user holds the player through the original endpoint.
  3. Lock the user's credits row (so concurrent approvals count correctly)
     and count their linked profiles against the free tier.
  4. If the free tier is still available: set status to `approved`,
     auto-reject the other pending claims for this player, and write an audit
     event.
  5. Otherwise: set status to `awaiting_confirmation` with
     `approval_expires_at = now + 30d`, and write an audit event.
  6. Commit, then send the email.
- **Confirm** (`POST /v1/player-links/claims/{claimId}/confirm`, claimant
  only), in one transaction: lock the claim, check it is
  `awaiting_confirmation` and not expired, charge `CostPlayerProfileCard`
  unless a free slot opened up, set `approved` with `confirmed_at` and
  `credit_transaction_id`, auto-reject other pending claims. If credits are
  insufficient, it returns **402** and nothing changes.
- **Decline** (`POST /v1/player-links/claims/{claimId}/decline`, claimant
  only): sets the claim to `cancelled`.
- **Expiry sweep:** the hourly `PlayerLinkWorker` sets overdue
  `awaiting_confirmation` claims to `expired`, and sends a reminder email 3
  days before expiry.
- **Credits page:** its "player profile cards" usage comes from the untouched
  credits module, which only counts original `player_profile_claim` rows. So
  links made through `playerlink` don't show there; the player link panel
  shows the free links left instead.

## 7. Request justification and anti-spam

- `POST /v1/player-links/players/{id}` takes the body `{ code?: string, note?: string }`.
  - With a `code`, the note is optional.
  - Without a code, the note is required: trimmed, 10 to 1000 characters,
    stored as plain text and escaped when rendered in the UI and in emails.
- A user can make at most **10 new requests per 24 hours** across all players.
- A user can have only one pending request per player profile (DB index).
- After a rejection the player sees the `decision_note` and can submit a new
  request with a new justification. Earlier requests stay in the history, so
  reviewers can see repeat attempts.

## 8. Verification codes

- Generated by a league owner or editor for a specific player row:
  `POST /v1/player-links/players/{id}/code`, from the player's page or the
  league's **All players** tab.
- The code is 8 characters (`XXXX-XXXX`) with no ambiguous characters. The
  plaintext is returned once; only the SHA-256 hash is stored.
- It expires after 7 days, can be used once, and is bound to that player.
  Admins can revoke it with `DELETE /v1/player-links/players/{id}/code`.
- Redemption compares the hash in constant time and locks the code with
  `SELECT … FOR UPDATE`. A user is locked out after **5 failed attempts** for
  that player in an hour. The code is only consumed if the whole redemption
  succeeds.
- A redeemed code counts as admin approval and follows the same
  free-tier/confirmation split as approval (section 6).
- Owners and editors are emailed whenever a code is redeemed, so they can roll
  back.

## 9. Career seasons and frozen snapshots

`GET /v1/player-links/players/{id}/career` (public):

1. Collect the player row plus every other row approved-linked to the same
   user. An unlinked player gets just their own row. Draft leagues are left
   out, except for the player's own row.
2. Rows whose league has a snapshot are read from `player_season_stats`.
3. Other rows are aggregated live from `game_stats`.
4. Newest league first.

**When snapshots are written:** by the hourly `PlayerLinkWorker` (also run on
API start-up), since the league service is not changed:

- Completed/archived leagues with no snapshot, or whose game stats changed
  after the snapshot, are (re-)snapshotted.
- Leagues with a snapshot that are no longer completed/archived (reopened)
  have it cleared.

So a status change takes effect within the hour. The numbers shown don't
change meanwhile, because an unfrozen season is calculated live from the same
stats.

**Response shape:** `CareerSeason` has GP, PPG, RPG, APG, SPG, BPG, FPG and
TPG (no FG%/3P%/FT%, because shot attempts are not tracked).

**Caching:** careers are cached per player for 5 minutes in an in-process
Ristretto cache (`pkg/caching`), cleared on link changes and snapshot
rewrites. The player endpoint (`GET /v1/players/{id}`) is unchanged; the app
and the public site call the career endpoint separately.

**Later (out of scope):** frozen seasons are immutable, so they can be
exported as JSON per player to R2 (`pkg/r2`) when a snapshot is written, and
served as static data.

**Privacy:** the public link summary returns only
`{ claimed, linkedProfileCount }`, never the claimant's uid.

## 10. Emails

Sent through `pkg/resend` with `pkg/resend/templates/player_link.html`.
Emails are sent after the transaction commits and never block it: a failed
send is logged and the request still succeeds.

| Event | Recipient | Content |
|---|---|---|
| New pending request | League owner and editors | Player, league, justification; button opens the **Pending** tab |
| Approved, free tier | Player | "Your profile is linked", link to the career profile |
| Approved, confirmation needed | Player | League, profile, cost, expiry date; the button goes to the **login page**, after which the dashboard shows the confirmation card |
| Reminder 3 days before expiry | Player | Same as above |
| Confirmed and linked | Player | Receipt with the credits charged |
| Rejected | Player | Reviewer's note, a button to request again |
| Revoked | Player | Reason |
| Code redeemed | League owner and editors | "X linked to player Y using a code", with a link to review or revoke |

No email is sent when an approval expires; the reminder 3 days before covers
it. Emails need `RESEND_API_KEY` and `RESEND_FROM_EMAIL`. Links in emails use
`APP_BASE_URL` (default `http://app.localhost`) and `PUBLIC_SITE_URL` (default
`http://localhost`). Without a Resend key, emails are skipped and logged as
`Player link notification (email disabled)`.

## 11. Backend (API)

New package `api/internal/playerlink/`:

- `playerlink_model.go`: statuses, methods, DTOs, errors
- `playerlink_store.go`: links, codes, audit log, overview queries, credit
  charging
- `playerlink_service.go`: rules and permissions
- `playerlink_handler.go`: routes and swag annotations
- `playerlink_notifier.go`: emails
- `playerlink_worker.go`: expiry, reminders and snapshot refresh (hourly)
- `playerlink_career_store.go`, `playerlink_career_service.go`: careers and
  snapshots
- Tests: `playerlink_service_test.go` (unit tests with fakes) and
  `playerlink_store_test.go` (integration tests against Postgres, skipped
  unless `LINK_TEST_DATABASE_URL` is set)

Wiring only, in `cmd/api`: `initPlayerLink` (store → service → handler),
`startPlayerLinkWorker`, the handler added to `collectRoutes`, and the new
tables in `tablesToCheck`. Two config values were added (`APP_BASE_URL`,
`PUBLIC_SITE_URL`) plus the template embed. Nothing in `internal/league` or
`internal/credits` changed.

Write endpoints accept only a real signed-in account. The anonymous public
user, share links and integrations get 401. Reject and revoke require a
reason.

### Routes

All under `/v1/player-links`:

| Method | Path | Who |
|---|---|---|
| GET | `/players/{id}` | Public: `{ claimed, linkedProfileCount }`; signed in: plus own claim, `canManage`, free links left |
| POST | `/players/{id}` | Player: request with `{ code?, note? }` |
| DELETE | `/players/{id}` | Player: cancel a pending request, decline, or unlink |
| GET | `/players/{id}/career` | Public |
| GET | `/me` | Player: their requests and links |
| GET | `/me/leagues` | Owner or editor: link counts per managed league |
| POST | `/claims/{claimId}/confirm` | Claimant |
| POST | `/claims/{claimId}/decline` | Claimant |
| GET | `/leagues/{id}/players` | Owner or editor: every player with link state |
| GET | `/leagues/{id}/claims?status=` | Owner or editor |
| GET | `/leagues/{id}/history` | Owner or editor |
| POST | `/claims/{claimId}/approve` | Owner or editor, with `{ note? }` |
| POST | `/claims/{claimId}/reject` | Owner or editor, with `{ note }` |
| POST | `/claims/{claimId}/revoke` | Owner or editor, with `{ note }` |
| GET | `/players/{id}/history` | Owner or editor |
| GET | `/players/{id}/code` | Owner or editor: whether a code is active (never the code) |
| POST/DELETE | `/players/{id}/code` | Owner or editor |

The original `GET|POST|DELETE /v1/players/{id}/claim` routes are unchanged.

The handlers have swag annotations, but the docs were **not** regenerated:
`swag` v1.16.4 cannot parse the Go 1.27 standard library. This was already
broken before this change; the docs date from 30 June. Upgrade `swag`, then
run `scripts/generate-swagger.sh`.

## 12. App front end (`app/`)

- `types/playerLink.types.ts`, `actions/playerLink.actions.ts` (all calls go
  to `/v1/player-links`)
- **`ClaimPlayerModal`:** two tabs, "I have a code" and "Request approval".
  The second has a required justification textarea with a character counter
  and shows the cost beyond the free tier.
- **Player detail:** `PlayerLinkPanel` with a status chip (none / pending /
  awaiting your confirmation / linked / rejected with reason) plus cancel,
  unlink and request-again actions. The career table (`PlayerProfile.tsx`) is
  filled from the career endpoint. Owners and editors also get the
  **Verification code** panel and a link to the league's link page.
- **`leagues/:leagueId/claims`** (owner or editor), tab chosen by `?tab=`:
  - **All players** (default): every player with a state chip (Not linked,
    Pending request, Awaiting confirmation, Linked), team and linked account,
    search and state filter. Actions: **Review** (pending), **Generate code /
    New code** and **Revoke code** (shows the new code once with Copy),
    **Revoke link** (linked or awaiting, with a reason).
  - **Pending:** the justification, the claimant's other linked profiles,
    approve/reject with a note.
  - **Awaiting confirmation:** each claim's expiry, with revoke.
  - **Linked:** revoke with a reason.
  - **History:** the audit log.
- **League teams page:** a **Player Link Requests** button for owners and
  editors.
- **Dashboard:**
  - **"Player links in my leagues"** (owners and editors): one row per
    managed league with pending, awaiting, linked and not-linked counts,
    leagues with pending requests first. A row opens that league's page on
    the Pending tab when there are requests, otherwise All players.
  - **"Profile links awaiting your confirmation"** card with the profile,
    league, season, cost, balance and expiry. It offers **Confirm & link** or
    **Top up credits** (which goes to `/credits?returnTo=/`; after checkout
    the credits page shows a **Go back** link), plus **Decline**.
  - **"My player profiles"** list.
  - Each section is hidden when it has nothing to show.

## 13. Public site (`ui/`)

`ui/app/players/[id]/page.tsx` loads the career from
`/v1/player-links/players/{id}/career` (`actions/playerLink.actions.ts`) and
shows it newest first, with league and team links and a **Live** badge on
active seasons. Career averages are weighted by games played across all
linked seasons. The share image and Open Graph image show the four newest
seasons, with SPG in place of FG%. If the career call fails, the page still
renders without it.

## 14. Automated tests

- The full state machine, including invalid transitions.
- Approval never deducts credits, whatever the balance.
- The free tier links immediately, and the count stays correct under
  concurrent approvals.
- Confirm with too few credits returns 402 and changes nothing; confirm after
  a top-up links the profile. `ChargeCredits` debits the balance and records
  the transaction.
- Original claims: another user's original claim blocks requests; the
  holder can still link; it uses the shared free tier; the public summary
  shows the player as claimed.
- The expiry sweep and reminder; decline; revoke while
  `awaiting_confirmation` and while `approved`.
- One approval per player profile; other requests are auto-rejected after
  confirmation.
- Codes: valid, expired, reused, revoked, wrong player, and lockout after 5
  failures.
- The 10-requests-per-24h limit; the justification is required and its length
  is validated.
- Permissions: owner and editor allowed; viewer and stranger denied
  (including the league overview).
- League overview states and per-league summary counts; a non-manager gets no
  summaries.
- Snapshots and the career merge of live and frozen seasons; the public
  response has no uid.

### Running them

```sh
cd api
# Unit tests (no database needed)
go test ./internal/playerlink/
# Plus store integration tests against a scratch database with the schema applied
LINK_TEST_DATABASE_URL="postgres://basketball:basketball@localhost:5433/linktest?sslmode=disable" \
  go test ./internal/playerlink/ -count=1
```

The `linktest` database exists in the local `jsp_postgres` container. To
rebuild it, drop and recreate it, then load `migrations/1_create_tables.up.sql`.

## 15. Order of work

1. Migration (new tables and the copy of existing claims).
2. Link model and store, then the service (approval and confirmation split,
   credits on confirm), then tests.
3. Codes, rate limits, audit log and the worker.
4. Season snapshots, the career query and caching.
5. Handlers, routes and wiring in `cmd/api`.
6. Emails.
7. App UI: claim modal, the league link page (All players and claims tabs),
   then the dashboard sections.
8. Public `ui` career table.

---

## 16. Functional test plan (manual)

### Setup

| Actor | Account | Notes |
|---|---|---|
| **Owner A** | owns League A (active) and League C (completed) | |
| **Editor A** | `editor` role on League A | |
| **Viewer A** | `viewer` role on League A | |
| **Owner B** | owns League B (active) | |
| **Player P** | regular user | starts with free tier unused and 0 credits |
| **Player Q** | regular user | used to test competing requests |

- Each league has a player row representing P: `P-A`, `P-B` and `P-C`.
- Each league has at least 2 games with stats recorded for that player row.
- Have access to the inboxes for all accounts (or the Resend dashboard or
  logs).
- Note the values of `FreeTierPlayerProfileCard` (1) and
  `CostPlayerProfileCard` (100 credits) before you start.
- Emails: set `RESEND_API_KEY` and `RESEND_FROM_EMAIL` in `.env`, then run
  `docker compose up -d api`. Without them, check the API logs for
  `Player link notification (email disabled)` lines instead.
- **Running the worker on demand:** the link worker runs at API start-up and
  then hourly. To run it now, use `docker restart jsp_api`.

### A. Request with justification

1. Log in as P. Open `P-A` and click **This is me**, then the
   **Request approval** tab.
2. With an empty note, **Expect:** **Send request** is disabled.
3. With a 5-character note, **Expect:** the counter shows "(min 10)" in red
   and **Send request** stays disabled. Calling the API directly returns 400.
4. Submit with a valid note. **Expect:** the status chip shows "Pending"; no
   credits were deducted.
5. **Expect:** Owner A and Editor A each get a "new pending request" email
   that includes the note; its button opens the league's **Pending** tab.
6. Try to submit another request for `P-A`. **Expect:** it is blocked because
   one is already pending.

### B. Permissions

1. As Viewer A, open League A's teams page. **Expect:** no
   **Player Link Requests** button. Opening `/leagues/<A>/claims` directly
   shows "You don't have permission…" and no player list or controls.
2. As Owner B, call `POST /v1/player-links/claims/{id}/approve` for P's
   League A claim. **Expect:** 403.
3. As Editor A, open `leagues/A/claims?tab=pending`. **Expect:** P's request
   is visible with the justification.
4. As Editor A, edit a game and a player in League A as usual. **Expect:**
   nothing about sharing permissions has changed.

### C. Reject, then request again

1. As Editor A, reject with the note "Not on our roster".
2. **Expect:** P gets a rejection email with the note; the chip shows
   "Rejected", with the note.
3. As P, request again with a new note. **Expect:** it is accepted and shows
   as pending.
4. As Owner A, open the History tab. **Expect:** both requests and the
   rejection are listed.

### D. Approval within the free tier

1. As Owner A, approve P's request for `P-A`.
2. **Expect:** the status is "Linked" immediately; there is no confirmation
   step and no credits are deducted.
3. **Expect:** P gets the "Approved, free tier" email.
4. On `P-A`'s page, **Expect:** P's link panel shows no free links left. The
   credits page usage count does **not** change: it comes from the untouched
   credits module, which only counts original claims (section 6).

### E. Approval beyond the free tier, then confirmation

Run this once P has used the free tier; repeat D first if needed.

1. As P (0 credits), request `P-B`. As Owner B, approve it.
2. **Expect:** Owner B sees the claim as approved with no error, whatever
   P's balance is. P's status is "Awaiting your confirmation".
3. **Expect:** P gets the "Approved, confirmation needed" email showing the
   cost and expiry date. Clicking its button opens the **login page**.
4. Log in as P. **Expect:** the dashboard shows the "Profile links awaiting
   your confirmation" card, with **Top up credits** because the balance is 0.
5. Call `POST /v1/player-links/claims/{id}/confirm` directly. **Expect:**
   402; the status is unchanged.
6. Click **Top up credits** and buy credits. **Expect:** back on the credits
   page, a "Credits added… Go back" banner appears. Clicking **Go back** opens
   the dashboard, and the card now shows **Confirm & link**.
7. Click **Confirm & link**. **Expect:**
   - the status is "Linked"
   - the balance is reduced by `CostPlayerProfileCard`
   - a `credit_transactions` row with `-100` and reason
     `player_profile_slot` exists
   - P gets the receipt email
8. Click confirm again (or replay the request). **Expect:** an error, and no
   second charge.

### F. Decline and expiry

1. Get another claim to the "Awaiting confirmation" state, then click
   **Decline**. **Expect:** the status is `cancelled`; no credits are charged.
2. Get another claim to the "Awaiting confirmation" state. In the database,
   set `player_link_claim.approval_expires_at` to now + 2 days and run the
   worker (see Setup). **Expect:** P gets the reminder email, and only once,
   even if the worker runs again.
3. Set `approval_expires_at` to the past and run the worker. **Expect:** the
   status is `expired`, the card disappears, and P can request again. No
   email is sent for the expiry.

### G. Competing requests (one approval per profile)

1. P and Q both request `P-A2`, a fresh player row in League A.
2. As Owner A, approve Q's request. With Q beyond the free tier, it is
   awaiting confirmation. **Expect:** P's request is still pending; approving
   P now fails because the profile already has an approval.
3. Q declines. **Expect:** Owner A can now approve P.
4. Repeat with Q confirming instead of declining. **Expect:** P's pending
   request is auto-rejected.

### H. Verification code

1. As Editor A, open a fresh player row's page and click **Generate code** in
   the **Verification code** panel. **Expect:** the code (XXXX-XXXX) is shown
   once with a Copy button. After reloading the page, it shows only "An unused
   code is active until …".
2. As P, enter a wrong code 5 times. **Expect:** an "invalid code" error each
   time, then a lockout message on the 6th attempt (even with the correct
   code). Wait an hour or clear `player_link_attempt` to continue.
3. Enter the correct code. **Expect:** the same free-tier/confirmation split
   as an approval.
4. **Expect:** Owner A and Editor A get the "code redeemed" alert email with a
   link to review or revoke.
5. Use the same code again, as P or as Q. **Expect:** rejected, because the
   code has been used.
6. Generate a code, then generate a second one. **Expect:** the first code no
   longer works.
7. Use a code generated for a different player row. **Expect:** rejected.
8. Set a code's `expires_at` to the past. **Expect:** rejected as expired.

### I. Revoke (rollback)

1. As Editor A, revoke P's linked `P-A` with a reason. **Expect:**
   - the status is `revoked`
   - P gets an email with the reason
   - no credits are refunded
   - League A's seasons disappear from P's career on the public profile
     straight away (the career cache is cleared on revoke)
2. Revoke a claim that is awaiting confirmation. **Expect:** the dashboard
   card disappears and no charge is possible.
3. Revoke a link that came from a code. **Expect:** this works the same way.
4. **Expect:** every action appears in the History tab with the actor and
   time.

### J. Career seasons and snapshots

1. With P linked to `P-A` (active), `P-B` (active) and `P-C` (completed), open
   P's public profile on the `ui` site, starting from any of the three player
   rows. **Expect:** all three seasons are listed with correct
   league/team/season and per-game stats. The app's player page shows the
   same career.
2. Check the database. **Expect:** `player_season_stats` has rows for League
   C (and any other completed/archived league), not for A or B.
3. As Owner A, set League A to `completed`, then run the worker (see Setup).
   **Expect:** snapshot rows appear for League A's players; the public
   numbers are unchanged. (Without running the worker, this happens within
   the hour.)
4. Edit a game stat in League A, which is now completed, then run the worker.
   **Expect:** the snapshot updates, and within 5 minutes (the career cache)
   the public profile shows the new value.
5. Set League A back to `active` and run the worker. **Expect:** League A's
   snapshot rows are deleted, and the stats still show (now calculated live).
6. Archive League C. **Expect:** its season is still shown.
7. Open an unlinked player's public profile. **Expect:** only that player's
   own season is shown.
8. Check the public `GET /v1/player-links/players/{id}` response. **Expect:**
   only `claimed`/`linkedProfileCount` (and nothing about the account).

### K. Rate limit and unlinking

1. As P, make 10 requests within 24 hours (code redemptions count too), then
   an 11th. **Expect:** the 11th is rejected with "request limit reached, try
   again tomorrow".
2. As P, unlink a linked profile. **Expect:** the status is `cancelled`; its
   seasons leave the career view; no refund.

### L. Existing claims (copied at migration)

1. For a claim that existed in `player_profile_claim` before the migration,
   check `player_link_claim`. **Expect:** a row with the same id,
   `status='approved'`, `method='legacy'`.
2. Open that player's public profile. **Expect:** it shows as linked, and the
   career includes that user's other linked profiles.
3. Restart the API so the migration runs again (drop a new table first, e.g.
   `player_link_attempt`). **Expect:** no duplicate legacy rows.

### M. League admin overview

1. As Owner A, open the dashboard. **Expect:** a **Player links in my
   leagues** section listing League A and League C with pending, awaiting,
   linked and not-linked counts; leagues with pending requests come first.
2. As P (who manages no leagues), open the dashboard. **Expect:** no such
   section.
3. As Owner A, click League A. **Expect:** it opens on the Pending tab if
   there are requests, otherwise **All players**.
4. On **All players**, **Expect:** every player in League A is listed,
   including ones nobody has requested, with the right state chip and, for
   linked players, the linked account's name and email.
5. Search by player name, team and linked email, and filter by state.
   **Expect:** the list narrows correctly.
6. On a not-linked player, click **Generate code**. **Expect:** the code
   shows once under the row with Copy; "Code active until …" appears after
   reload. **Revoke code** removes it.
7. On a pending player, click **Review**. **Expect:** the Pending tab opens.
8. On a linked player, click **Revoke link**, enter a reason and confirm.
   **Expect:** the row goes back to Not linked and P gets the revoke email.
9. As Editor A, repeat steps 1 and 4. **Expect:** the same view as the owner.
   As Viewer A, `GET /v1/player-links/leagues/{A}/players` returns 403.

### N. Original claim endpoints (unchanged)

1. Call `GET /v1/players/{id}/claim` for any player. **Expect:** the original
   response shape (`{"claim": …}`), working as before.
2. As Q, claim an unlinked player `X` through
   `POST /v1/players/{X}/claim`. **Expect:** it works as before (instant).
3. As P, request `X` through the app. **Expect:** 409 "already linked to
   another account". `GET /v1/player-links/players/{X}` shows
   `claimed: true`.
4. As Q, request `X` through the app and approve it as the league owner.
   **Expect:** allowed and linked straight away with no charge, because Q
   already holds that profile (the profile being linked is never counted
   against the free tier).
