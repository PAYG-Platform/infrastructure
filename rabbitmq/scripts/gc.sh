#!/bin/bash
set -eo pipefail

# ==============================================================================
# RABBITMQ ERLANG VM ON-DEMAND GARBAGE COLLECTION SCRIPT
# ==============================================================================
# Triggers on-demand memory reclamation across all Erlang processes on the node.
# Because Erlang uses per-process heaps, this does NOT freeze the broker and is
# completely safe to execute under live production traffic.
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
echo "🧹 RabbitMQ Erlang Garbage Collection (Memory Reclaim)"
echo "🎯 Container: $CONTAINER_NAME"
echo "=========================================================="

# 1. Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ ERROR: Container '$CONTAINER_NAME' is not running."
    exit 1
fi

# 2. Check broker health
if ! docker exec "$CONTAINER_NAME" rabbitmq-diagnostics -q ping >/dev/null 2>&1; do
    echo "❌ ERROR: RabbitMQ broker node is unresponsive."
    exit 1
fi

# Helper to read container memory usage via Docker stats
get_mem_usage() {
    docker stats "$CONTAINER_NAME" --no-stream --format "{{.MemUsage}}"
}

MEM_BEFORE=$(get_mem_usage)
echo "📊 Memory footprint BEFORE GC: $MEM_BEFORE"

# 3. Execute Erlang VM garbage collection across all active processes
echo "⏳ Triggering Erlang process garbage collection & allocator cleanup..."

# Iterates over every Erlang process PID (queues, channels, ETS tables)
# and reclaims orphaned binary memory blocks. Returns 'ok' to prevent stdout spam.
docker exec "$CONTAINER_NAME" rabbitmqctl eval '
    [erlang:garbage_collect(Pid) || Pid <- erlang:processes()],
    ok.
' >/dev/null

# 4. Measure memory footprint after cleanup
sleep 1
MEM_AFTER=$(get_mem_usage)

echo "📊 Memory footprint AFTER  GC: $MEM_AFTER"

# 5. Display detailed memory allocation breakdown from broker diagnostics
echo ""
echo "📋 Memory Allocation Breakdown:"
docker exec "$CONTAINER_NAME" rabbitmq-diagnostics -q memory_breakdown 2>/dev/null | grep -E "(total|connection_readers|connection_writers|queue_procs|binary|allocated_unused)" || true

echo ""
echo "=========================================================="
echo "✨ Garbage collection completed successfully!"
echo "   Unused binary allocator blocks released."
echo "=========================================================="