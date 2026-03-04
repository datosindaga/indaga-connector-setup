## Indaga Deploy

### Indaga Core

#### Install

```sh
[ ! -d /opt/.indaga ] && mkdir /opt/.indaga
cd /opt/.indaga
cp /opt/.indaga-deploy/indaga-dataspace-connector/indaga-dataspace-connector-init.sh indaga-dataspace-connector-init.sh
PARTICIPANT=<YOUR_EDC_PARTICIPANT>
SERVICE_DNS=https://<YOUR_SERVICE_DNS>
chmod +x indaga-dataspace-connector-init.sh && ./indaga-dataspace-connector-init.sh $SERVICE_DNS
chmod +x indaga-dataspace-connector-init.sh && ./indaga-dataspace-connector-init.sh $SERVICE_DNS --nginx
rm -rf indaga-dataspace-connector-init.sh
```

- indaga-dataspace-connector-init.sh options:
  - --no-databases
  - --no-apps
  - --no-proxy
  - --nginx
  - --jwt-sign-key RS256 (Default RS256; options: RS256, ES256)
* Configure .properties files
   - Token date and jti in auth properties
   - Token in connector properties


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

#### MinIO

Commands to add new users and grant permissions to bucket:

```sh
export NEW_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
export NEW_USER=<new-user>
export BUCKET=<the-bucket-name>
docker exec -i indaga-minio-1 bash -c "mc admin user add indaga $NEW_USER $NEW_PASSWORD"
docker exec -i indaga-minio-1 bash -c "cat > bucket-only.json <<EOF
{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Action\": [
        \"s3:ListBucket\"
      ],
      \"Resource\": [
        \"arn:aws:s3:::$BUCKET\"
      ]
    },
    {
      \"Effect\": \"Allow\",
      \"Action\": [
        \"s3:GetObject\",
        \"s3:PutObject\",
        \"s3:DeleteObject\"
      ],
      \"Resource\": [
        \"arn:aws:s3:::$BUCKET/*\"
      ]
    }
  ]
}
EOF"
docker exec -i indaga-minio-1 bash -c "mc admin policy create indaga $BUCKET-policy bucket-only.json"
docker exec -i indaga-minio-1 bash -c "mc admin policy attach indaga $BUCKET-policy --user $NEW_USER"


```

--- 

#### Port Services

##### DBs

| Service    |   Ports    |
| :--------- | :--------: |
| PostgreSQL |    5432    |
| MinIO      | 9090, 9091 |

##### Core Compose

| Service   | Ports |
| :-------- | :---: |
| Auth      | 8080  |
| Connector | 8980  |
