FROM nginx:1.27-alpine

ARG SOURCE_URL=https://github.com/ysfl/baize
ARG VERSION=unknown
ARG REVISION=unknown

LABEL org.opencontainers.image.source="${SOURCE_URL}" \
  org.opencontainers.image.version="${VERSION}" \
  org.opencontainers.image.revision="${REVISION}" \
  org.opencontainers.image.description="Baize Web"

COPY web/dist/ /usr/share/nginx/html/
COPY web/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY web/docker-entrypoint.d/19-baize-web-host-guard.envsh /docker-entrypoint.d/19-baize-web-host-guard.envsh
COPY web/docker-entrypoint.d/20-baize-api-config.sh /docker-entrypoint.d/20-baize-api-config.sh

RUN test -f /usr/share/nginx/html/index.html \
  && chmod +x /docker-entrypoint.d/19-baize-web-host-guard.envsh \
  && chmod +x /docker-entrypoint.d/20-baize-api-config.sh

EXPOSE 8080
