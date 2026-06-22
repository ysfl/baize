FROM alpine:3.20

ARG TARGETARCH
ARG SOURCE_URL=https://github.com/ysfl/baize
ARG VERSION=unknown
ARG REVISION=unknown

LABEL org.opencontainers.image.source="${SOURCE_URL}" \
  org.opencontainers.image.version="${VERSION}" \
  org.opencontainers.image.revision="${REVISION}" \
  org.opencontainers.image.description="Baize Control Service"

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY server/dist/ /app/server/dist/
COPY agent/dist/ /app/agent/dist/
COPY releases/ /app/releases/

RUN server_arch="${TARGETARCH:-amd64}" \
  && server_binary="/app/server/dist/baize-server-linux-${server_arch}" \
  && test -f "$server_binary" \
  && test -f /app/agent/dist/install.sh \
  && test -f /app/agent/dist/install.ps1 \
  && test -f /app/agent/dist/baize-agent.service \
  && cp "$server_binary" /app/baize-server \
  && chmod +x /app/baize-server /app/agent/dist/install.sh

EXPOSE 8080

CMD ["/app/baize-server"]
