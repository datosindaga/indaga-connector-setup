## Indaga Deploy

### Indaga Core

#### Proxying the app for HTTPS

1. Create neccesary variables:
```sh
export PARTICIPANT=<YOUR EDC PARTICIPANT>
export SUBDOMAIN=<YOUR SUBDOMAIN>
export DOMAIN=<YOUR DOMAIN>
```
2a. With nginx, use the /opt/.indaga-deploy/indaga-dataspace-connector/nginx/proxy.conf.template:
```sh
envsubst '$DOMAIN $SUBDOMAIN $PARTICIPANT' < /opt/.indaga-deploy/indaga-dataspace-connector/nginx/proxy.conf.template > <YOUR_NGINX_CONF_FOLDER>/${SUBDOMAIN}.${DOMAIN}.conf
```
2b. With Apache2, use the /opt/.indaga-deploy/indaga-dataspace-connector/httpd/connector.indaga.io.conf:
```sh
export APACHE="apache2"
envsubst '$DOMAIN $SUBDOMAIN $PARTICIPANT $APACHE' < /opt/.indaga-deploy/indaga-dataspace-connector/httpd/connector.indaga.io.conf > <YOUR_APACHE2_CONF_FOLDER>/${SUBDOMAIN}.${DOMAIN}.conf
```

##### Apache

The certs for the domain should exist:
`${DOMAIN}.crt`: Domain certificate (/etc/$APACHE/ssl.crt/$DOMAIN.crt)
`${DOMAIN}.key`: Domain key (/etc/$APACHE/ssl.crt/$DOMAIN.key)
`ca-bundle-${DOMAIN}.crt`: CA certificate (/etc/$APACHE/ssl.crt/ca-bundle-${DOMAIN}.crt)
If they are elsewhere, change the lines in `<YOUR_APACHE2_CONF_FOLDER>/${SUBDOMAIN}.${DOMAIN}.conf`

##### NGINX

The certs for the domain should exist:
`${DOMAIN}.fullchain.crt`: Fullchain Domain certificate (/etc/nginx/ssl/${DOMAIN}.fullchain.crt)
`${DOMAIN}.key`: Domain key (/etc/nginx/ssl/${DOMAIN}.key)
`ca-bundle-${DOMAIN}.crt`: CA certificate (/etc/nginx/ssl/ca-bundle-${DOMAIN}.crt)

If they are elsewhere those lines should be changed on `<YOUR_NGINX_CONF_FOLDER>/${SUBDOMAIN}.${DOMAIN}.conf`

#### Install

```sh
[ ! -d /opt/.indaga ] && mkdir /opt/.indaga
cd /opt/.indaga
cp /opt/.indaga-deploy/indaga-dataspace-connector/indaga-dataspace-connector-init.sh indaga-dataspace-connector-init.sh
#PARTICIPANT is the same as used in the edc-connector setup
PARTICIPANT=<YOUR_EDC_PARTICIPANT>
SERVICE_DNS=https://<YOUR_SERVICE_DNS>
chmod +x indaga-dataspace-connector-init.sh && ./indaga-dataspace-connector-init.sh $SERVICE_DNS
rm -rf indaga-dataspace-connector-init.sh
```

- indaga-dataspace-connector-init.sh options:
  - --no-databases
  - --no-apps
  - --proxy
  - --nginx (depends on --proxy to take effect)
  - --jwt-sign-key ES256 (Default ES256; options: RS256, ES256)


After setup is finished:

1. Review the properties files for each application:
   - indaga-auth: /opt/indaga-auth/application.properties
   nano /opt/indaga-auth/application.properties
   - indaga-dataspace-connector: /opt/indaga-dataspace-connector/application.properties
   nano /opt/indaga-dataspace-connector/application.properties

- Configure .properties files
   - Token date in auth properties

- Run the app:

```sh
docker compose -f /opt/.indaga/indaga-dataspace-connector-core.yml up -d
```

- Replace the token in connector app, and restart:

```sh
    watch -n 2 docker ps -a
    TOKEN=\`docker logs indaga-core-auth-1 | grep "TOKEN to Fly Apps generated" | awk -F': ' '{print \$NF}'\`
    echo \$TOKEN
    sed -i "s#\\\${FLYTHINGS_AUTH_TOKEN}#\${TOKEN}#" /opt/indaga-dataspace-connector/application.properties
    docker restart indaga-core-connector-1 
```

#### Version update

##### Docker Compose

```sh
cd /opt/.indaga
docker compose -f /opt/.indaga/indaga-dataspace-connector-core.yml pull
docker compose -f /opt/.indaga/indaga-dataspace-connector-core.yml up -d --force-recreate
```

##### Docker Swarm

```sh
docker stack deploy --resolve-image "always" --compose-file=/opt/.indaga/indaga-dataspace-connector-core.swarm.yml indaga-dataspace-connector --with-registry-auth
```

#### Uninstall

```sh
cd /opt/.indaga
docker compose -f indaga-dataspace-connector-databases.yml down
docker compose -f indaga-dataspace-connector-core.yml down
docker volume rm $(docker volume ls -q)
rm -rf /opt/.indaga 
rm -rf /opt/indaga-auth /opt/indaga-dataspace-connector
```

---

#### Port Services

##### DBs

| Service    |   Ports    |
| :--------- | :--------: |
| PostgreSQL |    5432    |
| MinIO      | 9090, 9091 |

##### Core Compose

| Service             | Ports |
| :------------------ | :---: |
| Auth                | 8080  |
| Indaga Connector    | 8980  |
| EDC Connector Nginx | 9080  |
