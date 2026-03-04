#!/usr/bin/env bash

# EDC participant local operations script.
# This script owns the full lifecycle for a single participant folder:
# validate, generate runtime artifacts, start/stop infrastructure, and register.
# Run it from the participant directory:
#   bash ./setup.sh help

set -euo pipefail

ACTION="${1:-help}"
LOG_SERVICE="${2:-}"
ARG1="${2:-}"
ARG2="${3:-}"
ARG3="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARTICIPANT_DIR="${SCRIPT_DIR}"
BASE_DIR="${SCRIPT_DIR}"

PARTICIPANT_CONF_FILE="${PARTICIPANT_DIR}/participant.env"
PARTICIPANT_PASS_FILE="${PARTICIPANT_DIR}/config/.pass"
RENDERED_ENV_DIR="${PARTICIPANT_DIR}/env/rendered"
NGINX_DIR="${PARTICIPANT_DIR}/nginx"
NGINX_TEMPLATE_FILE="${NGINX_DIR}/default.conf.template"
NGINX_HTTP_ONLY_TEMPLATE_FILE="${NGINX_DIR}/default.http.conf.template"
NGINX_RENDERED_FILE="${NGINX_DIR}/rendered/default.conf"
NGINX_CERTS_DIR="${NGINX_DIR}/certs"
NGINX_CERT_FILE="${NGINX_CERTS_DIR}/tls.crt"
NGINX_KEY_FILE="${NGINX_CERTS_DIR}/tls.key"
NGINX_CABUNDLE_FILE="${NGINX_CERTS_DIR}/ca-bundle.crt"
RENDERED_DIR="${BASE_DIR}/env/rendered"

# Print an error message and terminate the script with a non-zero exit code.
die() {
  echo "ERROR: $*"
  exit 1
}

# Print a warning message without stopping execution.
warn() {
  echo "WARN: $*"
}

# Show CLI usage, available commands, and quick examples.
print_help() {
  cat <<'EOF'
Usage:
  bash ./setup.sh <command> [args]

Commands:
  help                    Show this help
  validate                Validate prerequisites and configuration
  envs                    Re-render cp/dp/ih from existing secrets (requires first up)
  proxy                   Re-render nginx config from nginx/default.conf.template (requires first up)
  render                  Run envs + proxy
  runtime                 Render runtime files and nginx config
  clean                   Remove rendered folders (env + nginx)
  register                Register this participant in Identity Hub
  up                      Full deployment (vault + runtime + db + connector + register)
  reload                  Run render + compose up -d for cp/dp/ih/nginx
  debug-open <svc> <target_port> [host_port]
                          Open socat tunnel from host to an internal service port
  debug-close [name|all]  Close one debug tunnel or all tunnels for this participant
  debug-list              List active debug tunnels for this participant
  down                    Stop connector and vault stacks and remove volumes
  status                  Show compose status for vault and connector
  logs [SERVICE]          Show logs (connector or vault services)

Examples:
  bash ./setup.sh validate
  bash ./setup.sh clean
  bash ./setup.sh up
  bash ./setup.sh envs
  bash ./setup.sh proxy
  bash ./setup.sh render
  bash ./setup.sh reload
  bash ./setup.sh logs controlplane
  bash ./setup.sh debug-open controlplane 7060 17060
  bash ./setup.sh debug-list
  bash ./setup.sh debug-close all

Notes:
  - participant.env must exist before running commands.
  - If BASE_URL is an IPv4 address and TLS files are missing, runtime/proxy
    auto-generate self-signed TLS material under nginx/certs.
EOF
}

# Normalize a URL/path-like value to an absolute path without trailing slash (except "/").
normalize_path() {
  local input="${1:-/}"
  local normalized="${input}"

  [[ -n "${normalized}" ]] || normalized="/"
  [[ "${normalized}" == /* ]] || normalized="/${normalized}"
  normalized="${normalized%/}"
  [[ -n "${normalized}" ]] || normalized="/"
  printf '%s' "${normalized}"
}

# Return success when input is a valid IPv4 address.
is_ipv4_address() {
  local input="$1"
  local IFS='.'
  local -a octets
  local octet

  [[ "${input}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "${input}"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

# Ensure required local folders exist and participant.env is present.
ensure_conf_file() {
  mkdir -p "${PARTICIPANT_DIR}/config" "${RENDERED_ENV_DIR}" "${NGINX_DIR}/rendered" "${NGINX_CERTS_DIR}"

  if [[ -f "${PARTICIPANT_CONF_FILE}" ]]; then
    return
  fi

  # Intentionally strict: config creation is explicit and user-owned.
  die "Missing ${PARTICIPANT_CONF_FILE}. Create it manually (for example: cp participant.env.example participant.env)."
}

# Load participant configuration and apply safe defaults for optional values.
load_conf() {
  ensure_conf_file

  source "${PARTICIPANT_CONF_FILE}"

  PARTICIPANT="${PARTICIPANT:-$(basename "${PARTICIPANT_DIR}")}"
  PARTICIPANT="$(printf '%s' "${PARTICIPANT}" | tr '[:upper:]' '[:lower:]')"
  BASE_URL="${BASE_URL:-examplesub.domain.com}"
  POSTGRES_USER="${PARTICIPANT}"
  POSTGRES_PASSWORD=""
  NGINX_HTTP_HOST_PORT="${NGINX_HTTP_HOST_PORT:-}"
  NGINX_HTTPS_HOST_PORT="${NGINX_HTTPS_HOST_PORT:-}"
  TRUSTED_ISSUER_DID="${TRUSTED_ISSUER_DID:-did:web:cloud.datosindaga.com:issuer}"
  IDENTITY_REGISTER_URL="${IDENTITY_REGISTER_URL:-}"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"
  IDENTITY_HUB_IMAGE="${IDENTITY_HUB_IMAGE:-registry.itg.es/flythings-stack/flythings-dataspace/api-flythings-dataspace/identity-hub:latest}"
  CONTROLPLANE_IMAGE="${CONTROLPLANE_IMAGE:-registry.itg.es/flythings-stack/flythings-dataspace/api-flythings-dataspace/controlplane:latest}"
  DATAPLANE_IMAGE="${DATAPLANE_IMAGE:-registry.itg.es/flythings-stack/flythings-dataspace/api-flythings-dataspace/dataplane:latest}"
  NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.29}"
  VAULT_IMAGE="${VAULT_IMAGE:-hashicorp/vault:1.20}"
}

# Compute and normalize derived values from participant.env.
generate_derived_env() {
  load_conf
  [[ "${PARTICIPANT}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "PARTICIPANT must contain only lowercase letters, numbers, and dashes."

  local cp_path ih_path dp_path
  cp_path="/cp"
  ih_path="/ih"
  dp_path="/dp"

  local nginx_http_h nginx_https_h
  if [[ -n "${NGINX_HTTP_HOST_PORT}" ]]; then
    [[ "${NGINX_HTTP_HOST_PORT}" =~ ^[0-9]+$ ]] || die "NGINX_HTTP_HOST_PORT must be numeric in participant.env"
    nginx_http_h="${NGINX_HTTP_HOST_PORT}"
  else
    nginx_http_h="9080"
  fi

  if [[ -n "${NGINX_HTTPS_HOST_PORT}" ]]; then
    [[ "${NGINX_HTTPS_HOST_PORT}" =~ ^[0-9]+$ ]] || die "NGINX_HTTPS_HOST_PORT must be numeric in participant.env"
    nginx_https_h="${NGINX_HTTPS_HOST_PORT}"
  else
    nginx_https_h="9443"
  fi

  COMPOSE_PROJECT_NAME="${PARTICIPANT}"
  PUBLIC_CP_PATH="${cp_path}"
  PUBLIC_IH_PATH="${ih_path}"
  PUBLIC_DP_PATH="${dp_path}"
  PUBLIC_CP_URL="https://${BASE_URL}/${PARTICIPANT}${cp_path}"
  PUBLIC_IH_URL="https://${BASE_URL}/${PARTICIPANT}${ih_path}"
  PUBLIC_DP_URL="https://${BASE_URL}/${PARTICIPANT}${dp_path}"
  NGINX_HTTP_HOST_PORT="${nginx_http_h}"
  NGINX_HTTPS_HOST_PORT="${nginx_https_h}"
}

# Load optional runtime secrets.
load_effective_env() {
  local include_secrets="${1:-1}"
  if [[ "${include_secrets}" == "1" && -f "${PARTICIPANT_PASS_FILE}" ]]; then
    source "${PARTICIPANT_PASS_FILE}"
    DB_PASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
  fi
}

# Verify required external commands are installed and available in PATH.
require_commands() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      warn "Missing command: ${cmd}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || die "Missing required commands."
}

# Validate Docker daemon and docker compose availability.
docker_ready() {
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable."
  docker compose version >/dev/null 2>&1 || die "docker compose is not available."
}

# Check whether configured host ports are already in use.
check_host_ports() {
  local port_vars=(
    NGINX_HTTP_HOST_PORT
    NGINX_HTTPS_HOST_PORT
  )

  if ! command -v ss >/dev/null 2>&1; then
    warn "Command 'ss' not found. Port check skipped."
    return
  fi

  local has_conflicts=0
  local var_name port
  for var_name in "${port_vars[@]}"; do
    port="${!var_name:-}"
    [[ -n "${port}" ]] || continue
    if ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q .; then
      warn "Port ${port} (${var_name}) is in use."
      has_conflicts=1
    fi
  done
  [[ "${has_conflicts}" -eq 0 ]] || warn "Busy ports detected. Ignore if this participant is already running."
}

# Generate local CA + server certificate for nginx when BASE_URL is IPv4 and TLS files are absent.
# Existing complete TLS material is never overwritten.
ensure_ip_tls_material() {
  generate_derived_env

  if ! is_ipv4_address "${BASE_URL}"; then
    return
  fi

  local ca_key_file ca_serial_file csr_file ext_file
  ca_key_file="${NGINX_CERTS_DIR}/ca.key"
  ca_serial_file="${NGINX_CERTS_DIR}/ca.srl"
  csr_file="${NGINX_CERTS_DIR}/tls.csr"
  ext_file="${NGINX_CERTS_DIR}/tls.ext"

  if [[ -f "${NGINX_CERT_FILE}" && -f "${NGINX_KEY_FILE}" && -f "${NGINX_CABUNDLE_FILE}" ]]; then
    return
  fi

  if [[ -f "${NGINX_CERT_FILE}" || -f "${NGINX_KEY_FILE}" || -f "${NGINX_CABUNDLE_FILE}" ]]; then
    warn "Incomplete TLS material detected in ${NGINX_CERTS_DIR}. Remove existing TLS files to allow auto-generation for IPv4 BASE_URL."
    return
  fi

  require_commands openssl

  mkdir -p "${NGINX_CERTS_DIR}"

  cat > "${ext_file}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
IP.1=${BASE_URL}
EOF

  openssl genrsa -out "${ca_key_file}" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "${ca_key_file}" \
    -sha256 \
    -days 3650 \
    -subj "/C=ES/ST=Madrid/L=Madrid/O=Indaga/OU=IT/CN=Indaga-CA" \
    -out "${NGINX_CABUNDLE_FILE}" >/dev/null 2>&1

  openssl genrsa -out "${NGINX_KEY_FILE}" 4096 >/dev/null 2>&1
  openssl req -new \
    -key "${NGINX_KEY_FILE}" \
    -subj "/C=ES/ST=Madrid/L=Madrid/O=Indaga/OU=Platform/CN=${BASE_URL}" \
    -out "${csr_file}" >/dev/null 2>&1

  openssl x509 -req \
    -in "${csr_file}" \
    -CA "${NGINX_CABUNDLE_FILE}" \
    -CAkey "${ca_key_file}" \
    -CAcreateserial \
    -CAserial "${ca_serial_file}" \
    -out "${NGINX_CERT_FILE}" \
    -days 825 \
    -sha256 \
    -extfile "${ext_file}" >/dev/null 2>&1

  rm -f "${csr_file}" "${ext_file}" "${ca_serial_file}"
  echo "Generated self-signed TLS certificates for IPv4 BASE_URL (${BASE_URL}) in ${NGINX_CERTS_DIR}"
}

# Wait until an HTTP endpoint becomes reachable (2xx/3xx/4xx).
wait_for_http_reachable() {
  local url="$1"
  local description="${2:-endpoint}"
  local max_retries=60
  local retry=0
  local code

  while [[ "${retry}" -lt "${max_retries}" ]]; do
    code="$(curl -k -sS -o /dev/null -w "%{http_code}" "${url}" || true)"
    if [[ "${code}" =~ ^[234][0-9][0-9]$ ]]; then
      return 0
    fi
    retry=$((retry + 1))
    sleep 2
  done
  die "Timeout waiting for ${description} at ${url}"
}

# Build a local URL for nginx endpoints.
# If TLS files are present, prefer HTTPS on BASE_URL; otherwise use HTTP on loopback.
build_local_nginx_url() {
  local path="$1"
  local scheme host port
  [[ "${path}" == /* ]] || path="/${path}"

  if [[ -f "${NGINX_CERT_FILE}" && -f "${NGINX_KEY_FILE}" && -f "${NGINX_CABUNDLE_FILE}" ]]; then
    scheme="https"
    host="${BASE_URL}"
    port="${NGINX_HTTPS_HOST_PORT}"
  else
    scheme="http"
    host="127.0.0.1"
    port="${NGINX_HTTP_HOST_PORT}"
  fi

  printf '%s://%s:%s%s' "${scheme}" "${host}" "${port}" "${path}"
}

# Wait until Identity Hub logs indicate runtime readiness.
wait_for_identity_hub_runtime_ready() {
  local max_retries=90
  local retry=0
  local container_id
  local logs_tail

  while [[ "${retry}" -lt "${max_retries}" ]]; do
    container_id="$(compose "edc.yml" ps -q identity-hub 2>/dev/null || true)"
    if [[ -z "${container_id}" ]]; then
      retry=$((retry + 1))
      sleep 2
      continue
    fi

    logs_tail="$(docker logs --tail 300 "${container_id}" 2>&1 || true)"
    if echo "${logs_tail}" | grep -Eq 'Runtime [0-9a-fA-F-]+ ready'; then
      return 0
    fi

    retry=$((retry + 1))
    sleep 2
  done

  die "Identity Hub runtime did not report ready state in logs."
}

# Ensure PostgreSQL service from edc.yml is running and healthy before DB-dependent actions.
require_postgres_running() {
  local max_retries=30
  local retry=0
  local container_id running_state health_state

  while [[ "${retry}" -lt "${max_retries}" ]]; do
    container_id="$(compose "edc.yml" ps -q postgres 2>/dev/null || true)"
    if [[ -z "${container_id}" ]]; then
      retry=$((retry + 1))
      sleep 2
      continue
    fi

    running_state="$(docker inspect -f '{{.State.Running}}' "${container_id}" 2>/dev/null || true)"
    health_state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${container_id}" 2>/dev/null || true)"

    if [[ "${running_state}" == "true" && ( "${health_state}" == "healthy" || "${health_state}" == "no-healthcheck" ) ]]; then
      return 0
    fi

    retry=$((retry + 1))
    sleep 2
  done

  die "Postgres service is not healthy."
}

# Wrapper for docker compose using this participant context and generated env values.
compose() {
  local compose_file="$1"
  # Export derived and secret variables for docker compose interpolation.
  set -a
  generate_derived_env
  load_effective_env 1
  set +a
  docker compose --project-name "${COMPOSE_PROJECT_NAME}" -f "${PARTICIPANT_DIR}/${compose_file}" "${@:2}"
}

# Wait until Vault initialization output contains a usable client token.
wait_for_vault_token() {
  local max_retries=30
  local retry=0
  while [[ ${retry} -lt ${max_retries} ]]; do
    if [[ -f "${PARTICIPANT_DIR}/config/vault-edc-token.json" ]]; then
      local token
      token="$(jq -r '.auth.client_token // empty' < "${PARTICIPANT_DIR}/config/vault-edc-token.json" || true)"
      [[ -n "${token}" ]] && return 0
    fi
    retry=$((retry + 1))
    sleep 2
  done
  die "Vault token is not available in config/vault-edc-token.json"
}

# Create participant secrets once and cache them in config/.pass.
generate_secrets_if_missing() {
  generate_derived_env
  load_effective_env 0

  local ih_suffix vault_token needs_write desired_did
  needs_write=0
  desired_did="did:web:${BASE_URL}:${PARTICIPANT}"

  if [[ -f "${PARTICIPANT_PASS_FILE}" ]]; then
    source "${PARTICIPANT_PASS_FILE}"
  fi

  vault_token="$(jq -r '.auth.client_token // empty' < "${PARTICIPANT_DIR}/config/vault-edc-token.json")"

  if [[ -z "${AUTH_KEY:-}" ]]; then
    AUTH_KEY="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    needs_write=1
  fi

  if [[ -z "${IH_API_KEY:-}" ]]; then
    ih_suffix="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    IH_API_KEY="c3VwZXItdXNlcg==.${ih_suffix}"
    needs_write=1
  fi

  if [[ -z "${VAULT_EDC_TOKEN:-}" || "${VAULT_EDC_TOKEN}" != "${vault_token}" ]]; then
    VAULT_EDC_TOKEN="${vault_token}"
    needs_write=1
  fi

  if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    POSTGRES_PASSWORD="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    needs_write=1
  fi

  if [[ -z "${DB_PASSWORD:-}" || "${DB_PASSWORD}" != "${POSTGRES_PASSWORD}" ]]; then
    DB_PASSWORD="${POSTGRES_PASSWORD}"
    needs_write=1
  fi

  if [[ -z "${DID:-}" || "${DID}" != "${desired_did}" ]]; then
    DID="${desired_did}"
    needs_write=1
  fi

  if [[ ! -f "${PARTICIPANT_PASS_FILE}" || "${needs_write}" -eq 1 ]]; then

  cat > "${PARTICIPANT_PASS_FILE}" <<EOF
export AUTH_KEY=${AUTH_KEY}
export VAULT_EDC_TOKEN=${VAULT_EDC_TOKEN}
export DID=${DID}
export IH_API_KEY=${IH_API_KEY}
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
export DB_PASSWORD=${DB_PASSWORD}
EOF
  fi

  source "${PARTICIPANT_PASS_FILE}"
}

# Render KEY=VALUE templates with shell-style variable expansion.
render_env_template() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "${dst}")"
  : > "${dst}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "${line}" >> "${dst}"
      continue
    fi
    local key="${line%%=*}"
    local raw_value="${line#*=}"
    local expanded_value placeholder var_name var_value
    expanded_value="${raw_value}"
    while [[ "${expanded_value}" =~ (\$\{[A-Za-z_][A-Za-z0-9_]*\}) ]]; do
      placeholder="${BASH_REMATCH[1]}"
      var_name="${placeholder:2:${#placeholder}-3}"
      var_value="${!var_name:-}"
      expanded_value="${expanded_value//${placeholder}/${var_value}}"
    done
    printf '%s=%s\n' "${key}" "${expanded_value}" >> "${dst}"
  done < "${src}"
}

# Render plain text templates replacing ${VAR} placeholders and unescaping \$ to $.
render_text_template() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "${dst}")"
  : > "${dst}"

  local line rendered placeholder var_name var_value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    rendered="${line}"

    while [[ "${rendered}" =~ (\$\{[A-Za-z_][A-Za-z0-9_]*\}) ]]; do
      placeholder="${BASH_REMATCH[1]}"
      var_name="${placeholder:2:${#placeholder}-3}"
      var_value="${!var_name:-}"
      rendered="${rendered//${placeholder}/${var_value}}"
    done

    # Keep literal nginx variables like $host by writing them as \$host in template.
    rendered="${rendered//\\\$/\$}"
    printf '%s\n' "${rendered}" >> "${dst}"
  done < "${src}"
}

# Render participants.json mapping the current participant id to its DID.
render_participants_json() {
  local participant did target_file temp_file
  participant="${PARTICIPANT:-}"
  did="${DID:-}"

  if [[ -z "${did}" && -f "${PARTICIPANT_PASS_FILE}" ]]; then
    source "${PARTICIPANT_PASS_FILE}"
    did="${DID:-}"
  fi

  if [[ -z "${did}" ]]; then
    did="did:web:${BASE_URL}:${participant}"
  fi

  [[ -n "${participant}" ]] || die "PARTICIPANT is empty. Cannot render participants.json"
  [[ -n "${did}" ]] || die "DID is empty. Cannot render participants.json"

  target_file="${PARTICIPANT_DIR}/config/participants.json"
  mkdir -p "$(dirname "${target_file}")"

  temp_file="$(mktemp)"
  if [[ -s "${target_file}" ]]; then
    if ! jq -c --arg participant "${participant}" --arg did "${did}" \
      '. + {($participant): $did}' "${target_file}" > "${temp_file}"; then
      jq -cn --arg participant "${participant}" --arg did "${did}" '{($participant): $did}' > "${temp_file}"
    fi
  else
    jq -cn --arg participant "${participant}" --arg did "${did}" '{($participant): $did}' > "${temp_file}"
  fi
  mv "${temp_file}" "${target_file}"
}

# Render all service-specific env files from templates into env/rendered.
render_service_env_files() {
  generate_derived_env
  set -a
  load_effective_env 1
  set +a
  render_env_template "${PARTICIPANT_DIR}/env/cp.env" "${RENDERED_ENV_DIR}/cp.env"
  render_env_template "${PARTICIPANT_DIR}/env/dp.env" "${RENDERED_ENV_DIR}/dp.env"
  render_env_template "${PARTICIPANT_DIR}/env/ih.env" "${RENDERED_ENV_DIR}/ih.env"
}

# Ensure nginx templates exist.
ensure_nginx_template() {
  mkdir -p "${NGINX_DIR}/rendered"
  [[ -f "${NGINX_TEMPLATE_FILE}" ]] || die "File nginx/default.conf.template does not exist."
  [[ -f "${NGINX_HTTP_ONLY_TEMPLATE_FILE}" ]] || die "File nginx/default.http.conf.template does not exist."
}

# Convert a full URL to a normalized path component.
url_to_path() {
  local url="${1:-/}"
  local no_scheme path
  if [[ "${url}" != *"://"* ]]; then
    normalize_path "${url}"
    return
  fi
  no_scheme="${url#*://}"
  if [[ "${no_scheme}" == */* ]]; then
    path="/${no_scheme#*/}"
  else
    path="/"
  fi
  normalize_path "${path}"
}

# Render final nginx config from template and current derived/secret values.
render_nginx_config() {
  ensure_nginx_template
  render_service_env_files
  generate_derived_env
  ensure_ip_tls_material
  set -a
  load_effective_env 1
  set +a
  source "${RENDERED_ENV_DIR}/dp.env"

  local cp_public_path ih_public_path dp_public_path dp_upstream_path
  cp_public_path="$(url_to_path "${PUBLIC_CP_URL}")"
  ih_public_path="$(url_to_path "${PUBLIC_IH_URL}")"
  dp_public_path="$(url_to_path "${EDC_DATAPLANE_API_PUBLIC_BASEURL:-${PUBLIC_DP_URL}/api/public}")"
  dp_upstream_path="$(normalize_path "${WEB_HTTP_PUBLIC_PATH:-/api/public}")"

  export NGINX_CP_PUBLIC_PATH="${cp_public_path}"
  export NGINX_IH_PUBLIC_PATH="${ih_public_path}"
  export NGINX_DP_PUBLIC_PATH="${dp_public_path}"
  export NGINX_DP_UPSTREAM_PATH="${dp_upstream_path}"

  local selected_template
  if [[ -f "${NGINX_CERT_FILE}" && -f "${NGINX_KEY_FILE}" && -f "${NGINX_CABUNDLE_FILE}" ]]; then
    selected_template="${NGINX_TEMPLATE_FILE}"
  else
    if [[ -f "${NGINX_CERT_FILE}" || -f "${NGINX_KEY_FILE}" || -f "${NGINX_CABUNDLE_FILE}" ]]; then
      warn "Incomplete TLS material. Rendering HTTP-only nginx config."
    else
      warn "TLS files not found. Rendering HTTP-only nginx config."
    fi
    selected_template="${NGINX_HTTP_ONLY_TEMPLATE_FILE}"
  fi

  render_text_template "${selected_template}" "${NGINX_RENDERED_FILE}"
}

# Run static pre-flight validation for tools, Docker, required secrets, and ports.
validate() {
  generate_derived_env
  require_commands docker jq curl base64
  if is_ipv4_address "${BASE_URL}" && [[ ! -f "${NGINX_CERT_FILE}" || ! -f "${NGINX_KEY_FILE}" || ! -f "${NGINX_CABUNDLE_FILE}" ]]; then
    require_commands openssl
  fi
  docker_ready
  load_effective_env 0
  check_host_ports
}

# Render only connector env files (cp/dp/ih) using existing secret values.
render_envs() {
  generate_derived_env
  [[ -f "${PARTICIPANT_PASS_FILE}" ]] || die "Missing config/.pass. Run 'bash ./setup.sh up' first."
  render_service_env_files
  echo "Rendered files:"
  echo "  - ${RENDERED_ENV_DIR}/cp.env"
  echo "  - ${RENDERED_ENV_DIR}/dp.env"
  echo "  - ${RENDERED_ENV_DIR}/ih.env"
}

# Run validation and enforce runtime prerequisites required by connector operations.
validate_runtime() {
  validate
  [[ -f "${PARTICIPANT_PASS_FILE}" ]] || die "Missing config/.pass. Run 'bash ./setup.sh up' first."
  require_postgres_running
}

# Start vault stack and wait for token generation.
vault_up() {
  compose "vault-edc.yml" up -d
  wait_for_vault_token
}

# Generate all runtime artifacts required before connector startup.
runtime() {
  generate_derived_env
  wait_for_vault_token
  generate_secrets_if_missing
  render_participants_json
  render_service_env_files
  render_nginx_config
}

# Ensure the participant database exists in local PostgreSQL.
db_init() {
  validate_runtime
  load_effective_env 0
  compose "edc.yml" exec -T postgres psql -U "${POSTGRES_USER}" <<EOF
SELECT 'CREATE DATABASE ${PARTICIPANT}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${PARTICIPANT}')\gexec
EOF
}

# Poll PostgreSQL readiness using pg_isready until timeout.
wait_for_postgres() {
  local max_retries=40
  local retry=0
  while [[ ${retry} -lt ${max_retries} ]]; do
    if compose "edc.yml" exec -T postgres pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; then
      return 0
    fi
    retry=$((retry + 1))
    sleep 2
  done
  die "Postgres service did not become ready."
}

# Start local PostgreSQL service and wait until it is ready.
postgres_up() {
  compose "edc.yml" up -d postgres
  wait_for_postgres
}

# Re-render nginx config without starting/stopping services.
proxy() {
  generate_derived_env
  [[ -f "${PARTICIPANT_PASS_FILE}" ]] || die "Missing config/.pass. Run 'bash ./setup.sh up' first."
  render_nginx_config
  echo "Nginx config generated at ${NGINX_RENDERED_FILE}"
}

# Render both env files and nginx config from existing secret values.
render_all() {
  render_envs
  render_nginx_config
}

# Start connector services (cp, dp, ih, nginx) after runtime artifacts are ready.
connector_up() {
  validate_runtime
  render_all
  compose "edc.yml" up -d controlplane dataplane identity-hub nginx
}

# POST JSON payload and treat HTTP 409 as acceptable for idempotent calls.
post_json_allow_conflict() {
  local url="$1"
  local payload="$2"
  local api_key="$3"
  local tmp
  local -a curl_tls_args
  tmp="$(mktemp)"

  curl_tls_args=()
  if [[ "${url}" == https://* ]]; then
    curl_tls_args+=(--insecure)
  fi

  local http_code
  http_code="$(curl -sS -o "${tmp}" -w "%{http_code}" \
    --location "${url}" \
    "${curl_tls_args[@]}" \
    --header "Content-Type: application/json" \
    --header "x-api-key: ${api_key}" \
    --data "${payload}")"

  case "${http_code}" in
    200|201|202|204|409) rm -f "${tmp}" ;;
    *)
      cat "${tmp}" || true
      rm -f "${tmp}"
      die "HTTP ${http_code} calling ${url}"
      ;;
  esac
}

# Register participant metadata in Identity Hub.
register() {
  validate_runtime
  generate_derived_env
  load_effective_env 1

  local identity_url health_url cp_url ih_url base64_did payload
  identity_url="${IDENTITY_REGISTER_URL:-$(build_local_nginx_url "/${PARTICIPANT}${PUBLIC_IH_PATH}/api/identity/v1alpha/participants/")}"
  health_url="$(build_local_nginx_url "/${PARTICIPANT}/healthz")"
  cp_url="${PUBLIC_CP_URL}"
  ih_url="${PUBLIC_IH_URL}"
  base64_did="$(printf '%s' "${DID}" | base64 | tr -d '\n')"

  wait_for_identity_hub_runtime_ready
  wait_for_http_reachable "${health_url}" "nginx health endpoint"
  wait_for_http_reachable "${identity_url}" "identity registration endpoint"

  payload="$(jq -n \
    --arg url "${cp_url}" \
    --arg ihurl "${ih_url}" \
    --arg pidcs "${PARTICIPANT}-credentialservice-1" \
    --arg pidsp "${PARTICIPANT}-dsp" \
    --arg b64did "${base64_did}" \
    --arg did "${DID}" \
    '{
      "roles": [],
      "serviceEndpoints": [
        { "type": "CredentialService", "serviceEndpoint": "\($ihurl)/api/credentials/v1/participants/\($b64did)", "id": "\($pidcs)" },
        { "type": "ProtocolEndpoint", "serviceEndpoint": "\($url)/api/dsp", "id": "\($pidsp)" }
      ],
      "active": true,
      "participantId": "\($did)",
      "did": "\($did)",
      "key": {
        "keyId": "\($did)#key-1",
        "privateKeyAlias": "\($did)#key-1",
        "keyGeneratorParams": { "algorithm": "EdDSA", "curve": "Ed25519" }
      }
    }')"

  post_json_allow_conflict "${identity_url}" "${payload}" "${IH_API_KEY}"
}

# Full bootstrap flow for a participant: validate, infra, runtime, DB, services, registration.
up() {
  validate
  vault_up
  runtime
  postgres_up
  db_init
  connector_up
  register
}

# Re-render artifacts and reconcile connector services with docker compose.
reload() {
  validate
  render_all
  compose "edc.yml" up -d controlplane dataplane identity-hub nginx
  echo "Compose reconciliation done for controlplane, dataplane, identity-hub and nginx."
}

# Open a socat tunnel from host to an internal service/port for debugging.
debug_open() {
  generate_derived_env
  load_effective_env 0
  docker_ready

  local target_service="${ARG1:-}"
  local target_port="${ARG2:-}"
  local host_port="${ARG3:-${ARG2:-}}"
  [[ -n "${target_service}" ]] || die "Usage: bash ./setup.sh debug-open <service> <target_port> [host_port]"
  [[ -n "${target_port}" ]] || die "Usage: bash ./setup.sh debug-open <service> <target_port> [host_port]"
  [[ "${target_port}" =~ ^[0-9]+$ ]] || die "target_port must be numeric."
  [[ "${host_port}" =~ ^[0-9]+$ ]] || die "host_port must be numeric."

  local tunnel_name="${COMPOSE_PROJECT_NAME}_dbg_${target_service}_${host_port}"
  tunnel_name="${tunnel_name//[^a-zA-Z0-9_.-]/-}"

  docker rm -f "${tunnel_name}" >/dev/null 2>&1 || true
  docker run -d \
    --name "${tunnel_name}" \
    --restart unless-stopped \
    --network "${COMPOSE_PROJECT_NAME}_edc-net" \
    -p "${host_port}:${host_port}" \
    alpine/socat \
    "tcp-listen:${host_port},fork,reuseaddr" \
    "tcp-connect:${target_service}:${target_port}" >/dev/null

  echo "Debug tunnel started:"
  echo "  - container: ${tunnel_name}"
  echo "  - host:      127.0.0.1:${host_port}"
  echo "  - target:    ${target_service}:${target_port}"
}

# List active socat debug tunnels for this participant instance.
debug_list() {
  generate_derived_env
  load_effective_env 0
  docker_ready

  local prefix="${COMPOSE_PROJECT_NAME}_dbg_"
  docker ps --filter "name=^/${prefix}" --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'
}

# Close one debug tunnel by name, or all tunnels for this participant when using "all".
debug_close() {
  generate_derived_env
  load_effective_env 0
  docker_ready

  local target="${ARG1:-all}"
  local prefix="${COMPOSE_PROJECT_NAME}_dbg_"
  if [[ "${target}" == "all" ]]; then
    local names
    names="$(docker ps -a --filter "name=^/${prefix}" --format '{{.Names}}')"
    if [[ -z "${names}" ]]; then
      echo "No debug tunnels found."
      return
    fi
    # shellcheck disable=SC2086
    docker rm -f ${names} >/dev/null
    echo "Removed all debug tunnels for ${COMPOSE_PROJECT_NAME}."
    return
  fi

  docker rm -f "${target}" >/dev/null
  echo "Removed debug tunnel: ${target}"
}

# Stop connector and vault compose stacks and remove their named volumes.
down() {
  compose "edc.yml" down -v
  compose "vault-edc.yml" down -v
}

# Remove generated and rendered folders for env/nginx artifacts.
# Also reset local vault bootstrap output files to empty JSON objects.
clean() {
  rm -rf "${RENDERED_DIR}" "${NGINX_DIR}/rendered" "${PARTICIPANT_PASS_FILE}" "${PARTICIPANT_DIR}/config/participants.json"
  echo "{}" > ${PARTICIPANT_DIR}/config/vault-edc-token.json
  echo "{}" > ${PARTICIPANT_DIR}/config/vault-data.json
  echo "Removed:"
  echo "  - ${RENDERED_DIR}"
  echo "  - ${NGINX_DIR}/rendered"
  echo "  - ${PARTICIPANT_PASS_FILE}"
  echo "  - ${PARTICIPANT_DIR}/config/participants.json"
}

# Display compose status for vault and connector stacks.
status() {
  compose "vault-edc.yml" ps
  compose "edc.yml" ps
}

# Show logs for connector services, or vault services when requested.
logs() {
  if [[ -n "${LOG_SERVICE}" ]]; then
    case "${LOG_SERVICE}" in
      vault|vault-init|vault-autounseal) compose "vault-edc.yml" logs --tail=200 -f "${LOG_SERVICE}" ;;
      *) compose "edc.yml" logs --tail=200 -f "${LOG_SERVICE}" ;;
    esac
  else
    compose "edc.yml" logs --tail=200
  fi
}

case "${ACTION}" in
  help|-h|--help) print_help ;;
  validate) validate ;;
  envs|render-envs) render_envs ;;
  proxy|proxy-summary) proxy ;;
  render) render_all ;;
  runtime) runtime ;;
  clean) clean ;;
  register) register ;;
  up) up ;;
  reload) reload ;;
  debug-open|debug) debug_open ;;
  debug-list) debug_list ;;
  debug-close) debug_close ;;
  down) down ;;
  status) status ;;
  logs) logs ;;
  *)
    print_help
    exit 1
    ;;
esac
