# Indaga EDC Connector

This folder is a template for creating participant instances.


## Workflow

1. Copy `participant` manually once per connector instance.

Example:

```bash
#PARTICIPANT is the name of the participant generated, should be changed by a name containing no spaces nor puntuaction, and should be easily recognised, as it will be used to generate the credentials.
PARTICIPANT=<YOUR_PARTICIPANT_NAME>
mkdir -p /opt/indaga-edc/${PARTICIPANT}
cd /opt/.indaga-deploy/edc-connector
cp -R participant/* /opt/indaga-edc/${PARTICIPANT}/
cd /opt/indaga-edc/${PARTICIPANT}
# Modify the file according to your configuration (DNS, PARTICIPANT NAME)
nano participant.env
chmod +x setup.sh && ./setup.sh up
```
After install, redirect your traffic from

`https://$BASE_URL/$PARTICIPANT`

to

`http://localhost:9080/$PARTICIPANT`

## Single Config File

Edit only `participant.env`.

```env
BASE_URL=devdsconnector.indaga.io
TRUSTED_ISSUER_DID=did:web:cloud.datosindaga.com:issuer
```

- TRUSTED_ISSUER_DID must be held as it is by default.
- BASE_URL is the DNS Record pointing to the machine where Connector is deployed


PostgreSQL, Vault, Control Plane, Data Plane and Identity Hub run internally in the Docker network.
Public paths are fixed to `/cp`, `/ih`, and `/dp` for each participant instance.
`PARTICIPANT` is normalized to lowercase and validated (`a-z`, `0-9`, `-`).
PostgreSQL user is fixed to the participant name (`PARTICIPANT`).
PostgreSQL password is auto-generated and persisted in `config/.pass`.
Only Nginx is exposed to host ports.

## Configuration values for the Dataspace Connector App

Values related as ENV_VARS in the example can be found in config/.pass file created after the installation

- URL : https://${BASE_URL}/${PARTICIPANT}/cp (found in participant.env)
- Token : ${AUTH_KEY} (found in config/.pass)
- DID: ${DID} (found in config/.pass)
- Identity Hub URL: https://${BASE_URL}/${PARTICIPANT}/ih (found in participant.env)
- Identity Hub Credential: ${IH_API_KEY} (found in config/.pass)

## Nginx Proxy Config

- Editable TLS template: `participant/nginx/default.conf.template`
- Editable HTTP-only template: `participant/nginx/default.http.conf.template`
- Rendered file used by Docker Compose: `participant/nginx/rendered/default.conf`
- TLS certificate path: `participant/nginx/certs/tls.crt`
- TLS key path: `participant/nginx/certs/tls.key`

If both TLS files exist, HTTPS config is rendered.
If they do not exist (or only one exists), the script renders HTTP-only config.
If `BASE_URL` is an IPv4 address and TLS files are missing, `setup.sh` auto-generates:
- `participant/nginx/certs/tls.crt`
- `participant/nginx/certs/tls.key`
- `participant/nginx/certs/ca-bundle.crt`

## Local Commands (inside each participant folder)

```bash
bash ./setup.sh help
bash ./setup.sh validate
bash ./setup.sh clean
bash ./setup.sh envs
bash ./setup.sh proxy
bash ./setup.sh render
bash ./setup.sh runtime
bash ./setup.sh up
bash ./setup.sh reload
bash ./setup.sh status
bash ./setup.sh logs controlplane
bash ./setup.sh debug-open controlplane 7060 17060
bash ./setup.sh debug-list
bash ./setup.sh debug-close all
bash ./setup.sh register
bash ./setup.sh down
```

## What Each Command Does

- `help`: Shows all available commands and examples.
- `validate`: Checks required tools, Docker availability, required secrets, and host port conflicts.
- `clean`: Removes `env/rendered` and `nginx/rendered`.
- `envs`: Re-renders only `cp.env`, `dp.env`, and `ih.env` into `env/rendered` using existing `config/.pass` values.
- `proxy`: Re-renders `nginx/rendered/default.conf` using existing `config/.pass` values.
- `render`: Runs `envs` and `proxy`.
- `runtime`: Generates runtime env files, rendered service env files, and rendered nginx config.
- `up`: Runs the full flow (`validate -> vault -> runtime -> postgres -> db init -> connector -> register`).
- `reload`: Runs `render` and then `docker compose up -d` for `controlplane`, `dataplane`, `identity-hub`, and `nginx`.
- `debug-open <svc> <target_port> [host_port]`: Starts a `socat` tunnel container to expose an internal service port on host for debugging.
- `debug-list`: Lists active debug tunnel containers.
- `debug-close [name|all]`: Removes one debug tunnel container or all tunnels for this participant.
- `down`: Stops both compose stacks (`edc.yml` and `vault-edc.yml`) and removes their volumes.
- `status`: Shows current container status for both stacks.
- `logs [service]`: Shows logs for connector services or vault services.
- `register`: Re-registers the participant in Identity Hub.

## Generated Files

- `config/.pass`
- `env/rendered/cp.env`
- `env/rendered/dp.env`
- `env/rendered/ih.env`
- `nginx/rendered/default.conf`
