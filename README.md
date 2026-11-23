# CloudNotes 

A note-taking web application deployed on **Microsoft Azure** using Azure Container Instances (ACI), with automatic HTTPS via Let's Encrypt and Caddy.

---

## 1. Application Description

**CloudNotes** is a lightweight, responsive note-taking web application. Users can:

- Create notes with a title and multi-line content.
- View all their notes in reverse-chronological order.
- Delete notes they no longer need.
- Read this README directly in the browser via the **README** button in the navbar.

The app is accessible in any modern web browser over HTTPS at a free Azure subdomain:
`https://<AZURE_DNS_LABEL>.<AZURE_LOCATION>.azurecontainer.io`

All data is stored in a PostgreSQL database running as a container inside an Azure Container Instance group.

---

## 2. Cloud Services, Docker Objects, Persistent Volumes, Databases

### Cloud Provider — Microsoft Azure (Azure for Students)

| Azure Resource | Purpose |
|---|---|
| **Resource Group** | Logical container for all CloudNotes resources |
| **Azure Container Registry (ACR)** | Private Docker registry — stores the built backend image |
| **Azure Container Instances (ACI)** | Serverless container hosting — runs all 3 containers in one group |
| **Azure Storage Account** | Hosts Azure File shares used as persistent volumes |
| **Azure File Shares** (3×) | `caddy-data`, `caddy-config`, `postgres-data` (backup only) |

### DNS — ACI Built-in DNS Label (free)

ACI provides a free public DNS label for every container group:
`<dnsNameLabel>.<region>.azurecontainer.io`. Used directly for HTTPS — no external DNS service required.

### Containers (3 in one ACI container group)

| Container | Image | Role |
|---|---|---|
| `caddy` | `caddy:2-alpine` | Reverse proxy; automatic Let's Encrypt HTTPS; access logs to stdout |
| `backend` | custom (Python 3.11 + Flask + Gunicorn) built from `backend/Dockerfile` | REST API at `/api/notes`; serves the HTML frontend at `/` |
| `db` | `postgres:15-alpine` | Relational database storing all notes |

All three containers share the same `localhost` network inside the ACI group.

### Persistent Storage

| Volume | Type | Contents |
|---|---|---|
| `caddy-data` | Azure Files share | Let's Encrypt certificates — survives container restarts |
| `caddy-config` | Azure Files share | `Caddyfile` — Caddy configuration uploaded by `prepare-app.sh` |
| `postgres-data` | `emptyDir` (in-container disk) | PostgreSQL data directory — persists while container group is running |
| `postgres-backup` | Azure Files share (`postgres-data`) | Dump files written by `backup.sh` via `pg_dump` |

> **Note:** `emptyDir` is used for the PostgreSQL data directory because Azure Files (SMB) does not support the POSIX file permissions that PostgreSQL requires. Data persists across individual container crashes (ACI restarts the container automatically) but is lost if the container *group* is stopped or deleted. Use `backup.sh` regularly to preserve data.

### Automatic Restart

The ACI container group is configured with `restartPolicy: Always`. If any container crashes, ACI automatically restarts it. The Flask backend retries the database connection up to 30 times (3 s apart) on startup, so it recovers gracefully if PostgreSQL starts slowly.

---

## 3. Cost Analysis — 1 000 Users/Day, 50 GB Data

### Assumptions

- 1 000 daily active users, ~10 requests each → ~10 000 requests/day
- Average response ~50 KB → ~500 MB egress/day → ~182 GB/year
- 50 GB database data stored in Azure Blob/Files
- Region: germanywestcentral; prices in USD

### Azure Resource Costs (annual)

| Resource | Specification | Monthly Price | Annual Price |
|---|---|---|---|
| ACI — CPU | 1.0 vCPU × 730 h × $0.0000125/vCPU-s | ~$32.85 | **$394** |
| ACI — Memory | 1.3 GB × 730 h × $0.0000013/GB-s | ~$3.63 | **$43.56** |
| ACR Basic | $0.167/day | ~$5.00 | **$60** |
| Storage Account | Standard LRS, 3 shares, ~5 GB | ~$0.15 | **$1.80** |
| Outbound bandwidth | 182 GB/year − 100 GB free = 82 GB × $0.081 | — | **$6.64** |
| **Total estimate** | | | **≈ $506 / year** |

> **Notes:**
> - Azure for Students provides **$100 free credit** — enough for ~2.5 months of 24/7 operation, or much longer if the app is stopped when not in use (`./remove-app.sh`).
> - Cost drops significantly if the app is only run during exam/demo periods.
> - For a production 1 000-user scenario, consider **Azure Container Apps** (scale-to-zero, cheaper idle cost) or **Azure App Service** (managed runtime, ~$13/month on B1).
> - Backup storage: ~$0.02/GB/month → 5 GB of backups ≈ $1.20/year.

---

## 4. File Descriptions

```
sk1/
├── prepare-app.sh          # Deploys the application to Azure — no web UI needed
├── remove-app.sh           # Deletes all Azure resources created by prepare-app.sh
├── backup.sh               # Dumps PostgreSQL to Azure Files, downloads compressed backup
├── docker-compose.yml      # Reference only — not used in cloud deployment
├── .env.example            # Template for environment variables (safe to commit)
├── .gitignore              # Excludes .env and backup files from git
├── README.md               # This documentation file
└── backend/
    ├── Dockerfile          # Builds Flask/Gunicorn container (Python 3.11-slim)
    ├── app.py              # Flask routes: GET / (UI), /api/health, /api/readme, /api/notes (CRUD)
    ├── requirements.txt    # Python dependencies: Flask, psycopg2-binary, gunicorn
    ├── init.sql            # PostgreSQL schema (reference; schema created by app.py init_db())
    └── templates/
        └── index.html      # Single-page Bootstrap 5 frontend using fetch API
```

### Key file details

- **`prepare-app.sh`** — Creates an Azure resource group, ACR, storage account, and 3 Azure File shares; builds and pushes the backend Docker image to ACR; uploads a `Caddyfile` to Azure Files; generates an ACI JSON configuration with all 3 containers and deploys it. Idempotent — skips already-created resources on re-run.
- **`remove-app.sh`** — Deletes the entire resource group (and everything inside it) with one `az group delete` command. Requires typing `yes` to confirm.
- **`backup.sh`** — Runs `pg_dump` inside the `db` container via `az container exec`, writes the dump to the `postgres-backup` Azure Files mount (`/backup`), downloads it locally, gzips it, then deletes the remote file.
- **`backend/app.py`** — Input is validated and sanitised (length limits, `get_json(silent=True)`). Each request opens a fresh DB connection via `psycopg2` and closes it in a `finally` block. `init_db()` retries 30 times on startup to wait for PostgreSQL to be ready.
- **`backend/Dockerfile`** — Multi-layer build: installs Python dependencies first (cached layer), then copies app source. `README.md` is copied in by `prepare-app.sh` before `docker build` so `/api/readme` can serve it.

---

## 5. Configuration Description

All configuration is done via **environment variables** in a `.env` file that is **excluded from git** by `.gitignore`.

| Variable | Description |
|---|---|
| `AZURE_RESOURCE_GROUP` | Azure resource group name (e.g. `cloudnotes-rg`) |
| `AZURE_LOCATION` | Azure region — must be an allowed region (e.g. `germanywestcentral`) |
| `AZURE_DNS_LABEL` | Public DNS prefix for the ACI group — must be globally unique |
| `POSTGRES_DB` | Database name (default `cloudnotes`) |
| `POSTGRES_USER` | Database username (default `cloudnotes_user`) |
| `POSTGRES_PASSWORD` | **Secret** — strong password required; passed as `secureValue` in ACI |
| `SECRET_KEY` | **Secret** — Flask session key; auto-generated with `openssl rand` if left empty |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt certificate expiry notifications |

The following are derived automatically by `prepare-app.sh` and never need to be set manually:

| Derived variable | Formula |
|---|---|
| `STORAGE_ACCOUNT` | `${AZURE_DNS_LABEL:0:16}sa` (alphanumeric only, lowercase) |
| `ACR_NAME` | `${AZURE_DNS_LABEL:0:16}acr` |
| `DOMAIN` | `${AZURE_DNS_LABEL}.${AZURE_LOCATION}.azurecontainer.io` |
| `DATABASE_URL` | `postgresql://user:pass@localhost:5432/db` (localhost — all containers share network) |

---

## 6. Using the Application in a Web Browser

1. After `prepare-app.sh` completes, open the URL printed at the end:
   `https://<AZURE_DNS_LABEL>.<AZURE_LOCATION>.azurecontainer.io`
2. On the **first visit**, wait up to 2 minutes — Caddy contacts Let's Encrypt and obtains the TLS certificate automatically.
3. The **CloudNotes** UI appears:
   - **Left panel** — Enter a title and content, click **Save Note**.
   - **Right panel** — All saved notes appear; click **Delete** to remove one.
   - **README button** (navbar, top-right) — Opens this README rendered in a modal.
4. To verify the backend health: visit `/api/health` — returns `{"status":"healthy","database":"connected"}`.

---

## 7. Performing a Data Backup

### Automated (from your local machine)

```bash
cd sk1
./backup.sh
```

Backup is saved to `./backups/cloudnotes_backup_YYYYMMDD_HHMMSS.sql.gz`.

### Restore from backup

```bash
STORAGE_ACCOUNT="cloudnotesjoelsa"   # adjust to your value

# Decompress and upload to Azure Files
gunzip -c ./backups/cloudnotes_backup_TIMESTAMP.sql.gz > /tmp/restore.sql
az storage file upload \
    --account-name "$STORAGE_ACCOUNT" \
    --share-name postgres-data \
    --source /tmp/restore.sql \
    --path restore.sql

# Run psql restore inside the db container
az container exec \
    -g cloudnotes-rg -n cloudnotes-group \
    --container-name db \
    --exec-command "psql -U cloudnotes_user -d cloudnotes -f /backup/restore.sql"
```

---

## 8. Viewing Access Logs from the Internet

Caddy logs every HTTP/HTTPS request to stdout, which is captured by ACI.

### Live log stream

```bash
az container logs -g cloudnotes-rg -n cloudnotes-group --container-name caddy --follow
```

### Last N lines (snapshot)

```bash
az container logs -g cloudnotes-rg -n cloudnotes-group --container-name caddy
```

### Backend application logs

```bash
az container logs -g cloudnotes-rg -n cloudnotes-group --container-name backend
```

### Container status

```bash
az container show -g cloudnotes-rg -n cloudnotes-group \
    --query "containers[*].{name:name,state:instanceView.currentState.state}" -o table
```

The Caddy log includes: timestamp, client IP, HTTP method, URL path, status code, response size, and user-agent.

---

## 9. Conditions for Running prepare-app.sh and remove-app.sh

### Requirements (on your local machine before running)

| Requirement | How to satisfy |
|---|---|
| Azure CLI (`az`) installed | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |
| Logged in to Azure | `az login` |
| Azure for Students account active | Sign up at azure.microsoft.com/free/students with university email |
| Docker daemon running | `sudo service docker start` (WSL) or Docker Desktop |
| `python3` and `openssl` | Pre-installed on Ubuntu; `sudo apt install python3 openssl` if missing |
| `.env` file filled in | `cp .env.example .env` then edit all values |
| Azure region allowed by policy | Use one of: `germanywestcentral`, `switzerlandnorth`, `norwayeast`, `spaincentral`, `francecentral` |

### Running prepare-app.sh

```bash
cd sk1
cp .env.example .env      # fill in your values
chmod +x *.sh
./prepare-app.sh
```

The script is **idempotent** — running it again skips already-created resources (ACR, storage account, file shares).
Total runtime: approximately 3–5 minutes (Docker build is fast on re-run due to layer caching).

### Running remove-app.sh

```bash
cd sk1
./remove-app.sh            # asks for 'yes' confirmation
```

Deletes the entire Azure resource group and all resources inside it (ACR, storage, container group). Takes 2–3 minutes.

---

## 10. External Resources and AI Model Usage

### Development tools and documentation

| Resource | Type | How used |
|---|---|---|
| [Azure CLI documentation](https://learn.microsoft.com/en-us/cli/azure/) | Official docs | ACI, ACR, storage, resource group CLI commands |
| [Azure Container Instances documentation](https://learn.microsoft.com/en-us/azure/container-instances/) | Official docs | Container group JSON schema, volume types, restart policy |
| [Caddy documentation](https://caddyserver.com/docs/) | Official docs | Automatic HTTPS, reverse proxy config, Caddyfile syntax |
| [Flask documentation](https://flask.palletsprojects.com/) | Official docs | Route definitions, request handling, templates |
| [psycopg2 documentation](https://www.psycopg.org/docs/) | Official docs | PostgreSQL connection and parameterised queries |
| [Bootstrap 5](https://getbootstrap.com/docs/5.3/) | CSS framework | Frontend UI layout and components |
| [marked.js](https://marked.js.org/) | JS library | Markdown rendering for the in-browser README viewer |

### Generative AI

| Tool | Model | Method of use |
|---|---|---|
| **Claude Code** (Anthropic) | Claude Sonnet 4.6 | Used to  iteratively fix all project files: deployment scripts, ACI configuration, Flask application, HTML frontend, and this README. All output was reviewed and understood. Technical decisions (cloud provider selection, ACI vs VM, region availability, volume types) were verified against Azure documentation and tested live. |

