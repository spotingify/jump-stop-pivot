# Open Issues & Discrepancies

These were found while writing the specs (2026-10-29). Each one is a place where the code
looks wrong, contradicts another source, or needs a product decision. None of them
has been changed yet. Every item needs an owner decision: **fix**, **accept and document**, or
**won't fix**.

Severity: 🔴 critical · 🟠 high · 🟡 medium · ⚪ low / docs

---

## Security

### OI-SEC-01
🔴 **Team, game and player sharing endpoints have no authorization.**
`POST /v1/{teams|games|players}/{id}/sharing` writes `{firebaseUid, role}` straight into the
sharing table. `DELETE …/sharing/{uid}` and `GET …/sharing` are also unchecked. The caller's
identity is discarded, and `RequestAuthCheck` accepts the anonymous public user (BR-AUTH-002).
So **anyone, without signing in, can grant themselves `owner` on any game, team or player**,
and then edit or delete it, or list who it is shared with.
- [game_handler.go:552-591](../../api/internal/league/game_handler.go#L552-L591), [team_handler.go:~410-500](../../api/internal/league/team_handler.go), [player_handler.go:~480-610](../../api/internal/league/player_handler.go)
- Suggested fix: require that the caller is `owner` of the entity, the same way `LeagueService.ShareLeague` does it. Reject `PublicUser` in `RequestAuthCheck`, or add a `RequireSignedIn` helper.

### OI-SEC-02
🔴 **Integration user provisioning can impersonate any existing account.**
`ProvisionUser` uses `FindOrCreateFirebaseUser(email)`. If the email already belongs to a JSP
user, it returns a valid ID token **for that user**. Any signed-in user can self-register an
integration (BR-INT-001), so any user can take over any other account if they know its email.
- [integrations/service.go:163+](../../api/internal/integrations/service.go#L163), [pkg/firebase/admin.go:118-143](../../api/pkg/firebase/admin.go#L118-L143)
- Suggested fix: only mint tokens for users that this integration created or that have explicitly linked to it. Consider requiring approval before an integration can provision users.

### OI-SEC-03
🟠 **Users can create and modify plans themselves.**
`POST /v1/users/plan`, `PUT /v1/users/plan/{id}` and `DELETE /v1/users/plan/{id}` only call
`RequestAuthCheck`. A user can give themselves `leagues_premium`. Today that only affects the
client-side gate (BR-PLAN-001), but it becomes a real bypass as soon as the API starts trusting plans.
Update and delete by `id` also do not check that the plan belongs to the caller.
- [user/user_handler.go:181-314](../../api/internal/user/user_handler.go#L181)

### OI-SEC-04
🟠 **Integration scopes are never enforced** (BR-INT-003). The developer UI and the integration guide
present scopes as a permission boundary, but they are not one.

### OI-SEC-05
🟡 **The CSV player import does not appear to check the caller's role on the league.**
It is defined in `league_handler_public.go` and the store creates teams and players in any `leagueId`.
This needs confirmation.
- [league_handler_public.go:338](../../api/internal/league/league_handler_public.go#L338), [player_store.go:1032](../../api/internal/league/player_store.go#L1032)

### OI-SEC-06
🟡 **Anonymous users can create content.** Create endpoints run as `UserID = "public-user"`, so
every anonymous visitor shares one owner identity and one free-tier allowance. This needs a decision on whether create endpoints should reject the public user.

### OI-SEC-07
⚪ **The API-key middleware logs the first 10 characters of both the received and the expected key** when they don't match.
- [pkg/middleware/apikey.go:38-46](../../api/pkg/middleware/apikey.go#L38-L46)

### OI-SEC-08
⚪ **Share links cannot be revoked before they expire** (stateless JWT, 4 h). The `GenerateShareLink` doc comment says it "inserts a temporary game_sharing record". It does not.

---

## Business logic

### OI-BIZ-01
🟠 **The public pricing page does not match the API's credit packages.**

| | API (`credits_model.go`) | Pricing page (`ui/app/pricing/PricingClient.tsx`) |
|---|---|---|
| $9.99 | 300 credits | 320 credits ("= 8 Player Profile Cards" at 100 each would be 800) |
| $29.99 | 1 000 credits | 2 000 credits |
| $79.99 | 3 000 credits | 6 000 credits |
| Free games | 30 | "50 × real-time game scoring" |

The `CreateGame` doc comment also says 50. **Decision needed:** which figures are correct?

### OI-BIZ-02
🟠 **The Stripe webhook is not idempotent.** If Stripe retries `checkout.session.completed`, the credits are added twice.
Add a `UNIQUE` constraint on `credit_transactions.stripe_session_id` (partial, `WHERE stripe_session_id IS NOT NULL`) and use `ON CONFLICT DO NOTHING`.

### OI-BIZ-03
🟡 **Credits are deducted before the create, so a failed create loses them.** Deduct and create should share one transaction. `DeductInTx` already exists for this.

### OI-BIZ-04
🟡 **`leagues_premium` is only checked on the client.** The API still charges premium users for leagues beyond the first.

### OI-BIZ-05
🟡 **Score derivation uses each player's *current* team.** Moving a player to another team rewrites
historical scores for every game within the window. The `UpdateScoresFromStats` doc comment says it only
updates games where both scores are 0. The SQL does not do that: it overwrites any stats-enabled game dated up to 2 days ahead.
- [game_store.go:1028-1057](../../api/internal/league/game_store.go#L1028-L1057), [game_service.go:445](../../api/internal/league/game_service.go#L445)

### OI-BIZ-06
🟡 **Standings count unplayed games.** Scheduled 0–0 games add to *Played* and drag down win %.
Draws are counted as played without a W or L. Basketball has no draws, so a 0–0 almost always means the game has not been played.

### OI-BIZ-07
🟡 **Anyone can claim any player profile** with no verification (first come, first served).

### OI-BIZ-08
⚪ **League `status` silently resets to `draft`** if an update omits it (BR-LEAGUE-001). This can unpublish a league from the public site.

### OI-BIZ-09
⚪ **Unused constants:** `FreeTierGameStatsPro`, `CostGameStatsPro` and `GamesIncludedWithLeague`.

---

## Technical / docs drift

| ID | Issue |
|---|---|
| OI-TECH-01 | [api/README.md](../../api/README.md) describes a "Mini 4WD racing" API (copied from another project). `pkg/config` still reads `RACE_EXTERNAL_API_URL` and `PAYLOAD_EXTERNAL_API_KEY`. The ERD/DATABASE.md title says "VeloInterest API". |
| OI-TECH-02 | Migration 4 reshapes coach stats to entry-level `homeTimeOuts` etc. The current Go model instead uses a `periodStats[]` array. Rows migrated by migration 4 will not deserialize time-outs. |
| OI-TECH-03 | Migrations 2 and 3 are manual scripts, and #2 contains a `REPLACE_WITH_FIREBASE_UID` placeholder. Only the file in `MIGRATION_FILE_PATH` runs on startup, and only if tables are missing. There is no migration version tracking. |
| OI-TECH-04 | The WebSocket hub is in-memory, so it only works on a single API instance. Redis pub/sub only fans out to the Next.js SSE stream, not across API instances. |
| OI-TECH-05 | `internal/league` has **no Go tests**. Only `pkg/` has a few. |
| OI-TECH-06 | Legacy Firebase Functions (`getLeaguePurchaseCount`, `useLeagueCredit`, Firestore `customers/*`) implement an older per-league purchase model. Only `app/app/actions/checkout.actions.ts` still references them. Confirm whether they are dead code. |
| OI-TECH-07 | `app/` does not follow the standard React layout in `~/.claude/CLAUDE.md`. It uses flat `routes/`, `actions/`, `components/` and `types/` folders, the React Router file-route config instead of a `RouteObject[]`, and the `~/` alias alongside `@/`. `coffee/` is the only domain-shaped folder. |
| OI-TECH-08 | Integration auth uses `?auth=<idToken>` as a query-param fallback, so tokens can end up in access logs. |
| OI-TECH-09 | `FirebaseMiddleware` calls `log.Fatalf` if it fails to get the Auth client, which kills the whole process from inside a request. |
