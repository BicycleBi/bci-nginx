FROM nginx:1.25-alpine

LABEL maintainer="Bicycle Cloud Intelligence <dev@bicyclecloud.com>"
LABEL description="Client Nginx web entrypoint for Bicycle Cloud Intelligence"

ENV SECURITY_UPSTREAM_HOST=security \
    SECURITY_UPSTREAM_PORT=8400 \
    QUERY_ENGINE_UPSTREAM_HOST=query-engine \
    QUERY_ENGINE_UPSTREAM_PORT=8300

COPY templates/default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --spider -q --no-check-certificate https://localhost/healthz || exit 1
