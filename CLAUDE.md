# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**OTEL-LGTM-Skills** is an observability development environment built on the `grafana/otel-lgtm` Docker image. It provides an all-in-one OpenTelemetry backend for development, demo, and testing environments, bundling:
- **OpenTelemetry Collector** - receives OTLP data on ports 4317 (gRPC) and 4318 (HTTP)
- **Prometheus** - metrics storage (port 9090)
- **Tempo** - distributed tracing (port 3200)
- **Loki** - log aggregation (port 3100)
- **Pyroscope** - continuous profiling (port 4040)
- **Grafana** - visualization (port 3000, default login: admin/admin)

## Common Commands

### Run the LGTM Stack

```sh
# Using Docker directly (creates container/ dir for persistence)
./run-lgtm.sh

# Using mise (task runner)
mise run lgtm

# Using docker-compose (mounts configs for easy iteration)
docker-compose up -d
docker-compose restart   # Reload config changes
docker-compose logs -f   # Follow logs
```

### Build the Docker Image

```sh
cd docker/ && docker build . -t grafana/otel-lgtm

# Or with mise
mise run build-lgtm

# Run locally-built image
./run-lgtm.sh latest true
```

### Run Example Apps

```sh
# Java example (default)
./run-example.sh
mise run example

# Other languages
mise run example-nodejs
mise run example-python
mise run example-go
mise run example-dotnet

# Generate traffic to example apps
./generate-traffic.sh
```

### Linting

```sh
mise run lint           # Super linter
mise run lint-markdown  # Markdown only
mise run lint-links     # Link checking with lychee
```

### Kubernetes Deployment

```sh
kubectl apply -f k8s/lgtm.yaml
kubectl port-forward service/lgtm 3000:3000 4040:4040 4317:4317 4318:4318 9090:9090
```

## Architecture

### Docker Image Build (`docker/`)

The multi-stage Dockerfile downloads and bundles all observability components. Key files:
- `docker/Dockerfile` - Multi-stage build with version pinning via Renovate annotations
- `docker/download-*.sh` - Component download scripts with cosign signature verification
- `docker/run-*.sh` - Startup scripts for each component
- `docker/run-all.sh` - Main entrypoint that starts all services

### Configuration Files (`docker/`)

- `otelcol-config.yaml` - OpenTelemetry Collector pipelines (receivers, processors, exporters)
- `prometheus.yaml` - Prometheus scrape configs
- `tempo-config.yaml` - Tempo trace storage
- `loki-config.yaml` - Loki log storage
- `pyroscope-config.yaml` - Pyroscope profiling
- `grafana-datasources.yaml` - Pre-configured datasources with cross-linking (traces to logs, metrics to traces)
- `grafana-dashboards.yaml` - Dashboard provisioning

### Custom Dashboards

- `dashboards/` - Custom Grafana dashboards (mounted via docker-compose)
- `docker/grafana-dashboard-*.json` - Built-in dashboards included in the image

### Examples (`examples/`)

Language-specific OpenTelemetry instrumentation examples (Java, Go, Python, .NET, Node.js). Each implements a `/rolldice` endpoint. Examples include `oats.yaml` files for acceptance testing with the Grafana OATS framework.

## Configuration via Environment

Logging can be enabled via `.env` file:
- `ENABLE_LOGS_GRAFANA`, `ENABLE_LOGS_LOKI`, `ENABLE_LOGS_PROMETHEUS`, `ENABLE_LOGS_TEMPO`, `ENABLE_LOGS_PYROSCOPE`, `ENABLE_LOGS_OTELCOL`, `ENABLE_LOGS_ALL`

External forwarding:
- `OTEL_EXPORTER_OTLP_ENDPOINT` - Forward telemetry to external backends
- `OTEL_EXPORTER_OTLP_HEADERS` - Authentication headers for external backends

## OpenTelemetry Defaults

No client configuration needed - the image uses OpenTelemetry's defaults:
```sh
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
```
