#!/usr/bin/env bash
# remove-app.sh — Remove CloudNotes and all Azure resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; exit 1; }

[[ -f .env ]] || die ".env not found."
set -a; source .env; set +a

log "===== CloudNotes Removal ====="
log "Resource Group : $AZURE_RESOURCE_GROUP"
echo ""
warn "This will permanently delete ALL resources in the resource group:"
warn "  - Container group (Caddy + Flask + PostgreSQL)"
warn "  - Azure Container Registry and built images"
warn "  - Storage account and all file shares (database data)"
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { log "Aborted."; exit 0; }

az account show &>/dev/null || die "Not logged in. Run: az login"

log "Deleting resource group '$AZURE_RESOURCE_GROUP'..."
log "(This may take 2-3 minutes...)"
az group delete --name "$AZURE_RESOURCE_GROUP" --yes

log "Done. All CloudNotes resources have been deleted."
