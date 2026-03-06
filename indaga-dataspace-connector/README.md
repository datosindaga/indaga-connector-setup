## Indaga Deploy

### Indaga Core

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

- Configure .properties files
   - Token date in auth properties
   - Token in connector properties

```sh
    watch -n 2 docker ps -a
    TOKEN=\`docker logs indaga-core-auth-1 | grep "TOKEN to Fly Apps generated" | awk -F': ' '{print \$NF}'\`
    echo \$TOKEN
    sed -i "s#\\\${FLYTHINGS_AUTH_TOKEN}#\${TOKEN}#" /opt/indaga-dataspace-connector/application.properties
    docker restart indaga-core-connector-1 
```

#### Proxying the app for HTTPS

##### NGINX

There is two site templates for NGINX inside `nginx/` with name `proxy.conf.template`. Replace the variables with its value.

Example:

```sh
PARTICIPANT=<YOUR EDC PARTICIPANT>
SUBDOMAIN=<YOUR SUBDOMAIN>
DOMAIN=<YOUR DOMAIN>
cp nginx/proxy.conf.template /etc/nginx/conf.d/proxy.io.conf
sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /etc/nginx/templates/proxy.io.conf
sed -i "s#\${SUBDOMAIN}#${SUBDOMAIN}#" /etc/nginx/templates/proxy.io.conf
sed -i "s#\${DOMAIN}#${DOMAIN}#" /etc/nginx/templates/proxy.io.conf
```

In the nginx `etc` folder must have a `ssl` folder with:
`${DOMAIN}.fullchain.crt`: Fullchain Domain certificate
`${DOMAIN}.key`: Domain key
`ca-bundle-${DOMAIN}.crt`: CA certificate

If they are elsewhere those lines should be changed on the template on `proxy.io.conf`and `web.io.conf`.

##### Apache

There is a site template for Apache/HTTPD inside `httpd` folder. Replace the variables with its value.

Example for httpd:

```sh
PARTICIPANT=<YOUR EDC PARTICIPANT>
SUBDOMAIN=<YOUR SUBDOMAIN>
DOMAIN=<YOUR DOMAIN>
# Apache values are httpd/apache2
APACHE=httpd
cp httpd/connector.indaga.io.conf /etc/${APACHE}/conf.d/connector.indaga.io.conf
sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /etc/httpd/conf.d/connector.indaga.io.conf
sed -i "s#\${SUBDOMAIN}#${SUBDOMAIN}#" /etc/httpd/conf.d/connector.indaga.io.conf
sed -i "s#\${DOMAIN}#${DOMAIN}#" /etc/httpd/conf.d/connector.indaga.io.conf
sed -i "s#\${APACHE}#${APACHE}#" /etc/httpd/conf.d/connector.indaga.io.conf       
```

Example for apache2:

```sh
SUBDOMAIN=<YOUR SUBDOMAIN>
DOMAIN=<YOUR DOMAIN>
# Apache values are httpd/apache2
APACHE=apache2
cp httpd/connector.indaga.io.conf /etc/${APACHE}/sites-available/connector.indaga.io.conf
sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /etc/httpd/conf.d/connector.indaga.io.conf
sed -i "s#\${SUBDOMAIN}#${SUBDOMAIN}#" /etc/httpd/conf.d/connector.indaga.io.conf
sed -i "s#\${DOMAIN}#${DOMAIN}#" /etc/httpd/conf.d/connector.indaga.io.conf
sed -i "s#\${APACHE}#${APACHE}#" /etc/httpd/conf.d/connector.indaga.io.conf       
```

In the httpd/apache2 `etc` folder must have a `ssl.crt` folder with:
`${DOMAIN}.crt`: Domain certificate
`${DOMAIN}.key`: Domain key
`ca-bundle-${DOMAIN}.crt`: CA certificate

If they are elsewhere those lines should be changed on the template on connector.indaga.io.conf

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
