# Functional Specification — Jump Stop Pivot

> **Status:** describes the product **as built** on 2026-10-29.
> Rules referenced as `BR-*` are in [business-rules.md](business-rules.md); known gaps as `OI-*` in [open-issues.md](open-issues.md).

## 1. Product overview

**Jump Stop Pivot (JSP)** is a basketball league management and live-stats platform. Organisers set up
leagues, teams, players and fixtures. Statisticians record stats live from courtside, with several people at once if needed. The
public follows scores, standings, box scores and player profiles in real time on a public website.

Production domains: `jumpstoppivot.com` (public site), `app.jumpstoppivot.com` (admin app), `api.jumpstoppivot.com` (API).

### 1.1 Surfaces

| Surface | Code | Audience | Purpose |
|---|---|---|---|
| **Public site** | `ui/` (Next.js) | Fans, parents, players, search engines | Browse leagues, teams, players, games, standings and live scores. Marketing, pricing and donations. |
| **Admin app** | `app/` (React Router SPA) | Organisers, coaches, statisticians | Manage data, record live stats, buy credits, manage integrations |
| **Public API** | `api/` (Go) | Third-party developers | Integrate their own apps with JSP (see [docs/README.md](../README.md)) |

## 2. Personas

| Persona | Goals | Primary surface |
|---|---|---|
| **League organiser** | Create a league, register teams and players, schedule games, publish results | Admin app |
| **Statistician / scorer** | Record player and bench stats live during a game, often on a phone or tablet courtside | Admin app → Statsheet |
| **Guest scorer** | Help score one game without needing an account | Statsheet via share link |
| **Collaborator** | Help manage a league that someone else owns (editor) or just follow it (viewer) | Admin app |
| **Player** | Claim their profile card and view their stats history | Admin app + public site |
| **Fan / public viewer** | Follow live scores, standings and leaders | Public site |
| **Integration developer** | Provision JSP accounts for their own users and read or write league data | API |

## 3. Feature catalogue

### 3.1 Accounts & authentication
- Sign up / log in with email and password or Google (Firebase Auth); forgot-password flow.
- On first login an app profile is created along with a **default league** (BR-LEAGUE-002).
- Admin routes sit behind an auth guard. `/statsheet/:gameId` also accepts a share-link token instead of a login.

Admin routes: `/login`, `/signup`, `/signout`, `/forgot-password`.

### 3.2 Dashboard (`/`)
The landing page after login. It shows today's games, quick links, credit warnings, and the **Quick Game** shortcut.

### 3.3 Leagues (`/leagues`, `/leagues/:id/teams`)
- List the leagues you own or that are shared with you, with your role badge.
- Create, edit and delete a league: name, description, status (`draft` / `active` / …), season, start date.
- Creating a league beyond the free allowance needs credits. The UI checks affordability first and shows a purchase prompt (BR-CRED-001).
- **Share** a league by email as viewer or editor. Access flows down to every team, player and game in it (BR-ROLE-004/005).
- Only **active** leagues appear on the public site (BR-LEAGUE-003).

### 3.4 Teams (`/teams`, `/teams/:teamId`)
- CRUD for teams within a league, with an optional photo.
- The team detail page shows the roster, games and stats.

### 3.5 Players (`/players`, `/leagues/:leagueId/players`, `/teams/:teamId/players`, `/players/:playerId`)
- CRUD for players: name, number, position, team and photo.
- **CSV import** into a league. Teams are created automatically from a team-name column (BR-PLAYER-001). Sample files are `api/sample_players*.csv`.
- Assign a player to a team.
- **Profile claim:** a signed-in user claims a player card as "me". The first claim is free and later ones cost credits (BR-PLAYER-002).
- Player detail shows season averages and game-by-game history.

### 3.6 Games (`/games`, `/games/:gameId`, `/leagues/:leagueId/games`, `/teams/:teamId/games`)
- Schedule a game in a league with home and away teams, date/time, location and description.
- Toggle **stats enabled**.
- Generate a **share link** (owner or editor) that lets someone score this game for 4 hours without an account (BR-SHARE-001).
- Game detail shows the score, box score and a link into the statsheet.
- Creating games beyond the free allowance costs credits.

### 3.7 Quick Game
One-click setup for pickup games. It creates a league (if none is selected), two teams with placeholder players, and the game in a single step, then takes you straight to the statsheet (BR-QUICK-001).

### 3.8 Live Statsheet (`/statsheet/:gameId`)
The core feature. It has a full-screen, minimal-chrome layout designed for courtside use.

- Pick a player from the home or away roster, then tap a stat: points (1/2/3), rebounds, assists, steals, blocks, turnovers, fouls, technical and flagrant fouls. Each stat can be decremented to undo.
- A period selector covers Q1–Q4 and OT.
- Players can be toggled on court, and jersey numbers can be edited inline.
- The **coach/bench panel** tracks possession arrow, team fouls per period, time-outs per period, and team technical fouls.
- **Multi-recorder:** several scorers can record the same game at once without overwriting each other (BR-STAT-003).
- **Offline-tolerant:** changes are buffered locally and re-sent on reconnect. A status badge shows *Live*, *Syncing* or *Offline* (BR-STAT-005).
- Scores roll up automatically from player points within about 1 minute (BR-GAME-003).

### 3.9 Standings & leaders (`/standings`, public `/standings`, `/leagues/[id]/stats`)
- League table: P, W, L, PF, PA, Diff, Win %. Sorted by wins, then point differential (BR-STAND-001).
- Stat leaders: top 5 per category per league (BR-STAND-003).

### 3.10 Credits (`/credits`)
- Shows the balance, free-tier usage (leagues 1, player cards 1, games 30) and transaction history.
- Buy a credit pack through Stripe Checkout (BR-CRED-005/006).
- Warning banners appear across the app when credits run low.

### 3.11 Developer portal (`/developer`)
- Register an integration: name and scopes. The client ID and secret are shown once.
- List and revoke integrations.
- Integration guide and Postman collection: [docs/README.md](../README.md), [docs/JSP_Integrations.postman_collection.json](../JSP_Integrations.postman_collection.json).

### 3.12 Public site (`ui/`)
| Route | Content |
|---|---|
| `/` | Hero, live game carousel, league dashboard |
| `/leagues`, `/leagues/[id]` | Active leagues, league overview |
| `/leagues/[id]/players`, `/leagues/[id]/stats` | League roster, stat leaders |
| `/teams`, `/teams/[id]` | Teams, roster, team stats |
| `/players`, `/players/[id]` | Player directory, profile card and history |
| `/games`, `/games/[id]` | Fixtures and results. Game detail updates **live** over SSE, including the coach/bench stream |
| `/standings`, `/stats` | Standings and leaders |
| `/features`, `/pricing`, `/privacy`, `/thank-you` | Marketing, legal and donation pages |

Every entity page also has generated **Open Graph images** for social sharing, plus a sitemap and robots.txt.
The site shows a "Buy me a coffee" donation button (BR-COFFEE-001) and an AdSense banner.

### 3.13 Guide (`/guide`)
In-app user guide.

## 4. Key user journeys

### 4.1 New organiser → first live game
1. Sign up. A default league is created automatically.
2. Open **Quick Game**, or create teams, import players by CSV, and schedule a game.
3. Open the game and go to its statsheet (`/statsheet/:gameId`).
4. Record stats. The public `/games/[id]` page updates live.
5. Standings and player averages update automatically (within 1 min and 60 min respectively).

### 4.2 Recruit a guest scorer
1. The owner or editor opens the game, generates a share link, and copies the URL with `?token=`.
2. The guest opens the link. The statsheet loads without login and allows writes for 4 hours, for this game only.

### 4.3 Co-manage a league
1. The owner shares the league with a collaborator's email as **editor**.
2. Within a few seconds (it runs asynchronously) the collaborator sees the league and all its teams, players and games.

### 4.4 Player claims profile
1. The player signs up, finds their player page and chooses **Claim**.
2. The first claim is free. Later claims cost 100 credits each.

### 4.5 Third-party integration
1. The developer registers an integration in `/developer`.
2. Their backend exchanges the client ID and secret for a token, then provisions JSP users by email.
3. Their frontend calls the JSP API with each user's token.

## 5. Out of scope / not implemented
- Game lifecycle states (scheduled, live, final), forfeits, and overtime rules beyond the "OT" label.
- Per-period player stats on the server. Periods are kept only for team fouls and time-outs.
- Shot charts, minutes played, and plus/minus.
- Admin or back-office tooling for plans. Plans are set through raw endpoints or SQL.
- Email notifications. A Resend client exists in `pkg/resend` but no domain uses it.
- Image upload pipeline. An R2 client exists in `pkg/r2`, and photos are stored as URLs.
