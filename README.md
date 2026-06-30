# Jump Stop Pivot — Integration Guide

Integrate your application with the Jump Stop Pivot (JSP) basketball API. This guide covers everything you need to authenticate server-to-server and provision your users with JSP accounts — no Firebase SDK required on your end.

**Base URL:** `https://api.jumpstoppivot.com`

---

## Overview

JSP integrations use a two-token model:

| Token | Purpose |
|---|---|
| **Integration token** | Authenticates your *application* (M2M). Used server-to-server. |
| **User token** | Authenticates an *end user* of your app within JSP. Passed to your frontend. |

You exchange a `clientId` + `clientSecret` for the integration token. You use the integration token to provision user tokens. All token exchanges happen over plain HTTPS — no Firebase SDK needed on your side.

---

## Step 1 — Create a JSP Account and Register Your Integration

You'll need a JSP account before you can register an integration.

Once you have an account, call the register endpoint using your account's Firebase `idToken` as the Bearer token:

```http
POST /v1/integrations
Authorization: Bearer {your-jsp-account-idToken}
Content-Type: application/json

{
  "name": "My App",
  "scopes": ["read:leagues", "read:stats", "write:stats"]
}
```

**Response `201`:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "clientId": "YOUR_CLIENT_ID",
  "clientSecret": "YOUR_CLIENT_SECRET",
  "name": "My App",
  "scopes": ["read:leagues", "read:stats", "write:stats"],
  "active": true,
  "createdAt": "2026-06-30T10:00:00Z"
}
```

> **Save `clientSecret` immediately.** It is shown once and never stored in plaintext. Treat it like a password — store it in an environment variable or a secrets manager.

---

## Step 2 — Get an Integration Token

Exchange your credentials for a token. This is a server-side call — never expose `clientSecret` to a browser or mobile app.

```http
POST /v1/integrations/token
Content-Type: application/json

{
  "clientId": "YOUR_CLIENT_ID",
  "clientSecret": "YOUR_CLIENT_SECRET"
}
```

**Response `200`:**
```json
{
  "idToken": "YOUR_ID_TOKEN",
  "refreshToken": "YOUR_REFRESH_TOKEN",
  "expiresIn": 3600
}
```

Store both tokens. The `idToken` is valid for **1 hour**. The `refreshToken` does not expire but rotates on every refresh.

---

## Step 3 — Refresh the Integration Token

When the `idToken` expires, refresh it through JSP:

```http
POST /v1/integrations/token/refresh
Content-Type: application/json

{
  "refreshToken": "YOUR_REFRESH_TOKEN"
}
```

**Response `200`:**
```json
{
  "idToken": "YOUR_ID_TOKEN",
  "refreshToken": "YOUR_REFRESH_TOKEN",
  "expiresIn": 3600
}
```

> The `refreshToken` rotates — always store the new value returned in the response.

---

## Step 4 — Make API Calls

Use the `idToken` as a standard Bearer token on all JSP API calls:

```http
GET /v1/leagues
Authorization: Bearer {idToken}
```

Your integration token carries custom claims identifying your app. JSP uses these to enforce access and audit API usage.

---

## Step 5 — Provision Your End Users (SSO)

When one of your users needs access to JSP, provision them from your backend using your integration token. JSP will find or create a JSP account for that user and return tokens you can pass directly to your frontend.

```http
POST /v1/integrations/users/provision
Authorization: Bearer {integration-idToken}
Content-Type: application/json

{
  "email": "john@example.com",
  "name": "John Doe"
}
```

**Response `200`:**
```json
{
  "idToken": "YOUR_ID_TOKEN",
  "refreshToken": "YOUR_REFRESH_TOKEN",
  "isNewUser": true,
  "expiresIn": 3600
}
```

- `isNewUser: true` — a new JSP account was created for this email.
- `isNewUser: false` — an existing JSP account was found. No duplicate is created.

Pass `idToken` to your frontend. Your frontend uses it directly as a Bearer token on JSP API calls.

---

## Step 6 — Refresh User Tokens

Refresh user tokens the same way — through the JSP proxy:

```http
POST /v1/integrations/token/refresh
Content-Type: application/json

{
  "refreshToken": "YOUR_REFRESH_TOKEN"
}
```

Pass the new `idToken` to your frontend when needed.

---

## Token Lifecycle Summary

```
Your backend                    JSP API                  Your frontend
─────────────────────────────────────────────────────────────────────────

1. POST /v1/integrations/token (clientId + clientSecret)
   └─► { idToken, refreshToken }  ← store server-side

2. POST /v1/integrations/users/provision (integration idToken + user email)
   └─► { user idToken, user refreshToken }
         └─► pass idToken to frontend ─────────────────────────────────►
                                                 Bearer idToken on JSP calls

3. When idToken expires:
   Your backend ─► POST /v1/integrations/token/refresh (refreshToken)
                    └─► new idToken ──────────────────────────────────►
```

---

## Managing Integrations

### List your integrations
```http
GET /v1/integrations
Authorization: Bearer {your-jsp-account-idToken}
```

### Revoke an integration
```http
DELETE /v1/integrations/{id}
Authorization: Bearer {your-jsp-account-idToken}
```

Revocation disables the integration's Firebase identity immediately. Any `idToken` minted for that integration will expire within the hour and cannot be refreshed.

---

## Security Notes

| Concern | How it's handled |
|---|---|
| `clientSecret` never stored plaintext | bcrypt-hashed in JSP's database |
| Short-lived access tokens | `idToken` expires in 1 hour |
| Token rotation | `refreshToken` rotates on every refresh |
| Instant revocation | Revoking disables the Firebase identity — no new tokens can be minted |
| User deduplication | Provisioning by email never creates duplicate accounts |
| No client-side Firebase exposure | Firebase API key is only needed on your backend for token refresh |

---

## Endpoint Reference

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/v1/integrations` | User Bearer token | Register a new integration |
| `GET` | `/v1/integrations` | User Bearer token | List your integrations |
| `DELETE` | `/v1/integrations/{id}` | User Bearer token | Revoke an integration |
| `POST` | `/v1/integrations/token` | None — clientId + clientSecret | Exchange credentials for tokens |
| `POST` | `/v1/integrations/token/refresh` | None — refreshToken in body | Refresh an idToken (integration or user) |
| `POST` | `/v1/integrations/users/provision` | Integration Bearer token | Provision an end user |

---

## Checklist

- [ ] Created a JSP account
- [ ] Called `POST /v1/integrations` and saved `clientId` + `clientSecret` securely
- [ ] Server-side: exchange credentials for integration `idToken` + `refreshToken` on startup
- [ ] Server-side: refresh integration token before it expires (1 hour)
- [ ] Server-side: call provision endpoint per user and pass `idToken` to frontend
- [ ] Frontend: include `Authorization: Bearer {idToken}` on all JSP API calls
- [ ] Server-side: handle user token refresh and relay new `idToken` to frontend

---

Questions or issues? Contact the JSP team at [support@jumpstoppivot.com](mailto:support@jumpstoppivot.com).
