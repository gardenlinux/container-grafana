#!/usr/bin/env bash
# Test that all default preinstall plugins are loaded in a running Grafana container.
# Compares against the 19 plugins that Grafana 13.x installs by default
# (pkg/setting/setting_plugins.go: defaultPreinstallPlugins).
#
# Usage: test-grafana-plugins.sh <image>
# Example: test-grafana-plugins.sh gl-fips-grafana:13.2.3-amd64
set -euo pipefail

IMAGE="${1:?Usage: $0 <image>}"
CONTAINER="grafana-plugin-test-$$"
PORT=3100
TIMEOUT=120

EXPECTED_PLUGINS=(
    elasticsearch
    grafana-advisor-app
    grafana-exploretraces-app
    grafana-lokiexplore-app
    grafana-metricsdrilldown-app
    grafana-postgresql-datasource
    grafana-pyroscope-app
    grafana-pyroscope-datasource
    influxdb
    jaeger
    loki
    mssql
    mysql
    opentsdb
    prometheus
    stackdriver
    tempo
    zipkin
)

cleanup() {
    docker rm -f "$CONTAINER" &>/dev/null || true
}
trap cleanup EXIT

echo "--- Starting container $CONTAINER from $IMAGE"
docker run -d \
    --name "$CONTAINER" \
    -p "${PORT}:3000" \
    -e GF_LOG_LEVEL=warn \
    "$IMAGE"

echo "--- Waiting for Grafana to become ready (up to ${TIMEOUT}s)"
ELAPSED=0
until curl -sf "http://localhost:${PORT}/api/health" | grep -q '"database": "ok"'; do
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "FAIL: Grafana did not become ready within ${TIMEOUT}s"
        echo "--- Container logs:"
        docker logs "$CONTAINER"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo "    Ready after ${ELAPSED}s"

echo "--- Querying installed plugins"
PLUGIN_JSON=$(curl -sf \
    -u "admin:admin" \
    "http://localhost:${PORT}/api/plugins?embedded=0&enabled=true") || {
    echo "FAIL: could not query /api/plugins"
    docker logs "$CONTAINER"
    exit 1
}

echo "--- All plugins reported by Grafana:"
echo "$PLUGIN_JSON" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//' | sort | sed 's/^/    /'

echo ""
echo "--- Checking expected plugins"
PASS=true
for plugin in "${EXPECTED_PLUGINS[@]}"; do
    if echo "$PLUGIN_JSON" | grep -q "\"id\":\"${plugin}\""; then
        echo "    OK       $plugin"
    else
        echo "    MISSING  $plugin"
        PASS=false
    fi
done

echo ""
if [ "$PASS" = "true" ]; then
    echo "PASS: all ${#EXPECTED_PLUGINS[@]} expected plugins are loaded"
else
    echo "FAIL: one or more expected plugins are missing"
    exit 1
fi
