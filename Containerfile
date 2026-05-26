# Nginx Web Host Containerfile for Bicycle Cloud Intelligence
# Uses official Nginx image as base

FROM nginx:1.25-alpine

# Set maintainer label
LABEL maintainer="Bicycle Cloud Intelligence <dev@bicyclecloud.com>"
LABEL description="Nginx Web Host for BCI Orchestration Layer"

# Copy custom nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# (Optional) Copy static web content if needed
# COPY html/ /usr/share/nginx/html/

# Expose the single external HTTP port handled by the deployment host.
EXPOSE 80

# Healthcheck validates the Nginx process via an unauthenticated local endpoint.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --spider -q http://localhost/healthz || exit 1

# Use default Nginx entrypoint and command
