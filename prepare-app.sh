#!/usr/bin/env bash
# prepare-app.sh — Deploy CloudNotes to Azure Container Instances (ACI)
# Requires: az (logged in), python3, openssl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; exit 1; }

for cmd in az python3 openssl; do
    command -v "$cmd" &>/dev/null || die "Required command '$cmd' not found."
done

# ── Load .env ──────────────────────────────────────────────────────────────────
[[ -f .env ]] || die ".env not found. Copy .env.example to .env and fill in your values."
set -a; source .env; set +a

for var in AZURE_RESOURCE_GROUP AZURE_LOCATION AZURE_DNS_LABEL POSTGRES_PASSWORD LETSENCRYPT_EMAIL; do
    [[ -n "${!var:-}" ]] || die "Variable $var is not set in .env"
done

# ── Derived variables ─────────────────────────────────────────────────────────
SAFE=$(echo "$AZURE_DNS_LABEL" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-16)
STORAGE_ACCOUNT="${SAFE}sa"
ACR_NAME="${SAFE}acr"
CONTAINER_GROUP="cloudnotes-group"
DOMAIN="${AZURE_DNS_LABEL}.${AZURE_LOCATION}.azurecontainer.io"
POSTGRES_DB="${POSTGRES_DB:-cloudnotes}"
POSTGRES_USER="${POSTGRES_USER:-cloudnotes_user}"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 32)}"
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"

log "===== CloudNotes ACI Deployment ====="
log "Resource Group : $AZURE_RESOURCE_GROUP"
log "Location       : $AZURE_LOCATION"
log "Domain         : https://$DOMAIN"
log "ACR            : $ACR_NAME"
log "Storage        : $STORAGE_ACCOUNT"
echo ""

az account show --query "user.name" -o tsv &>/dev/null || die "Not logged in. Run: az login"

# ── Register providers ─────────────────────────────────────────────────────────
log "Registering Azure providers..."
for ns in Microsoft.ContainerRegistry Microsoft.Storage Microsoft.ContainerInstance; do
    az provider register --namespace "$ns" --output none 2>/dev/null || true
done

# ── Resource group ─────────────────────────────────────────────────────────────
log "Creating resource group..."
az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" --output none
log "Resource group ready."

# ── Azure Container Registry ──────────────────────────────────────────────────
log "Creating Azure Container Registry ($ACR_NAME)..."
if ! az acr show --name "$ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" &>/dev/null; then
    az acr create \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --location "$AZURE_LOCATION" \
        --sku Basic \
        --admin-enabled true \
        --output none
    log "ACR created."
else
    log "ACR already exists."
fi

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv | tr -d '\r')

# ── Build backend image locally and push to ACR ───────────────────────────────
command -v docker &>/dev/null || die "Docker not found. Install with: curl -fsSL https://get.docker.com | sudo sh"
log "Logging in to ACR..."
ACR_TOKEN=$(az acr login --name "$ACR_NAME" --expose-token --query accessToken -o tsv | tr -d '\r')
echo "$ACR_TOKEN" | docker login "${ACR_LOGIN_SERVER}" \
    --username 00000000-0000-0000-0000-000000000000 \
    --password-stdin
log "Building backend image locally..."
cp README.md backend/README.md
docker build -t "${ACR_LOGIN_SERVER}/cloudnotes-backend:latest" ./backend
rm -f backend/README.md
log "Pushing image to ACR..."
docker push "${ACR_LOGIN_SERVER}/cloudnotes-backend:latest"
log "Image built: ${ACR_LOGIN_SERVER}/cloudnotes-backend:latest"

ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query username -o tsv | tr -d '\r')
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv | tr -d '\r')

# ── Storage account ───────────────────────────────────────────────────────────
log "Creating storage account ($STORAGE_ACCOUNT)..."
if ! az storage account show --name "$STORAGE_ACCOUNT" \
        --resource-group "$AZURE_RESOURCE_GROUP" &>/dev/null; then
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION" \
        --sku Standard_LRS \
        --output none
    log "Storage account created."
else
    log "Storage account already exists."
fi

STORAGE_KEY=$(az storage account keys list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT" \
    --query "[0].value" -o tsv | tr -d '\r')

# ── File shares ───────────────────────────────────────────────────────────────
log "Creating file shares..."
for share in caddy-data caddy-config postgres-data; do
    az storage share create \
        --name "$share" \
        --account-name "$STORAGE_ACCOUNT" \
        --account-key "$STORAGE_KEY" \
        --quota 1 \
        --output none
    log "  Share ready: $share"
done
sleep 3

# ── Upload Caddyfile ──────────────────────────────────────────────────────────
log "Uploading Caddyfile..."
cat > /tmp/Caddyfile << EOF
{
  email ${LETSENCRYPT_EMAIL}
  log {
    output stdout
  }
}

${DOMAIN} {
  log {
    output stdout
  }
  reverse_proxy localhost:5000
}
EOF

az storage file upload \
    --account-name "$STORAGE_ACCOUNT" \
    --share-name caddy-config \
    --source /tmp/Caddyfile \
    --account-key "$STORAGE_KEY" \
    --output none
rm -f /tmp/Caddyfile

# ── Generate ACI JSON config ──────────────────────────────────────────────────
log "Generating ACI configuration..."
export ACR_LOGIN_SERVER ACR_USERNAME ACR_PASSWORD
export STORAGE_ACCOUNT STORAGE_KEY
export POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD SECRET_KEY DATABASE_URL
export DOMAIN AZURE_LOCATION AZURE_DNS_LABEL CONTAINER_GROUP LETSENCRYPT_EMAIL

python3 << 'PYEOF'
import json, os

def e(key): return os.environ[key]

config = {
    "apiVersion": "2021-10-01",
    "name": e("CONTAINER_GROUP"),
    "location": e("AZURE_LOCATION"),
    "properties": {
        "osType": "Linux",
        "restartPolicy": "Always",
        "ipAddress": {
            "type": "Public",
            "dnsNameLabel": e("AZURE_DNS_LABEL"),
            "ports": [
                {"protocol": "TCP", "port": 80},
                {"protocol": "TCP", "port": 443}
            ]
        },
        "imageRegistryCredentials": [{
            "server":   e("ACR_LOGIN_SERVER"),
            "username": e("ACR_USERNAME"),
            "password": e("ACR_PASSWORD")
        }],
        "containers": [
            {
                "name": "caddy",
                "properties": {
                    "image": "caddy:2-alpine",
                    "ports": [{"port": 80}, {"port": 443}],
                    "resources": {"requests": {"cpu": 0.25, "memoryInGB": 0.3}},
                    "volumeMounts": [
                        {"name": "caddy-data",   "mountPath": "/data"},
                        {"name": "caddy-config", "mountPath": "/etc/caddy"}
                    ]
                }
            },
            {
                "name": "backend",
                "properties": {
                    "image": e("ACR_LOGIN_SERVER") + "/cloudnotes-backend:latest",
                    "ports": [{"port": 5000}],
                    "resources": {"requests": {"cpu": 0.5, "memoryInGB": 0.5}},
                    "environmentVariables": [
                        {"name": "DATABASE_URL", "secureValue": e("DATABASE_URL")},
                        {"name": "SECRET_KEY",   "secureValue": e("SECRET_KEY")}
                    ]
                }
            },
            {
                "name": "db",
                "properties": {
                    "image": "postgres:15-alpine",
                    "ports": [{"port": 5432}],
                    "resources": {"requests": {"cpu": 0.25, "memoryInGB": 0.5}},
                    "environmentVariables": [
                        {"name": "POSTGRES_DB",       "value":       e("POSTGRES_DB")},
                        {"name": "POSTGRES_USER",     "value":       e("POSTGRES_USER")},
                        {"name": "POSTGRES_PASSWORD", "secureValue": e("POSTGRES_PASSWORD")},
                        {"name": "PGDATA",            "value":       "/var/lib/postgresql/data/pgdata"}
                    ],
                    "volumeMounts": [
                        {"name": "postgres-data",   "mountPath": "/var/lib/postgresql/data"},
                        {"name": "postgres-backup", "mountPath": "/backup"}
                    ]
                }
            }
        ],
        "volumes": [
            {"name": "caddy-data",     "azureFile": {"shareName": "caddy-data",   "storageAccountName": e("STORAGE_ACCOUNT"), "storageAccountKey": e("STORAGE_KEY")}},
            {"name": "caddy-config",   "azureFile": {"shareName": "caddy-config", "storageAccountName": e("STORAGE_ACCOUNT"), "storageAccountKey": e("STORAGE_KEY")}},
            {"name": "postgres-data",  "emptyDir": {}},
            {"name": "postgres-backup","azureFile": {"shareName": "postgres-data","storageAccountName": e("STORAGE_ACCOUNT"), "storageAccountKey": e("STORAGE_KEY")}}
        ]
    }
}

with open('/tmp/aci-group.json', 'w') as f:
    json.dump(config, f, indent=2)
print("ACI config generated.")
PYEOF

# ── Deploy container group ────────────────────────────────────────────────────
log "Deploying container group (this takes ~2 minutes)..."
az container create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --file /tmp/aci-group.json \
    --output none
rm -f /tmp/aci-group.json

# ── Wait for running state ────────────────────────────────────────────────────
log "Waiting for containers to start..."
for i in $(seq 1 24); do
    STATE=$(az container show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$CONTAINER_GROUP" \
        --query "instanceView.state" -o tsv 2>/dev/null || echo "Pending")
    if [[ "$STATE" == "Running" ]]; then
        log "All containers are running!"
        break
    fi
    echo "  State: $STATE (attempt $i/24)..."
    sleep 10
done

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "===== Deployment Complete ====="
log "URL  : https://$DOMAIN"
log "Note : Caddy obtains the SSL certificate automatically on first request."
log "       Wait up to 2 minutes on the first visit."
echo ""
log "Useful commands:"
log "  Caddy logs  : az container logs -g $AZURE_RESOURCE_GROUP -n $CONTAINER_GROUP --container-name caddy -f"
log "  App logs    : az container logs -g $AZURE_RESOURCE_GROUP -n $CONTAINER_GROUP --container-name backend -f"
log "  Status      : az container show -g $AZURE_RESOURCE_GROUP -n $CONTAINER_GROUP --query instanceView.state"
log "  Backup      : ./backup.sh"
log "  Remove app  : ./remove-app.sh"
echo ""
