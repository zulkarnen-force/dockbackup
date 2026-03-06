# Docker DB Backup Agent

Lightweight Docker sidecar that automatically discovers and backs up **PostgreSQL**, **MySQL / MariaDB**, and **MongoDB** containers — by label.

Backups can be stored locally, uploaded to cloud storage via [rclone](https://rclone.org) (Cloudflare R2, Mega, PCloud), or both.

```
docker pull zulkarnen/docker-db-backup:latest
```

---

## Features

- **Auto-discovery** — finds containers with a configurable Docker label
- **Auto-detect database type** — identifies PostgreSQL, MySQL/MariaDB, or MongoDB from the container image name
- **Multiple backup formats** — plain SQL or compressed (pg_dump -Fc, gzip, mongodump --gzip archive)
- **Cloud upload** — upload backups to up to **2 rclone providers** simultaneously (R2, Mega, PCloud)
- **Flexible backup method** — `local` only, `rclone` only, or `both`
- **Retention policy** — keeps the last N backups (applies to both local and remote storage)
- **Human-friendly intervals** — `60s`, `5m`, `1h`
- **Multi-arch** — `linux/amd64` and `linux/arm64`

---

## Quick Start

### 1. Label your database containers

Add the label `backup.enable=true` to any database container you want to back up:

```yaml
# your existing database service
services:
  my-postgres:
    image: postgres:16
    labels:
      - backup.enable=true
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: secret
```

### 2. Run the backup agent

```yaml
services:
  backup:
    image: zulkarnen/docker-db-backup:latest
    container_name: backup-agent
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backups:/backup
    environment:
      INTERVAL: 1h
```

That's it. The agent will discover all labeled containers and back them up every hour.

---

## Environment Variables

### Core

| Variable        | Default              | Description                                                        |
| --------------- | -------------------- | ------------------------------------------------------------------ |
| `TZ`            | `Asia/Jakarta`       | Timezone for timestamps                                            |
| `BACKUP_DIR`    | `/backup`            | Local backup directory inside the container                        |
| `LABEL_FILTER`  | `backup.enable=true` | Docker label used to discover database containers                  |
| `INTERVAL`      | `5m`                 | Backup interval. Supports: `60s`, `5m`, `1h`, or raw seconds `300` |
| `MAX_FILES`     | `7`                  | Number of backups to retain (per container, both local and remote) |
| `BACKUP_FORMAT` | `compress`           | `plain` or `compress` (see format table below)                     |
| `BACKUP_METHOD` | `local`              | `local`, `rclone`, or `both` (see below)                           |

### Backup Method

| Value    | Local file           | Cloud upload | Local retention | Remote retention |
| -------- | -------------------- | ------------ | --------------- | ---------------- |
| `local`  | Kept                 | No           | Yes             | No               |
| `rclone` | Deleted after upload | Yes          | No              | Yes              |
| `both`   | Kept                 | Yes          | Yes             | Yes              |

### Backup Format

| Database        | `plain`    | `compress`                    |
| --------------- | ---------- | ----------------------------- |
| PostgreSQL      | `.sql`     | `.dump` (pg_dump -Fc)         |
| MySQL / MariaDB | `.sql`     | `.sql.gz`                     |
| MongoDB         | `.archive` | `.archive` (mongodump --gzip) |

### Rclone Providers (up to 2 slots)

Replace `n` with `1` or `2`.

#### Common

| Variable               | Default   | Description                                     |
| ---------------------- | --------- | ----------------------------------------------- |
| `RCLONE_n_PROVIDER`    | _(empty)_ | `r2`, `mega`, or `pcloud`. Leave empty to skip. |
| `RCLONE_n_NAME`        | `remoteN` | Rclone remote name                              |
| `RCLONE_n_REMOTE_PATH` | `backup`  | Remote path / bucket                            |

#### Cloudflare R2

| Variable                     | Description                                  |
| ---------------------------- | -------------------------------------------- |
| `RCLONE_n_ACCESS_KEY_ID`     | R2 access key                                |
| `RCLONE_n_SECRET_ACCESS_KEY` | R2 secret key                                |
| `RCLONE_n_ENDPOINT`          | `https://<account>.r2.cloudflarestorage.com` |
| `RCLONE_n_ACL`               | `private` (default)                          |

#### Mega

| Variable        | Description                                           |
| --------------- | ----------------------------------------------------- |
| `RCLONE_n_USER` | Mega email                                            |
| `RCLONE_n_PASS` | Mega password (plain text — auto-obscured at startup) |

#### PCloud

| Variable            | Description                                            |
| ------------------- | ------------------------------------------------------ |
| `RCLONE_n_HOSTNAME` | `api.pcloud.com` (default) or `eapi.pcloud.com` for EU |
| `RCLONE_n_TOKEN`    | OAuth access token (raw string or full JSON)           |

---

## Database Auto-Detection

The agent inspects the container's **image name** to determine the database type:

| Image pattern | Detected as                  |
| ------------- | ---------------------------- |
| `*postgres*`  | PostgreSQL                   |
| `*mysql*`     | MySQL                        |
| `*mariadb*`   | MariaDB (backed up as MySQL) |
| `*mongo*`     | MongoDB                      |

This covers official images (`postgres:16`, `mysql:8`, `mongo:7`), Bitnami images (`bitnami/postgresql`, `bitnami/mongodb`), and custom images containing these keywords.

> **Note — MongoDB:** Unlike PostgreSQL and MySQL (which use `docker exec`), MongoDB backups run the agent's own `mongodump` binary and connect to the container via its Docker network IP. This is necessary because MongoDB 6.0+ images no longer bundle `mongodump`. The backup agent must share a Docker network with the MongoDB container (automatic when both are in the same `docker-compose.yml`).

### Required Container Environment Variables

**PostgreSQL:**

- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`

**MySQL / MariaDB:**

- `MYSQL_DATABASE` / `MARIADB_DATABASE`
- `MYSQL_USER` / `MARIADB_USER`
- `MYSQL_PASSWORD` / `MARIADB_PASSWORD`
- Falls back to `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` if user/pass not set

**MongoDB:**

- `MONGO_INITDB_ROOT_USERNAME` / `MONGODB_ROOT_USER`
- `MONGO_INITDB_ROOT_PASSWORD` / `MONGODB_ROOT_PASSWORD`
- `MONGO_INITDB_DATABASE` / `MONGODB_DATABASE` _(optional — backs up all databases if not set)_

---

## Examples

### Local backup only (simplest)

```yaml
services:
  db:
    image: postgres:16
    labels:
      - backup.enable=true
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: secret

  backup:
    image: zulkarnen/docker-db-backup:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backups:/backup
    environment:
      INTERVAL: 1h
      MAX_FILES: 7
```

### Upload to PCloud only (no local files)

```yaml
services:
  backup:
    image: zulkarnen/docker-db-backup:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      INTERVAL: 6h
      BACKUP_METHOD: rclone
      RCLONE_1_PROVIDER: pcloud
      RCLONE_1_NAME: mypcloud
      RCLONE_1_REMOTE_PATH: backups/myserver
      RCLONE_1_TOKEN: "<your-pcloud-access-token>"
```

### Both local + Cloudflare R2

```yaml
services:
  backup:
    image: zulkarnen/docker-db-backup:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backups:/backup
    environment:
      INTERVAL: 30m
      BACKUP_METHOD: both
      RCLONE_1_PROVIDER: r2
      RCLONE_1_NAME: cloudflare
      RCLONE_1_REMOTE_PATH: my-bucket/db-backups
      RCLONE_1_ACCESS_KEY_ID: "<key>"
      RCLONE_1_SECRET_ACCESS_KEY: "<secret>"
      RCLONE_1_ENDPOINT: "https://<account>.r2.cloudflarestorage.com"
```

### Dual provider — R2 + Mega

```yaml
services:
  backup:
    image: zulkarnen/docker-db-backup:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backups:/backup
    environment:
      INTERVAL: 1h
      BACKUP_METHOD: both
      MAX_FILES: 14

      RCLONE_1_PROVIDER: r2
      RCLONE_1_NAME: cloudflare
      RCLONE_1_REMOTE_PATH: my-bucket/backups
      RCLONE_1_ACCESS_KEY_ID: "<key>"
      RCLONE_1_SECRET_ACCESS_KEY: "<secret>"
      RCLONE_1_ENDPOINT: "https://<account>.r2.cloudflarestorage.com"

      RCLONE_2_PROVIDER: mega
      RCLONE_2_NAME: mega
      RCLONE_2_REMOTE_PATH: /backups
      RCLONE_2_USER: "user@example.com"
      RCLONE_2_PASS: "your-mega-password"
```

### MongoDB only

```yaml
services:
  mongo:
    image: mongo:7
    labels:
      - backup.enable=true
    environment:
      MONGO_INITDB_DATABASE: myapp
      MONGO_INITDB_ROOT_USERNAME: admin
      MONGO_INITDB_ROOT_PASSWORD: secret

  backup:
    image: zulkarnen/docker-db-backup:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backups:/backup
    environment:
      INTERVAL: 1h
      BACKUP_FORMAT: compress
      MAX_FILES: 7
```

### Mixed databases

```yaml
services:
  postgres-db:
    image: postgres:16
    labels:
      - backup.enable=true
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret

  mysql-db:
    image: mysql:8
    labels:
      - backup.enable=true
    environment:
      MYSQL_DATABASE: shop
      MYSQL_USER: shop
      MYSQL_PASSWORD: secret
      MYSQL_ROOT_PASSWORD: rootsecret

  mongo-db:
    image: mongo:7
    labels:
      - backup.enable=true
    environment:
      MONGO_INITDB_DATABASE: analytics
      MONGO_INITDB_ROOT_USERNAME: admin
      MONGO_INITDB_ROOT_PASSWORD: secret

  backup:
    image: zulkarnen/docker-db-backup:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backups:/backup
    environment:
      INTERVAL: 1h
      BACKUP_FORMAT: compress
      MAX_FILES: 7
```

---

## Backup Directory Structure

```
/backup/
├── postgres-db/
│   ├── app_20260305_120000.dump
│   └── app_20260305_130000.dump
├── mysql-db/
│   ├── shop_20260305_120000.sql.gz
│   └── shop_20260305_130000.sql.gz
└── mongo-db/
    ├── analytics_20260305_120000.archive
    └── analytics_20260305_130000.archive
```

Backups are organized by container name, with filenames containing the database name and timestamp.

---

## GitHub Actions (CI/CD)

This repository includes a GitHub Actions workflow that:

1. **Lints** the Dockerfile (Hadolint) and shell script (ShellCheck)
2. **Builds** multi-arch images (`amd64` + `arm64`)
3. **Pushes** to Docker Hub on every push to `main` and on version tags
4. **Auto-updates** the Docker Hub README

### Setup

Add these secrets to your GitHub repository:

| Secret               | Description                                                                           |
| -------------------- | ------------------------------------------------------------------------------------- |
| `DOCKERHUB_USERNAME` | Your Docker Hub username                                                              |
| `DOCKERHUB_TOKEN`    | Docker Hub access token ([create one here](https://hub.docker.com/settings/security)) |

### Tagging

Push a semver tag to create a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This produces Docker tags: `1.0.0`, `1.0`, `1`, and `latest`.

---

## License

MIT
