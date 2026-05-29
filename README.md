# BCI Nginx

BCI Nginx is the client-stack web entrypoint for Bicycle Cloud Intelligence. It
terminates HTTPS for one client stack, authorizes protected requests with the
client Security service through Nginx `auth_request`, and proxies authorized
traffic to the client Query Engine with the identity headers returned by
Security.

This is not the shared host ingress. On a shared host, the host-level ingress
routes public client hostnames to each client's local BCI Nginx entrypoint.

## Responsibilities

- Listen on container port `443` with TLS.
- Provide unauthenticated `GET /healthz` for container health checks.
- Proxy Security-owned browser auth routes directly to Security.
- Authorize all other routes through `auth_request`.
- Forward the internal BCI JWT and identity context from Security to Query
  Engine.
- Keep Query Engine, Security, Postgres, email-service, and credential-helper on
  the client stack's internal Docker network.

## Runtime Contract

Default upstreams:

```text
SECURITY_UPSTREAM_HOST=security
SECURITY_UPSTREAM_PORT=8400
QUERY_ENGINE_UPSTREAM_HOST=query-engine
QUERY_ENGINE_UPSTREAM_PORT=8300
```

TLS material must be mounted read-only:

```text
/etc/nginx/tls/tls.crt
/etc/nginx/tls/tls.key
```

Only `/healthz` is unauthenticated. These Security routes bypass `auth_request`:

```text
/login
/auth/callback
/logout
/auth/logout
```

All other routes are protected. A protected request first calls Security at
`/auth`. On success, Security must return an internal BCI JWT in `Authorization`
and the identity headers that Query Engine expects.

## Configuration

The Docker image uses the official Nginx runtime template mechanism. The
template lives at `templates/default.conf.template` and is rendered when the
container starts.

Supported environment variables:

```text
CLIENT_WEB_BIND=127.0.0.1:18443
CLIENT_TLS_CERT_PATH=./dev/tls/tls.crt
CLIENT_TLS_KEY_PATH=./dev/tls/tls.key
SECURITY_UPSTREAM_HOST=security
SECURITY_UPSTREAM_PORT=8400
QUERY_ENGINE_UPSTREAM_HOST=query-engine
QUERY_ENGINE_UPSTREAM_PORT=8300
```

`CLIENT_WEB_BIND` is used by Docker Compose for the host binding. On shared
multi-client hosts, keep it localhost-only, for example `127.0.0.1:18443`. A
single-client deployment may override it to `0.0.0.0:443`.

## Build

```sh
docker build -t bci-nginx:latest .
```

## Run With Docker Compose

For local development, create a self-signed certificate if you do not already
have client TLS material:

```sh
mkdir -p dev/tls
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout dev/tls/tls.key \
  -out dev/tls/tls.crt \
  -subj "/CN=localhost"
```

Then run:

```sh
docker compose up -d --build
```

The compose file binds HTTPS to `127.0.0.1:18443` by default:

```sh
curl -k https://127.0.0.1:18443/healthz
```

For generated client stacks, `bci-container-orch` should mount real certificate
files, attach this service to the stack's internal Docker network, and provide
the Security and Query Engine services under the configured upstream names.

## Podman Smoke Test

See [docs/podman-smoke-test.md](docs/podman-smoke-test.md) for the local Podman
test that runs this image with mock Security and Query Engine containers.

## Files

- `Dockerfile`: image build instructions.
- `templates/default.conf.template`: Nginx HTTPS, auth, and proxy template.
- `docker-compose.yml`: local/client-stack service example.
- `.env.example`: supported runtime variables.
