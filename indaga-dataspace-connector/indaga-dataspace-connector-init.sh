#!/bin/bash

#####
JWT_SIGN_KEY="RS256"
#####
POSITIONAL=()
while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        --nginx)
            NGINX=TRUE
            shift # past argument
        ;;
        --no-databases)
            NO_DBS=TRUE
            shift # past argument
        ;;
        --no-apps)
            NO_APPS=TRUE
            shift # past argument
        ;;
        --proxy)
            PROXY=TRUE
            shift # past argument
        ;;
        --kwt-sign-key)
            JWT_SIGN_KEY="$2"
            shift # past argument
            shift # past argument
        ;;
        *)    
            # unknown option
            POSITIONAL+=("$key") # save it in an array for later
            shift # past argument
        ;;
    esac
done
set -- "${POSITIONAL[@]}"
#####

INDAGA_SERVICE_DNS=$1
BASE_DEPLOY_DIR=/opt/.indaga-deploy/indaga-dataspace-connector

if [ -z "$NO_DBS" ]; then
    #########################################
    # Passwords generation
    #########################################
    if [ ! -f .pass ]; then
        export INDAGA_POSTGRES_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
        export INDAGA_MINIO_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`

        echo "export INDAGA_POSTGRES_PASSWORD=${INDAGA_POSTGRES_PASSWORD}" >> .pass
        echo "export INDAGA_MINIO_PASSWORD=${INDAGA_MINIO_PASSWORD}" >> .pass
    else
        source .pass
    fi
    #########################################

    #########################################
    # Databases installation
    #########################################
    if [ ! -f indaga-dataspace-connector-databases.yml ]; then
        cp $BASE_DEPLOY_DIR/indaga-dataspace-connector-databases.yml indaga-dataspace-connector-databases.yml
        docker compose -f indaga-dataspace-connector-databases.yml up -d
        docker compose -f indaga-dataspace-connector-databases.yml down

        sed -i "/POSTGRES_PASSWORD/d" indaga-dataspace-connector-databases.yml
        sed -i "s/\${INDAGA_MINIO_PASSWORD}/${INDAGA_MINIO_PASSWORD}/" indaga-dataspace-connector-databases.yml
    fi

    docker compose -f indaga-dataspace-connector-databases.yml up -d
    #########################################

    #########################################
    # MinIO Bucket Provision
    #########################################
    sleep 2
    docker exec -i indaga-minio-1 bash -c "mc alias set indaga http://127.0.0.1:9000 indaga $INDAGA_MINIO_PASSWORD"
    docker exec -i indaga-minio-1 mc mb indaga/indaga-data
    #########################################

    #########################################
    # PostgreSQL Indaga Database Provision
    #########################################
    echo $INDAGA_POSTGRES_PASSWORD | docker run --rm -i --net indaga_default -v /opt/.indaga-deploy/indaga-dataspace-connector/postgres/:/tmp/ -w /tmp/ postgis/postgis:15-3.3 psql -h postgres -U indaga -f kickstartdb.sql
    #########################################

    #########################################
    # Backup Enabled
    #########################################
    cp $BASE_DEPLOY_DIR/indaga-dataspace-connector-backup /etc/cron.daily/
    chmod +x /etc/cron.daily/indaga-dataspace-connector-backup
    #########################################
fi

if [ -z "$NO_APPS" ]; then

    if [ -f .pass ]; then
        source .pass
    fi

    #########################################
    # Indaga Auth Configuration
    #########################################
    if [ ! -d /opt/indaga-auth ]; then
        mkdir /opt/indaga-auth && cd /opt/indaga-auth
        case "$JWT_SIGN_KEY" in
            --RS256|RS256)
                openssl req -x509 -newkey rsa:2048 -nodes -keyout privateKey.pem -out publicKey.pem -subj "/C=ES/O=itg/CN=indaga"
            ;;
            --ES256|ES256|*)
                openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout privateKey.pem -out publicKey.pem -subj "/C=ES/O=itg/CN=indaga"
            ;;
        esac
        chmod 644 privateKey.pem
        cp $BASE_DEPLOY_DIR/pem-to-jwks.tar.gz pem-to-jwks.tar.gz && tar -zxvf pem-to-jwks.tar.gz
        cp publicKey.pem pem-to-jwks/
        cd pem-to-jwks
        docker run -it --rm -v $PWD:/mnt/ -w /mnt/ node:16-alpine npm install
        docker run -it --rm -v $PWD:/mnt/ -w /mnt/ node:16-alpine node index.js publicKey.pem > ../jwks.json
        cd .. && rm -rf pem-to-jwks pem-to-jwks.tar.gz
        docker rmi node:16-alpine
        cp $BASE_DEPLOY_DIR/properties/indaga-auth.properties application.properties
        sed -i "s/\${INDAGA_POSTGRES_PASSWORD}/${INDAGA_POSTGRES_PASSWORD}/" application.properties
        sed -i "s/\${INDAGA_MINIO_PASSWORD}/${INDAGA_MINIO_PASSWORD}/" application.properties
        sed -i "s#\${INDAGA_SERVICE_DNS}#${INDAGA_SERVICE_DNS}#" application.properties
        sed -i "s#\${INDAGA_JWT_SIGN_KEY}#${JWT_SIGN_KEY}#" application.properties
    fi
    #########################################


    #########################################
    # Indaga Connector Configuration
    #########################################
    if [ ! -d /opt/indaga-dataspace-connector ]; then
        mkdir /opt/indaga-dataspace-connector && cd /opt/indaga-dataspace-connector
        cp $BASE_DEPLOY_DIR/properties/indaga-dataspace-connector.properties application.properties
        sed -i "s/\${INDAGA_POSTGRES_PASSWORD}/${INDAGA_POSTGRES_PASSWORD}/" application.properties
        sed -i "s/\${INDAGA_MINIO_PASSWORD}/${INDAGA_MINIO_PASSWORD}/" application.properties
        sed -i "s#\${INDAGA_SERVICE_DNS}#${INDAGA_SERVICE_DNS}#" application.properties
    fi
    #########################################
fi

if [ "$PROXY" = "TRUE" ]; then
    #########################################
    # Proxy Provision
    #########################################
    if [ -z "$NGINX" ]; then
        if [ -d /etc/httpd/ ] && [ ! -f /etc/httpd/conf.d/connector.indaga.io.conf ]; then
            cp $BASE_DEPLOY_DIR/httpd/connector.indaga.io.conf /etc/httpd/conf.d/connector.indaga.io.conf
            sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /etc/httpd/conf.d/connector.indaga.io.conf
            cd /etc/httpd/ssl.crt
        fi
        if [ -d /etc/apache2/ ] && [ ! -f /etc/apache2/sites-available/connector.indaga.io.conf ]; then
            cp $BASE_DEPLOY_DIR/httpd/connector.indaga.io.conf /etc/apache2/sites-available/connector.indaga.io.conf
            sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /etc/apache2/sites-available/connector.indaga.io.conf
            a2ensite connector.indaga.io
            cd /etc/apache2/ssl.crt
        fi
    else
        echo "Configuring NGINX"
        if [ ! -d /opt/nginx ]; then
            mkdir /opt/nginx
            mkdir /opt/nginx/conf.d
            mkdir /opt/nginx/templates
            mkdir /opt/nginx/logs
            mkdir /opt/nginx/ssl
            mkdir /opt/nginx/www
        fi
        export DOMAIN=$(echo "$INDAGA_SERVICE_DNS" | sed -E 's~https?://~~' | cut -d. -f2-)
        export SUBDOMAIN=$(echo "$INDAGA_SERVICE_DNS" | sed -E 's~https?://~~' | awk -F. '{print $1}')
        cp $BASE_DEPLOY_DIR/nginx/proxy.conf.template /opt/nginx/templates/proxy.conf.template
        sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /opt/nginx/templates/proxy.conf.template
        cp $BASE_DEPLOY_DIR/nginx/web.conf.template /opt/nginx/templates/web.conf.template
        sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /opt/nginx/templates/web.conf.template
        cp $BASE_DEPLOY_DIR/nginx/default-proxy.conf.template /opt/nginx/conf.d/default-server.conf
        sed -i "s#\${PARTICIPANT}#${PARTICIPANT}#" /opt/nginx/conf.d/default-server.conf
        if [ "$DOMAIN" == "flythings.io" ]; then
            envsubst '$DOMAIN $SUBDOMAIN' < /opt/nginx/templates/proxy.conf.template > /opt/nginx/conf.d/${SUBDOMAIN}.${DOMAIN}.conf
        fi
        [ ! -f /opt/nginx/docker-proxy.yml ] && cp $BASE_DEPLOY_DIR/nginx/docker-proxy.yml /opt/nginx/
        [ -f /opt/nginx/docker-proxy.yml ] && docker compose -f /opt/nginx/docker-proxy.yml up -d
        cd /opt/nginx/ssl
        if [ "$DOMAIN" != "flythings.io" ]; then
            cat > flythings.io.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
IP.1 = $FLYTHINGS_RUNENV_SERVER_URL
# Si quieres también dominios:
# DNS.1 = lince0.flythings.io
# DNS.2 = www.lince0.flythings.io
EOF
        fi
    fi
    if [ ! -f ca-indaga.io.key ]; then
        openssl genrsa -out ca-indaga.io.key 4096
        openssl req -x509 -new -nodes -key ca-indaga.io.key -sha256 -days 3650 -subj "/C=ES/ST=Madrid/L=Madrid/O=Indaga/OU=IT/CN=Indaga-CA" -out ca-bundle-indaga.io.crt
        openssl genrsa -out indaga.io.key 4096
        openssl req -new -key indaga.io.key -subj "/C=ES/ST=Madrid/L=Madrid/O=Indaga/OU=Platform/CN=$INDAGA_RUNENV_SERVER_URL" -out indaga.io.csr
        if [ -f indaga.io.ext ]; then
            openssl x509 -req -in indaga.io.csr -CA ca-bundle-indaga.io.crt -CAkey ca-indaga.io.key -CAcreateserial -out indaga.io.crt -days 825 -sha256 -extfile indaga.io.ext
        else
            openssl x509 -req -in indaga.io.csr -CA ca-bundle-indaga.io.crt -CAkey ca-indaga.io.key -CAcreateserial -out indaga.io.crt -days 825 -sha256
        fi
        cat indaga.io.crt ca-bundle-indaga.io.crt > indaga.io.fullchain.crt
    fi
    #########################################
fi

if [ -z "$NO_APPS" ]; then
    #########################################
    # Indaga Core and Help Message
    #########################################
    cd /opt/.indaga
    if [ ! -f indaga-dataspace-connector-core.yml ]; then
        cp $BASE_DEPLOY_DIR/indaga-dataspace-connector-core.yml indaga-dataspace-connector-core.yml
        cp $BASE_DEPLOY_DIR/indaga-dataspace-connector-core.swarm.yml indaga-dataspace-connector-core.swarm.yml
        echo "" && echo "" && echo "" && echo "" && echo ""
        cat <<EOF
##############################################
# Help: Indaga Service Configuration & Deployment
##############################################

1. Review the properties files for each application:
   - indaga-auth: /opt/indaga-auth/application.properties
   nano /opt/indaga-auth/application.properties
   - indaga-dataspace-connector: /opt/indaga-dataspace-connector/application.properties
   nano /opt/indaga-dataspace-connector/application.properties

   Properties to overwrite:
   - Token date and jti in auth properties
   - Token properties in connector

2. Include service dns in apache conf file and restart
    [ -f /etc/httpd/conf.d/connector.indaga.io.conf ] && nano /etc/httpd/conf.d/connector.indaga.io.conf
    systemctl restart httpd
    ó
    [ -f /etc/apache2/sites-available/connector.indaga.io.conf ] && nano /etc/apache2/sites-available/connector.indaga.io.conf
    systemctl restart apache2
    ó
    [ -f /opt/nginx/conf.d/connector.indaga.io.conf ] && nano /opt/nginx/conf.d/connector.indaga.io.conf
    docker restart proxy-nginx-1

3. After editing the properties files, deploy the services:
   docker compose -f /opt/.indaga/indaga-dataspace-connector-core.yml up -d

4. Include Auth token in Flyapps properties and refresh services
    watch -n 2 docker ps -a
    TOKEN=\`docker logs indaga-core-auth-1 | grep "TOKEN to Fly Apps generated" | awk -F': ' '{print \$NF}'\`
    echo \$TOKEN
    sed -i "s#\\\${FLYTHINGS_AUTH_TOKEN}#\${TOKEN}#" /opt/indaga-dataspace-connector/application.properties
    docker restart indaga-core-connector-1 

5. Save and remove the /opt/.indaga/.pass

##############################################
EOF
    fi
    #########################################
fi