#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/grafana/grafana}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-.build/grafana-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-grafana}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-13.2.4}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-af4a33e3786594ad72f72d97e6744010330c2977}"
GO_IMAGE="${GO_IMAGE:-golang:1.26.9-alpine}"
# Space-separated list of additional plugins to bake into the image at build time,
# e.g. GRAFANA_PLUGINS="grafana-clock-panel grafana-piechart-panel"
GRAFANA_PLUGINS="${GRAFANA_PLUGINS:-}"

# Directory containing this script — used to locate patch files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}/patches/grafana-${VERSION}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- clone -------------------------------------------------------------------

CLONE_DIR=".build/fips-port-grafana"
if [ ! -d "$CLONE_DIR" ]; then
    git clone "$REPO_URL" "$CLONE_DIR"
fi

cd "$CLONE_DIR"
git fetch --tags
git checkout "v${VERSION}"
# Reset any previously applied patches so the script is idempotent
# checkout -- resets modified tracked files; clean -f removes new untracked files added by patches
git checkout -- .
git clean -f

# --- apply FIPS source patches -----------------------------------------------
# Replace non-FIPS-approved primitives (MD5, SHA-1, AES-CFB) with FIPS-approved
# equivalents (SHA-256, AES-GCM). Patches live in patches/grafana-<VERSION>/.

for patch in "${PATCHES_DIR}"/*.patch; do
    echo "Applying patch: $(basename "$patch")"
    git apply "$patch"
done

# --- generate Dockerfile.fips -------------------------------------------------
# The upstream Dockerfile has no gardenlinux stage. We generate Dockerfile.fips by:
# 1. Taking the main Dockerfile as base
# 2. Fixing the go-builder FROM for cross-compilation (--platform=$BUILDPLATFORM)
# 3. Appending a final-gardenlinux stage that copies assets from the multi-stage
#    build and runs Grafana on a FIPS-enabled Debian (gardenlinux) base.

mkdir -p "${WORKDIR}"
cp Dockerfile "${WORKDIR}/Dockerfile.fips"

# Add --platform=$BUILDPLATFORM to the Go builder FROM for cross-compilation
sed -i 's|^FROM \${GO_IMAGE} AS go-builder$|FROM --platform=\$BUILDPLATFORM \${GO_IMAGE} AS go-builder|' \
    "${WORKDIR}/Dockerfile.fips"

# Append the GardenLinux FIPS final stage
cat >> "${WORKDIR}/Dockerfile.fips" <<'GARDENLINUX_STAGE'

# GardenLinux FIPS final stage — use --target=final-gardenlinux to select.
# Debian-based (gardenlinux), FIPS-enabled OpenSSL via GODEBUG=fips140=only.
FROM ghcr.io/gardenlinux/gardenlinux/fips:1877.22 AS final-gardenlinux
ARG UPSTREAM_GIT_SHA

LABEL maintainer="Grafana Labs <hello@grafana.com>"
LABEL org.opencontainers.image.source="https://github.com/grafana/grafana"
LABEL org.opencontainers.image.description="A FIPS-enabled Grafana image"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.revision="${UPSTREAM_GIT_SHA}"

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
  apt-get install -y ca-certificates tzdata && \
  apt-get autoremove -y && \
  rm -rf /var/lib/apt/lists/*

COPY --from=go-src /tmp/grafana/conf ./conf

RUN if [ ! "$(getent group "$GF_GID")" ]; then \
  groupadd --system --gid $GF_GID grafana; \
  fi && \
  GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
  mkdir -p "$GF_PATHS_HOME/.aws" && \
  useradd --system --uid $GF_UID --gid "$GF_GID_NAME" -s /sbin/nologin grafana && \
  mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
  "$GF_PATHS_PROVISIONING/dashboards" \
  "$GF_PATHS_PROVISIONING/notifiers" \
  "$GF_PATHS_PROVISIONING/plugins" \
  "$GF_PATHS_PROVISIONING/access-control" \
  "$GF_PATHS_PROVISIONING/alerting" \
  "$GF_PATHS_LOGS" \
  "$GF_PATHS_PLUGINS" \
  "$GF_PATHS_HOME/data/plugins-bundled" \
  "$GF_PATHS_DATA" && \
  cp conf/sample.ini "$GF_PATHS_CONFIG" && \
  cp conf/ldap.toml /etc/grafana/ldap.toml && \
  chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled" && \
  chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled"

COPY --link --from=grafana-assets /usr/share/grafana /usr/share/grafana
COPY --link --from=grafana-plugins /usr/share/grafana/data /usr/share/grafana/data

# Install bundled plugins and any operator-specified additional plugins at build time
# (before GODEBUG=fips140=only is set), so OpenPGP signature verification runs without
# FIPS restrictions. The runtime background installer is disabled via
# GF_PLUGINS_PREINSTALL_DISABLED so no plugin download happens under fips140=only.
ARG GRAFANA_PLUGINS=""
RUN for plugin in \
      elasticsearch \
      grafana-advisor-app \
      grafana-exploretraces-app \
      grafana-lokiexplore-app \
      grafana-metricsdrilldown-app \
      grafana-postgresql-datasource \
      grafana-pyroscope-app \
      grafana-pyroscope-datasource \
      influxdb \
      jaeger \
      loki \
      mssql \
      mysql \
      opentsdb \
      prometheus \
      stackdriver \
      tempo \
      zipkin \
      $GRAFANA_PLUGINS; do \
    grafana cli --pluginsDir "$GF_PATHS_PLUGINS" plugins install "$plugin"; \
  done

RUN grafana server -v | sed -e 's/Version //' > /.grafana-version
RUN chmod 644 /.grafana-version

# Set FIPS enforcement after all build-time plugin installation is complete.
# GF_PLUGINS_PREINSTALL_DISABLED suppresses the background installer at runtime —
# bundled plugins are already present from the grafana-plugins build stage.
ENV GODEBUG=fips140=only \
  GF_PLUGINS_PREINSTALL_DISABLED=true

EXPOSE 3000

COPY packaging/docker/run.sh /run.sh

USER "$GF_UID"
ENTRYPOINT [ "/run.sh" ]
GARDENLINUX_STAGE

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg ARCH="${ARCH}" \
    --build-arg GO_IMAGE="${GO_IMAGE}" \
    --build-arg JS_PLATFORM="$(uname -m | sed 's/x86_64/linux\/amd64/;s/aarch64/linux\/arm64/')" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --build-arg SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" \
    --build-arg GRAFANA_PLUGINS="${GRAFANA_PLUGINS}" \
    --target=final-gardenlinux \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    -f "${WORKDIR}/Dockerfile.fips" \
    .

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"
