#!/usr/bin/env bash
# backup.sh — Back up the CloudNotes PostgreSQL database from ACI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
die() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; exit 1; }

[[ -f .env ]] || die ".env not found."
set -a; source .env; set +a

SAFE=$(echo "$AZURE_DNS_LABEL" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-16)
STORAGE_ACCOUNT="${SAFE}sa"
CONTAINER_GROUP="cloudnotes-group"
POSTGRES_DB="${POSTGRES_DB:-cloudnotes}"
POSTGRES_USER="${POSTGRES_USER:-cloudnotes_user}"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REMOTE_FILE="backup_${TIMESTAMP}.sql"
LOCAL_FILE="${BACKUP_DIR}/cloudnotes_backup_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

log "Starting database backup..."
log "Container group : $CONTAINER_GROUP"
log "Database        : $POSTGRES_DB"
log "Output          : $LOCAL_FILE"

STORAGE_KEY=$(az storage account keys list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT" \
    --query "[0].value" -o tsv)

# ── Dump database into the postgres-data Azure Files share ───────────────────
log "Running pg_dump in container..."
az container exec \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$CONTAINER_GROUP" \
    --container-name db \
    --exec-command "pg_dump -U ${POSTGRES_USER} -d ${POSTGRES_DB} -f /backup/${REMOTE_FILE}"

sleep 3

# ── Download backup file from Azure Files ─────────────────────────────────────
log "Downloading backup from Azure Files..."
az storage file download \
    --account-name "$STORAGE_ACCOUNT" \
    --share-name postgres-data \
    --path "$REMOTE_FILE" \
    --dest /tmp/cloudnotes_backup_raw.sql \
    --account-key "$STORAGE_KEY" \
    --output none

gzip -c /tmp/cloudnotes_backup_raw.sql > "$LOCAL_FILE"
rm -f /tmp/cloudnotes_backup_raw.sql

# ── Remove backup file from the share ────────────────────────────────────────
az storage file delete \
    --account-name "$STORAGE_ACCOUNT" \
    --share-name postgres-data \
    --path "$REMOTE_FILE" \
    --account-key "$STORAGE_KEY" \
    --output none

log "Backup saved : $LOCAL_FILE"
log "Size         : $(du -sh "$LOCAL_FILE" | cut -f1)"
echo ""
log "To restore this backup:"
log "  gunzip -c $LOCAL_FILE > /tmp/restore.sql"
log "  az storage file upload --account-name $STORAGE_ACCOUNT --share-name postgres-data \\"
log "    --source /tmp/restore.sql --path restore.sql --account-key <key>"
log "  az container exec -g $AZURE_RESOURCE_GROUP -n $CONTAINER_GROUP --container-name db \\"
log "    --exec-command 'psql -U $POSTGRES_USER -d $POSTGRES_DB -f /var/lib/postgresql/data/restore.sql'"
