# Client Nginx Update Handoff

Status: Implemented in `bci-nginx`; orchestration follow-up pending  
Repository: `bci-nginx`  
Related source-of-truth repo: `bci-container-orch`

## Scope Clarification

This document is about the Nginx setup only.

It is not a handoff for implementing the Security service. Security is owned and
built separately. References to Security in this document exist only to define
the communication contract that client Nginx must support: which routes it
proxies to Security, what it sends in auth subrequests, what responses it
expects, and what identity context it forwards to Query Engine after Security
authorizes a request.

## Purpose

Update `bci-nginx` from its current standalone Podman proof of concept into the
client-specific web entrypoint for a BCI client stack.

This Nginx is not the shared host ingress. The shared host ingress remains a
separate host-level concern that can route public client hostnames to each
client's local web entrypoint. This repository should own the Nginx instance that
lives with one client stack and talks directly to that client's Security service
and Query Engine.

Target path:

```text
public/shared host ingress
  -> client Nginx web entrypoint
  -> client Security service
  -> client Query Engine
  -> client Postgres data/metadata
```

For a single-client deployment, the client Nginx may be bound directly to the
host's public `443`. For a multi-client shared host, it should usually bind to a
unique localhost port, for example `127.0.0.1:18443:443`, and the shared ingress
routes to it.

## Original Implementation Gaps

The original repo was a useful `auth_request` sketch, but it did not match the
current orchestration design. The `bci-nginx` repo now implements the Nginx-side
changes below; the related `bci-container-orch` work remains separate.

Required corrections:

1. Replace Podman-facing documentation and compose files with Docker-facing
   equivalents.
2. Expose HTTPS on container port `443`.
3. Treat this Nginx as a per-client web entrypoint, not the shared host ingress.
4. Join the client stack's internal Docker network rather than a shared external
   `bci-net`.
5. Proxy Query Engine traffic to its current internal port, `8300`, not `8080`.
6. Add a clear contract with the planned Security service.
7. Make upstream names, ports, and TLS material configurable for generated client
   stacks.
8. Keep Query Engine, Security, Postgres, email-service, and credential-helper
   internal to the client stack.

## Docker Runtime Changes

### File Naming

Use Docker-native names:

- Replace `podman-compose.yml` with `docker-compose.yml`, or remove repo-local
  compose if `bci-container-orch` owns the full client stack.
- Prefer `Dockerfile` over `Containerfile` for the image build. Docker can build
  `Containerfile`, but this repo should follow the rest of the stack's Docker
  convention.
- Update README commands from `podman` / `podman compose` to `docker` /
  `docker compose`.

### Compose Shape

This service should be added to the generated client stack in
`bci-container-orch`, not run on a shared external network.

Expected service shape:

```yaml
services:
  nginx:
    build:
      context: ${BCI_REPO_ROOT:-../..}/bci-nginx
    image: bci-nginx:latest
    env_file:
      - .env
    ports:
      - "${CLIENT_WEB_BIND:-127.0.0.1:18443}:443"
    volumes:
      - ${CLIENT_TLS_CERT_PATH}:/etc/nginx/tls/tls.crt:ro
      - ${CLIENT_TLS_KEY_PATH}:/etc/nginx/tls/tls.key:ro
    networks:
      - internal
    depends_on:
      security:
        condition: service_healthy
      query-engine:
        condition: service_healthy
```

Notes:

- `CLIENT_WEB_BIND` is the host binding for this client entrypoint.
- On a shared multi-client host, default to localhost-only bindings such as
  `127.0.0.1:18443`.
- On a single-client host, the deployment may override to `0.0.0.0:443`.
- Do not attach this container to other clients' networks.

## HTTPS Requirement

Nginx should listen on `443` inside the container.

Minimum TLS requirements:

- `listen 443 ssl;`
- certificate mounted read-only at runtime
- private key mounted read-only at runtime
- modern TLS protocols only, preferably `TLSv1.2 TLSv1.3`
- unauthenticated local `/healthz`

Example:

```nginx
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/tls/tls.crt;
    ssl_certificate_key /etc/nginx/tls/tls.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /healthz {
        access_log off;
        return 200 'ok';
    }
}
```

If local development needs self-signed certificates, document the generation
path, but keep the production contract as mounted certificate files or Docker
secrets.

## Configuration Templating

Avoid hard-coded upstream ports in the final Nginx config. The official Nginx
image supports runtime template substitution from `/etc/nginx/templates/*.template`.

Recommended defaults:

```text
SECURITY_UPSTREAM_HOST=security
SECURITY_UPSTREAM_PORT=8400
QUERY_ENGINE_UPSTREAM_HOST=query-engine
QUERY_ENGINE_UPSTREAM_PORT=8300
```

`8400` is the proposed Security service port to keep the stack convention:

```text
credential-helper: 8100
email-service:     8200
query-engine:      8300
security:          8400
client-nginx:      443
```

If the Security service chooses a different internal port, update the default in
both the security repo and this repo's template.

## Nginx Route Model

Only `/healthz` should be unauthenticated by default.

Security-owned routes should bypass `auth_request` and proxy directly to
Security:

- `GET /login`
- `GET /auth/callback`
- `POST /auth/callback` if the security implementation needs it
- `GET /logout` or `/auth/logout` if implemented

All Query Engine routes should be protected by `auth_request`, including:

- `GET /artifacts/{client_key}/{artifact_key}`
- `POST /artifact-executions`
- `GET /artifact-executions/{run_id}`
- legacy `/run/...` routes while they still exist

Nginx should not own role policy. It should pass method, path, user/session
context, and credentials to Security. Security decides whether the request is
authenticated and authorized.

## Nginx To Security Auth Contract

Nginx makes an internal auth subrequest before proxying protected traffic.

### Request

```http
GET /auth HTTP/1.1
Host: <client-hostname>
X-Real-IP: <remote-ip>
X-Forwarded-For: <proxy-chain>
X-Forwarded-Proto: https
X-Forwarded-Host: <client-hostname>
X-Original-Method: <original-method>
X-Original-URI: <original-uri>
X-Original-Host: <client-hostname>
Authorization: <incoming-authorization-if-present>
Cookie: <incoming-cookie-if-present>
```

Rules:

- Request body must not be forwarded for auth subrequests.
- `Content-Length` should be cleared.
- Security must be able to authorize from either a session cookie or an incoming
  bearer token.
- Security should use `X-Original-Method` and `X-Original-URI` for route-level
  authorization decisions.

### Successful Response

Security returns any `2xx` status when the request may continue.

Required response headers:

```http
Authorization: Bearer <internal-bci-jwt>
X-Identity-User-Id: <stable-user-id>
X-Identity-Email: <user-email>
X-Identity-Name: <display-name>
X-Identity-Roles: <comma-separated-roles-or-json>
X-Identity-Client-Key: <client-key>
```

The `Authorization` header must contain the internal BCI JWT or signed token,
not the raw Entra ID token. Query Engine should receive the internal token and
identity headers from Nginx.

Optional response headers:

```http
X-Identity-Tenant-Id: <entra-tenant-id>
X-Identity-Scopes: <authorized-scopes>
X-Auth-Expires-At: <iso8601-or-epoch>
```

### Not Authenticated

Security returns `401`.

Recommended response:

```http
HTTP/1.1 401 Unauthorized
Location: /login?return_to=<url-encoded-original-uri>
```

Nginx should redirect the browser to the `Location` header from Security. Avoid
hard-coding Microsoft login URLs in Nginx. Security owns Entra/OIDC redirects
because it owns the client tenant configuration.

### Authenticated But Forbidden

Security returns `403`.

Nginx may return a small forbidden page, or it may proxy a Security-provided
forbidden response if the implementation chooses that pattern.

## Browser Login Contract

Nginx proxies login and callback routes directly to Security.

### `GET /login`

Security responsibilities:

1. Read `return_to` if present.
2. Fetch this client's Entra app configuration through credential-helper.
3. Start the OIDC authorization-code flow with Entra.
4. Store any temporary state in a signed cookie or other stateless mechanism
   unless a later design explicitly adds a state store.

### `/auth/callback`

Security responsibilities:

1. Validate OIDC state and nonce.
2. Exchange the authorization code with Entra.
3. Validate the identity token.
4. Look up authorization in Postgres metadata security tables.
5. Issue a signed session cookie and/or internal BCI JWT.
6. Redirect back to the original `return_to` path.

Session cookie requirements:

- `HttpOnly`
- `Secure`
- `SameSite=Lax` unless the OIDC flow requires another value
- scoped to the client hostname
- no cross-client shared session state

## Nginx To Query Engine Contract

After a successful auth subrequest, Nginx proxies the original request to Query
Engine.

Default upstream:

```text
http://query-engine:8300
```

Required forwarded headers:

```http
Host: <client-hostname>
X-Real-IP: <remote-ip>
X-Forwarded-For: <proxy-chain>
X-Forwarded-Proto: https
Authorization: Bearer <internal-bci-jwt>
X-Identity-User-Id: <stable-user-id>
X-Identity-Email: <user-email>
X-Identity-Name: <display-name>
X-Identity-Roles: <roles>
X-Identity-Client-Key: <client-key>
```

Query Engine should not trust these headers from arbitrary callers. It should
only accept them from the client Nginx path on the internal client network, and
it should validate the internal token before querying data.

## Query Engine To Security Policy Contract

The orchestration security design says no Query Engine request should reach
Postgres without passing through Security policy enforcement. That is not fully
implemented today, so the developer should align with the Query Engine and
Security owners before finalizing this path.

Recommended baseline:

1. Nginx authenticates every browser/API request with Security.
2. Security returns an internal JWT to Nginx.
3. Nginx forwards the internal JWT to Query Engine.
4. Query Engine validates the JWT and asks Security to authorize the concrete
   artifact/query action before reading from Postgres.

Possible policy endpoint:

```http
POST /policy/check
Authorization: Bearer <internal-bci-jwt>
Content-Type: application/json

{
  "method": "GET",
  "path": "/artifacts/srp/visit-counts-quick-page",
  "client_key": "srp",
  "artifact_key": "visit-counts-quick-page",
  "action": "artifact.render"
}
```

Successful response:

```json
{
  "allowed": true,
  "client_key": "srp",
  "user_id": "user-id",
  "roles": ["viewer"]
}
```

Denied response:

```http
HTTP/1.1 403 Forbidden
```

Alternative: Security publishes a JWKS endpoint and Query Engine validates the
JWT locally for simple artifact permissions, then calls Security only for policy
decisions that require live metadata. That would reduce request latency, but it
must still preserve centralized authorization semantics.

## Security To Credential Helper Contract

Security needs client Entra configuration and signing key material from Vault via
credential-helper.

Existing credential-helper contract:

```http
POST /credential
Authorization: Bearer <SERVICE_TOKEN>
Content-Type: application/json

{
  "service_identity": "security",
  "item": "<vault-item-name>"
}
```

Security must use the client's `SERVICE_TOKEN`, not a shared cross-client token.

Expected credential categories:

- Entra tenant ID
- Entra client ID
- Entra client secret or certificate material
- Security JWT signing key or key reference, if stored in Vault

## Environment Variables

Expected new variables for generated client stacks:

```text
CLIENT_WEB_BIND=127.0.0.1:18443
CLIENT_TLS_CERT_PATH=/path/to/client/tls.crt
CLIENT_TLS_KEY_PATH=/path/to/client/tls.key
SECURITY_UPSTREAM_HOST=security
SECURITY_UPSTREAM_PORT=8400
QUERY_ENGINE_UPSTREAM_HOST=query-engine
QUERY_ENGINE_UPSTREAM_PORT=8300
```

Existing client stack variables still apply:

```text
COMPOSE_PROJECT_NAME=<client-stack-name>
SERVICE_TOKEN=<client-specific-token>
POSTGRES_PASSWORD=<client-specific-postgres-password>
BCI_REPO_ROOT=/shared/home
```

## Implemented Code Changes In This Repo

1. Replaced `podman-compose.yml` with Docker Compose wiring.
2. Replaced `Containerfile` with `Dockerfile`.
3. Changed the Nginx listener from `80` to `443 ssl`.
4. Changed Query Engine upstream from `query-engine:8080` to
   `query-engine:8300`.
5. Changed Security upstream from hard-coded `security:8081` to a templated
   default, proposed `security:8400`.
6. Removed the dependency on an external `bci-net`.
7. Added Nginx config templating for upstream host/port values.
8. Added certificate/key mount expectations.
9. Kept `/healthz` unauthenticated.
10. Added `/login`, `/auth/callback`, and logout route pass-throughs to
    Security.
11. Ensured `401` redirect target comes from Security's `Location` header, with
    `/login` as a fallback if Security omits the header.
12. Forwarded only the internal BCI JWT returned by Security to Query Engine,
    not incoming Entra tokens.
13. Updated README to explain client-stack role and Docker usage.

## Required Changes In Orchestration Repo

The `bci-container-orch` repo should be updated separately after this repo's
contract is accepted.

Expected changes:

1. Add `bci-nginx` to the current or planned repository list.
2. Add `nginx` and `security` services to the client stack template when
   `bci-security` exists.
3. Add `.env.example` values for `CLIENT_WEB_BIND`, TLS paths, and upstream
   defaults.
4. Update client onboarding docs to explain that Query Engine, email-service,
   credential-helper, and Postgres remain internal.
5. Explain the distinction between shared host ingress and client web entrypoint.

## Acceptance Criteria

A developer can consider the Nginx update complete when:

1. `docker build` succeeds.
2. `docker compose config` succeeds in a generated client stack.
3. Nginx listens on `443` inside the container.
4. `/healthz` returns `200` without Security or Query Engine.
5. Protected routes call Security via `auth_request`.
6. A `401` from Security redirects to the Security-provided login location.
7. A `403` from Security returns forbidden.
8. A `2xx` from Security proxies the original request to Query Engine on
   `query-engine:8300`.
9. Query Engine receives the internal JWT and identity headers.
10. No service is attached to a cross-client shared Docker network.
11. Default host binding is localhost-only for multi-client safety.

## Open Decisions

These should be resolved with the Security service owner:

1. Final Security service internal port. This draft proposes `8400`.
2. Exact Security auth endpoint path. This draft uses `/auth`.
3. Exact login and logout paths. This draft uses `/login`, `/auth/callback`, and
   either `/logout` or `/auth/logout`.
4. Internal JWT signing and validation model.
5. Whether Query Engine validates JWTs locally through JWKS or calls Security on
   every policy check.
6. Exact role/scopes header format if Nginx forwards denormalized identity
   headers.
7. Whether shared host ingress terminates TLS before the client Nginx or proxies
   TLS through to it. This repo should still support listening on container
   port `443`.
