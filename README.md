# BCI Nginx

BCI Nginx is the Podman-managed Nginx deployment host for the Bicycle Cloud Intelligence orchestration layer. It is the public entry point for web traffic and uses Nginx `auth_request` to authorize requests through the Security Module before proxying them to the Query Engine.

## Responsibilities

- Expose the single external HTTP port for the stack
- Send every protected request to the Security Module as an auth subrequest
- Proxy authorized requests to the Query Engine with identity headers attached
- Forward login and auth callback routes to the Security Module
- Keep Query Engine, Security, Mail Service, Postgres, Redis, and Credential Helper on an internal Podman network
- Provide an unauthenticated `/healthz` endpoint for container health checks

## Requirements

- Podman
- Podman Compose
- A shared Podman network named `bci-net`

On Windows, start the Podman machine first:

```sh
podman machine init
podman machine start
```

Create the shared network once:

```sh
podman network create bci-net
```

## Build

```sh
podman build -f Containerfile -t bci-nginx:latest .
```

## Run With Podman

```sh
podman run -d --name bci-nginx --network bci-net -p 80:80 bci-nginx:latest
```

## Run With Podman Compose

```sh
podman compose -f podman-compose.yml up -d --build
```

The upstream services must be reachable on the same Podman network using these names:

- `security:8081`
- `query-engine:8080`

## Files

- `Containerfile`: container build instructions
- `nginx.conf`: Nginx reverse proxy and `auth_request` configuration
- `podman-compose.yml`: Podman Compose definition for the Nginx container

