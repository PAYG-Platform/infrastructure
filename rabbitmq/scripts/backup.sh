#!/bin/bash
set -eo pipefail

# ==============================================================================
# RABBITMQ AUTOMATED DEFINITION & SCHEMA BACKUP SCRIPT
# ==============================================================================
# Exports all vhosts, users, permissions, queues, exchanges, bindings, and
# policies without taking the broker offline or disrupting live messages.
# ==============================================================================

# Script directory resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Timestamp and backup directory setup
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="${BACKUP_DIR:-$BASE_DIR/backups}"
mkdir -p "$BACKUP_DIR"

RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Auto-detect container name (supports unified and standalone deployments)
CONTAINER_NAME="${RABBITMQ_CONTAINER:-}"

if [ -z "$CONTAINER_NAME" ]; then
    if docker ps --format '{{.Names}}' | grep -q "^shared-rabbitmq$"; then
        CONTAINER_NAME="shared-rabbitmq"
    elif docker ps --format '{{.Names}}' | grep -q "^standalone-rabbitmq$"; then
        CONTAINER_NAME="standalone-rabbitmq"
    else
        CONTAINER_NAME="shared-rabbitmq"
    fi
fi

echo "=========================================================="
echo "📦 RabbitMQ Backup Routine"
echo "🎯 Container: $CONTAINER_NAME"
echo "📅 Timestamp: $TIMESTAMP"
echo "📂 Target Directory: $BACKUP_DIR"
echo "=========================================================="

# 1. Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ ERROR: Container '$CONTAINER_NAME' is not running. Backup aborted."
    exit 1
fi

# 2. Check broker health
if ! docker exec "$CONTAINER_NAME" rabbitmq-diagnostics -q ping >/dev/null 2>&1; do
    echo "❌ ERROR: RabbitMQ broker node is unresponsive. Backup aborted."
    exit 1
fi

TEMP_CONTAINER_PATH="/tmp/definitions_${TIMESTAMP}.json"
HOST_BACKUP_FILE="${BACKUP_DIR}/rabbitmq_definitions_${TIMESTAMP}.json"

# 3. Export definitions inside container
echo "⏳ Exporting broker schemas, queues, and policies..."
docker exec "$CONTAINER_NAME" rabbitmqctl export_definitions "$TEMP_CONTAINER_PATH" >/dev/null

# 4. Copy export to host system
echo "📥 Transferring definition export to host..."
docker cp "${CONTAINER_NAME}:${TEMP_CONTAINER_PATH}" "$HOST_BACKUP_FILE"

# Clean up temporary file inside the container
docker exec "$CONTAINER_NAME" rm -f "$TEMP_CONTAINER_PATH"

# 5. Validate file exists and is non-empty
if [ ! -s "$HOST_BACKUP_FILE" ]; then
    echo "❌ ERROR: Exported definition file is empty or missing!"
    rm -f "$HOST_BACKUP_FILE"
    exit 1
fi

# 6. Compress export using gzip
echo "🗜️  Compressing backup archive with gzip..."
gzip -f "$HOST_BACKUP_FILE"
COMPRESSED_FILE="${HOST_BACKUP_FILE}.gz"

FILE_SIZE=$(du -h "$COMPRESSED_FILE" | cut -f1)
echo "✅ Successfully created backup: $(basename "$COMPRESSED_FILE") ($FILE_SIZE)"

# 7. Prune backups older than retention window
echo "🧹 Pruning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -name "rabbitmq_definitions_*.json.gz" -mtime +"$RETENTION_DAYS" -exec rm -f {} + || true

echo "=========================================================="
echo "✨ RabbitMQ backup completed successfully!"
echo "   Archive: $COMPRESSED_FILE"
echo "=========================================================="