# Indaga Connector Setup

This repository contains deployment assets for two component stacks used in the Indaga ecosystem.

## Repository Contents

- `edc-connector/`: Template-based setup for EDC participant connector instances.
- `indaga-dataspace-connector/`: INDAGA Dataspace Connector core deployment files.

## Prerequisites

- Linux host with `docker` (with `docker compose`), `jq`, `curl`, `base64`
- Access to `registry.itg.es` (Docker registry credentials)
- Permissions to create and manage files under `/opt` on the target host

## Quick Start

1. Download the repo with `curl -L https://github.com/datosindaga/indaga-connector-setup/archive/refs/heads/main.zip -o deploy.tar.gz`
2. Unzip the content `tar -zxvf deploy.tar.gz && mv indaga-connector-setup-main*/ /opt/.indaga-deploy/`
3. `rm -rf deploy.tar.gz`
4. Choose the stack you want to deploy:
   - EDC participant connector: see [`edc-connector/README.md`](edc-connector/README.md), located in `/opt/.indaga-deploy/edc-connector/README.md`
   - Indaga core connector stack: see [`indaga-dataspace-connector/README.md`](indaga-dataspace-connector/README.md) located in `/opt/.indaga-deploy/indaga-dataspace-connector/README.md`
5. Follow the folder-specific setup steps and configuration notes.
6. Validate services with Docker (`docker compose ps`, container logs, and exposed ports).

## Notes

- The `edc-connector` flow is oriented to per-participant isolated instances.
- The `indaga-dataspace-connector` flow is oriented to core platform service deployment or per-participant isolated instances.
- Keep secrets and generated credentials out of version control.
