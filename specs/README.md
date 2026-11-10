# Jump Stop Pivot — Specifications

Engineering documentation for the JSP basketball platform. Each document describes the system
**as implemented**. Last full pass: 2026-10-29.

| Document | Answers |
|---|---|
| [functional-spec.md](functional-spec.md) | What does the product do, for whom, through which screens? |
| [technical-spec.md](technical-spec.md) | How is it built: architecture, API, data model, real-time, deployment? |
| [business-rules.md](business-rules.md) | What exact rules govern access, credits, scoring, standings…? (stable `BR-*` IDs) |
| [open-issues.md](open-issues.md) | Where does the code look wrong or contradict other sources? (`OI-*` IDs) |

Related docs that stay authoritative for their topic:
- [DOCKER.md](../../DOCKER.md): local environment
- [REALTIME_TRANSPORT.md](../../REALTIME_TRANSPORT.md): why WebSockets rather than SSE for recorders
- [app/STATSHEET_SYNC.md](../../app/STATSHEET_SYNC.md): statsheet sync design
- [api/docs/](../../api/docs/): Swagger, ERD and DBML (generated)
- [docs/README.md](../README.md): third-party integration guide

## Maintaining these docs
- If a PR changes behaviour covered by a `BR-*` rule, update the rule in the same PR.
- When you fix an `OI-*` item, delete it and update any rule that linked to it.
- Code links point at `path:line`. Line numbers drift, so treat them as hints and the function name as the anchor.

## Glossary
| Term | Meaning |
|---|---|
| **Owner / Editor / Viewer** | Per-entity roles stored in `*_sharing` tables |
| **Share token / share link** | Short-lived JWT in `?token=` that lets a guest act on one game without logging in |
| **Public user** | Identity assigned to unauthenticated requests (`UserID = "public-user"`) |
| **Credits** | Prepaid in-app currency (also called "tokens" in the UI and Stripe metadata) spent on leagues, games and profile claims beyond the free tier |
| **Free tier** | Per-user allowances: 1 league, 1 player-card claim, 30 games |
| **Plan** | `user_plan` row with a feature list. `leagues_premium` is the only feature used |
| **Statsheet** | Courtside live stat-recording screen in the admin app |
| **Coach/bench stats** | Team-level per-period data: team fouls, time-outs, technicals, possession arrow |
| **Merge vs upsert** | Increment-based vs full-replace stats writes |
| **Integration** | Third-party app registered with client credentials, acting through Firebase custom tokens |
| **Quick Game** | One-shot creation of league + teams + players + game |
