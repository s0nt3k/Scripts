# MySQL_DB
Deploys a MySQL v8.0 Database Server w/ phpMyAdmin

(Recommended) Create a .env file in the same folder to store secrets
```
MYSQL_ROOT_PASSWORD=SuperS3cureRoot!
MYSQL_DATABASE=appdb
MYSQL_USER=appuser
MYSQL_PASSWORD=AnotherS3curePass!
```
MYSQL_PASSWORD=AnotherS3curePass!Show more lines
Then reference them in the compose YAML:
```
environment:
  MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
  MYSQL_DATABASE: ${MYSQL_DATABASE}
  MYSQL_USER: ${MYSQL_USER}
  MYSQL_PASSWORD: ${MYSQL_PASSWORD}
```
**Start** the stack:
```
docker compose up -d
```
**Access phpMyAdmin:** <http://localhost:8080>
 - Server: db (or localhost if you bound 3306 and connect directly)
 - User: root (or appuser)
 - Password: the value you set

## Optional Enhancements
 - **Custom MySQL config:** drop a .cnf file in ./mysql/conf.d and uncomment the volume. Example ./mysql/conf.d/my.cnf:
```
[mysqld]
innodb_buffer_pool_size=512M
max_connections=200
```
 - **Backups (logical dump):**
```
# Full dump as root
docker exec -i mysql mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --routines --triggers --databases appdb > backup.sql

# Restore
docker exec -i mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" appdb < backup.sql
```
 - **Secure phpMyAdmin:**
   - Put behind a reverse proxy with HTTPS (e.g., Traefik or Nginx Proxy Manager).
   - Restrict access by network or VPN when in production.
 - **Migrate to MariaDB:** swap image: mysql:8.0 for mariadb:11 and adjust configs as needed.

### Quick Troubleshooting

 - **phpMyAdmin can’t connect to MySQL:** ensure PMA_HOST=db and that db is healthy (docker compose ps).
 - **Authentication plugin errors:** the --default-authentication-plugin=mysql_native_password command line ensures compatibility with many clients.
 - **Port conflicts:** change 3306:3306 or 8080:80 if already in use.
