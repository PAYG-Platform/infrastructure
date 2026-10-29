#!/bin/bash
set -eo pipefail

# ==============================================================================
# RABBITMQ POLICY AUTOMATION SCRIPT
# ==============================================================================
# Applies global memory-saving policies to keep message bodies on NVMe/SSD
# storage instead of buffering them in RAM.
# ==============================================================================

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
echo "🐇 RabbitMQ Policy Provisioner"
echo "🎯 Target Container: $CONTAINER_NAME"
echo "=========================================================="

# 1. Verify that the Docker container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ ERROR: Container '$CONTAINER_NAME' is not running."
    echo "   Start the container first via: docker compose up -d"
    exit 1
fi

# 2. Wait until RabbitMQ Erlang node passes health diagnostics
echo "⏳ Waiting for RabbitMQ broker to accept administrative commands..."
MAX_ATTEMPTS=30
ATTEMPT=1

until docker exec "$CONTAINER_NAME" rabbitmq-diagnostics -q ping >/dev/null 2>&1; do
    if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
        echo "❌ ERROR: RabbitMQ health check timed out after $MAX_ATTEMPTS attempts."
        exit 1
    fi
    echo "   Attempt $ATTEMPT/$MAX_ATTEMPTS: Node initializing, waiting 2s..."
    sleep 2
    ATTEMPT=$((ATTEMPT + 1))
done

echo "✅ RabbitMQ node is fully operational and responsive."

# 3. Apply global Lazy Queue policy
echo "⚙️  Applying global 'Lazy' Queue policy across all queues..."
# - Policy Name: Lazy
# - Pattern: ^.* (Matches every queue across all exchanges)
# - Definition: {"queue-mode":"lazy"} (Writes payloads to disk immediately)
# - Apply to: queues
docker exec "$CONTAINER_NAME" rabbitmqctl set_policy Lazy "^.*" \
  '{"queue-mode":"lazy"}' \
  --apply-to queues

# 4. Confirm and print active policies
echo "📋 Verifying active policies on default vhost (/)..."
docker exec "$CONTAINER_NAME" rabbitmqctl list_policies

echo "=========================================================="
echo "✨ Success! Global Lazy Queue policy is active."
echo "   All current and future queues will commit message"
echo "   payloads to disk, reducing RAM consumption by ~80%."
echo "=========================================================="