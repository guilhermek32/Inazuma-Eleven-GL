# Pinned Godot toolchain and the Godot-based service images, all from one file
# so every image is built by the same verified engine. Build context: repo root.
#
#   docker build -f tools/godot/Dockerfile --target godot -t inazuma/godot:4.7.2 .
#   docker build -f tools/godot/Dockerfile --target godot-export -t inazuma/godot-export:4.7.2 .
#   docker build -f tools/godot/Dockerfile --target match-runtime .   (or: docker compose build)
#   docker build -f tools/godot/Dockerfile --target gateway .
#
# Both binaries are the official godotengine/godot release, verified against the
# release's SHA512-SUMS.txt. Bump GODOT_VERSION and both hashes together, and
# keep config/features in project.godot on the same minor version.

ARG GODOT_VERSION=4.7.2
ARG GODOT_SHA512=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
ARG TEMPLATES_SHA512=ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079

FROM debian:bookworm-slim AS godot
ARG GODOT_VERSION
ARG GODOT_SHA512
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/godot.zip \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
 && echo "${GODOT_SHA512}  /tmp/godot.zip" | sha512sum -c - \
 && unzip -q /tmp/godot.zip -d /opt/godot \
 && ln -s "/opt/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot \
 && rm /tmp/godot.zip
WORKDIR /project
ENTRYPOINT ["godot"]

# Adds only the export templates this project uses (web + linux), not the whole archive.
FROM godot AS godot-export
ARG GODOT_VERSION
ARG TEMPLATES_SHA512
RUN curl -fsSL -o /tmp/templates.tpz \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" \
 && echo "${TEMPLATES_SHA512}  /tmp/templates.tpz" | sha512sum -c - \
 && dest="/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable" \
 && mkdir -p "$dest" \
 && unzip -q -j /tmp/templates.tpz 'templates/version.txt' 'templates/web_*' 'templates/linux_*x86_64' -d "$dest" \
 && rm /tmp/templates.tpz \
 && ls "$dest"

# The project, imported once; both exports start from here.
FROM godot-export AS project
COPY . /project
RUN mkdir -p /project/build && touch /project/build/.gdignore \
 && godot --headless --import --path /project

FROM project AS export-web
RUN mkdir -p build/web \
 && godot --headless --path /project --export-release "Web" build/web/index.html \
 && test -s build/web/index.wasm

FROM project AS export-server
RUN mkdir -p build/server \
 && godot --headless --path /project --export-release "Linux Server" build/server/inazuma_server.x86_64 \
 && test -x build/server/inazuma_server.x86_64

# Headless match runtime (also hosts the AI bot entry point, selected by --bot).
FROM debian:bookworm-slim AS match-runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home app \
 && mkdir -p /data && chown app /data
COPY --from=export-server /project/build/server /app
USER app
WORKDIR /app
ENV MATCH_RUNTIME_PORT=8910
EXPOSE 8910
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD bash -c '</dev/tcp/127.0.0.1/8910' || exit 1
ENTRYPOINT ["/app/inazuma_server.x86_64", "--headless"]

# Public entry point: TLS, the web client and the reverse proxy to the services.
FROM caddy:2.10-alpine AS gateway
COPY services/gateway/Caddyfile /etc/caddy/Caddyfile
COPY --from=export-web /project/build/web /srv/web

# Development runtime: the debug editor binary serving the imported project,
# so DEV_NO_AUTH=1 "dev:<team>" tokens work (see docker-compose.dev.yml).
# Never used by the production compose file.
FROM project AS match-runtime-dev
ENV MATCH_RUNTIME_PORT=8910
EXPOSE 8910
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
  CMD bash -c '</dev/tcp/127.0.0.1/8910' || exit 1
ENTRYPOINT ["godot", "--headless", "--path", "/project", "--", "--server"]
