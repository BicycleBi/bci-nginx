# Podman Smoke Test

This document records the local Podman test used to validate the BCI Nginx
container before wiring it into the generated client stack.

The test runs three containers on one temporary Podman network:

- `bci-nginx-test`: the actual `bci-nginx:latest` image built from this repo.
- `bci-security-mock`: a disposable Nginx container that responds to `/auth`
  like the planned Security service.
- `bci-query-engine-mock`: a disposable Nginx container that echoes the identity
  headers it receives from BCI Nginx.

The mock upstream containers use `docker.io/library/nginx:1.25-alpine` directly.
That image is also the base image for `bci-nginx`, so Podman may show both images
with the same size.

## 1. Build BCI Nginx

Create local TLS material for the HTTPS listener:

```sh
mkdir -p dev/tls
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout dev/tls/tls.key \
  -out dev/tls/tls.crt \
  -subj "/CN=localhost"
```

Build the image:

```sh
podman build -t bci-nginx:latest .
```

Expected result:

```text
localhost/bci-nginx:latest
```

Podman may warn that image-level `HEALTHCHECK` is ignored for its default OCI
image format. That does not block this smoke test.

## 2. Create Mock Upstream Configs

Create a temporary directory for mock Nginx configs:

```sh
mkdir -p /private/tmp/bci-nginx-test
```

Create `/private/tmp/bci-nginx-test/security.conf`:

```nginx
server {
    listen 8400;

    location = /auth {
        add_header Authorization "Bearer test-internal-token" always;
        add_header X-Identity-User-Id "user-123" always;
        add_header X-Identity-Email "user@example.test" always;
        add_header X-Identity-Name "Test User" always;
        add_header X-Identity-Roles "viewer" always;
        add_header X-Identity-Client-Key "test-client" always;
        return 204;
    }

    location / {
        default_type text/plain;
        return 200 "security ok\n";
    }
}
```

Create `/private/tmp/bci-nginx-test/query.conf`:

```nginx
server {
    listen 8300;

    location / {
        default_type text/plain;
        return 200 "query ok\nAuthorization: $http_authorization\nUser: $http_x_identity_user_id\nEmail: $http_x_identity_email\nClient: $http_x_identity_client_key\n";
    }
}
```

## 3. Start The Test Network And Containers

Create the temporary Podman network:

```sh
podman network create bci-nginx-test-net
```

Start the mock Security service:

```sh
podman run -d \
  --name bci-security-mock \
  --network bci-nginx-test-net \
  --network-alias security \
  -v /private/tmp/bci-nginx-test/security.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:1.25-alpine
```

Start the mock Query Engine:

```sh
podman run -d \
  --name bci-query-engine-mock \
  --network bci-nginx-test-net \
  --network-alias query-engine \
  -v /private/tmp/bci-nginx-test/query.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:1.25-alpine
```

Start BCI Nginx with its default upstream names:

```sh
podman run -d \
  --name bci-nginx-test \
  --network bci-nginx-test-net \
  -p 127.0.0.1:18443:443 \
  -v "$PWD/dev/tls/tls.crt:/etc/nginx/tls/tls.crt:ro" \
  -v "$PWD/dev/tls/tls.key:/etc/nginx/tls/tls.key:ro" \
  bci-nginx:latest
```

## 4. Validate

Check the public unauthenticated health endpoint:

```sh
curl -k -i https://127.0.0.1:18443/healthz
```

Expected result:

```text
HTTP/1.1 200 OK

ok
```

Check a protected route through the `auth_request` flow:

```sh
curl -k -i https://127.0.0.1:18443/artifacts/test-client/test-artifact
```

Expected body:

```text
query ok
Authorization: Bearer test-internal-token
User: user-123
Email: user@example.test
Client: test-client
```

Check running containers:

```sh
podman ps --filter network=bci-nginx-test-net \
  --format '{{.Names}} {{.Status}} {{.Ports}}'
```

Expected containers:

```text
bci-security-mock
bci-query-engine-mock
bci-nginx-test
```

## Cleanup

```sh
podman rm -f bci-nginx-test bci-security-mock bci-query-engine-mock
podman network rm bci-nginx-test-net
```

The generated local TLS files are ignored by git via `dev/tls/`.
