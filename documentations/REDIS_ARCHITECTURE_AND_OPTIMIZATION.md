# Production Redis Architecture, Cloud Deployment & Memory Management Guide
**Standard:** Enterprise In-Memory Data Store & Cache Specification  
**Classification:** DevOps / Systems Engineering Reference Manual

---

## 📑 Table of Contents
1. [Architectural Overview & Distributed Workload Archetypes](#1-architectural-overview--distributed-workload-archetypes)
2. [Redis Memory Architecture & Eviction Policies](#2-redis-memory-architecture--eviction-policies)
3. [Production `redis.conf` Specification](#3-production-redisconf-specification)
4. [Client Implementation Rules: The Async Event-Loop Trap](#4-client-implementation-rules-the-async-event-loop-trap)
5. [Docker Compose & Linux cgroups Deployment](#5-docker-compose--linux-cgroups-deployment)
6. [Security, Passwords & Access Control](#6-security-passwords--access-control)
7. [Operational Diagnostic & Maintenance Runbook](#7-operational-diagnostic--maintenance-runbook)

---

## 1. Architectural Overview & Distributed Workload Archetypes

Redis operates as an ultra-low-latency in-memory data structure store. In a modern distributed architecture, it fulfills three distinct roles:

```
                          [ API Gateway / Load Balancer ]
                                        │
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
     [ Microservice A ]         [ Microservice B ]         [ Microservice C ]
             │                          │                          │
             │ Rate-Limit Counters      │ Ephemeral Session State  │ Cache Queries
             ▼                          ▼                          ▼
     ════════════════════════════════════════════════════════════════════════
                     Central Standalone Cloud Redis Node
     ════════════════════════════════════════════════════════════════════════
       • Memory Hard-Capped: 256 MB         • Eviction: allkeys-lru
       • Non-Blocking Async Connections    • Durable Persistence: AOF everysec
     ────────────────────────────────────────────────────────────────────────
```

1. **Distributed Sliding-Window Rate Limiting:** Tracking real-time request counts across multiple gateway or microservice instances using atomic Lua scripts.
2. **State Machines & Session Storage:** Managing transient state (wizard flows, verification codes, deep links) with explicit TTL expirations.
3. **Data Cache:** Reducing read pressure on relational databases (PostgreSQL/MySQL).

---

## 2. Redis Memory Architecture & Eviction Policies

Because Redis stores all dataset structures directly in physical RAM, an unconstrained Redis instance will eventually consume all host memory, triggering the Linux kernel's Out-Of-Memory (OOM) killer.

### 2.1 The Two Critical Memory Metrics
* **`used_memory`:** Actual bytes allocated by Redis for data structures and keys.
* **`used_memory_rss`:** Resident Set Size—the actual memory allocated by the operating system to the Redis process.
* **Memory Fragmentation Ratio:**  
  $$\text{mem\_fragmentation\_ratio} = \frac{\text{used\_memory\_rss}}{\text{used\_memory}}$$
  * Ratio $> 1.5$: Indicates high memory fragmentation (memory allocated by OS but unused by Redis).
  * Ratio $< 1.0$: Indicates Redis has been swapped to disk (catastrophic performance degradation).

### 2.2 Selecting the Correct Eviction Policy (`maxmemory-policy`)
When `used_memory` reaches `maxmemory`, Redis must be instructed how to behave:

| Policy | Mechanism | Ideal Use Case |
| :--- | :--- | :--- |
| **`noeviction`** *(Default)* | Returns errors on write operations when memory is full | Strict transactional data where drops are unacceptable |
| **`allkeys-lru`** *(Recommended)* | Evicts least-recently-used keys regardless of TTL | Shared caching, rate limiters, session stores |
| **`volatile-lru`** | Evicts least-recently-used keys *only among those with an expire (TTL) set* | Mixed store where permanent data and cache coexist |
| **`allkeys-lfu`** | Evicts least-frequently-used keys (frequency counter) | Workloads with clear hot/cold data distributions |
| **`volatile-ttl`** | Evicts keys with the shortest remaining TTL | Priority queue caching |

---

## 3. Production `redis.conf` Specification

Place this configuration file at `/usr/local/etc/redis/redis.conf` on your Redis server:

```ini
# ==============================================================================
# REDIS PRODUCTION OPTIMIZED & BOUNDED-MEMORY PROFILE
# ==============================================================================

# 1. NETWORK & CONNECTION LIFECYCLE
bind 0.0.0.0
protected-mode yes
port 6379
tcp-backlog 511
timeout 300
tcp-keepalive 60

# 2. HARD MEMORY LIMITS & EVICTION
# Set hard ceiling (e.g. 256MB on a 1GB VPS; adjust to 512MB or 1GB for larger tiers)
maxmemory 256mb

# Automatically evict least-recently-used keys when maxmemory is saturated
maxmemory-policy allkeys-lru
maxmemory-samples 5

# Active defragmentation (reclaims fragmented RAM dynamically)
activedefrag yes
active-defrag-ignore-bytes 50mb
active-defrag-threshold-lower 10
active-defrag-threshold-upper 30

# 3. DURABLE PERSISTENCE (AOF Engine)
# Retain data between restarts without memory bloat
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite yes
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb

# 4. SNAPSHOTTING (RDB Engine)
# Fallback backup snapshot
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /data
```

---

## 4. Client Implementation Rules: The Async Event-Loop Trap

### ⚠️ Critical Anti-Pattern: Synchronous Redis in Asynchronous Frameworks
When building with asynchronous frameworks (FastAPI, Starlette, Node.js, aiohttp), **never use a synchronous Redis driver** in middleware or route handlers.

```python
# ❌ CATASTROPHIC ANTI-PATTERN (Blocks the entire server event loop):
import redis

client = redis.Redis.from_url("redis://remote-host:6379/0")

async def rate_limit_middleware(request: Request, call_next):
    # This synchronous call blocks the main Python thread for 30ms-100ms over WAN!
    client.incr("counter_key") 
    return await call_next(request)
```

```python
# ✅ PRODUCTION-GRADE NON-BLOCKING PATTERN:
import redis.asyncio as aioredis

pool = aioredis.ConnectionPool.from_url(
    "redis://:password@remote-host:6379/0",
    max_connections=20,
    decode_responses=True
)
redis_client = aioredis.Redis(connection_pool=pool)

async def rate_limit_middleware(request: Request, call_next):
    # Yields execution back to the event loop while waiting for network I/O
    await redis_client.incr("counter_key")
    return await call_next(request)
```

---

## 5. Docker Compose & Linux cgroups Deployment

### `docker-compose.yml`
```yaml
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    container_name: shared-redis
    restart: always
    command: >
      redis-server /usr/local/etc/redis/redis.conf
      --requirepass ${REDIS_PASSWORD}
    ports:
      # Redis Port (Bound to host interface or private mesh)
      - "${BIND_IP:-0.0.0.0}:6379:6379"
    volumes:
      - ./data/redis:/data
      - ./config/redis.conf:/usr/local/etc/redis/redis.conf:ro
    # Linux Kernel Cgroup Hard Limit (Must be higher than maxmemory in redis.conf)
    deploy:
      resources:
        limits:
          memory: 384M
        reservations:
          memory: 64M
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s
```

---

## 6. Security, Passwords & Access Control

### 6.1 Authentication (`requirepass`)
Always require a cryptographically random password (32+ characters). Redis can evaluate over 150,000 passwords per second; short passwords can be brute-forced easily:
```bash
# Generate a 32-character high-entropy password
openssl rand -hex 24
```

### 6.2 Disabling Dangerous Administrative Commands
In `config/redis.conf`, rename or disable dangerous commands that malicious actors or accidental queries can use to wipe data or exhaust the CPU:

```ini
# Disable commands that can crash production
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command KEYS ""
rename-command DEBUG ""
rename-command CONFIG "CONFIG_ADMIN_SECRET_CMD"
```

### 6.3 Host Firewall Restriction
```bash
# Grant access strictly from trusted microservice IPs
sudo ufw allow from <SERVICE_A_IP> to any port 6379 proto tcp
sudo ufw allow from <SERVICE_B_IP> to any port 6379 proto tcp
sudo ufw enable
```

---

## 7. Operational Diagnostic & Maintenance Runbook

### 7.1 Inspect Live Memory Allocation & Fragmentation
```bash
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" INFO memory
```
Key metrics to review:
* `used_memory_human`: Target should remain $\le$ `maxmemory`.
* `mem_fragmentation_ratio`: Target is between `1.0` and `1.3`.
* `evicted_keys`: Number of keys purged due to memory saturation.

### 7.2 Find Memory-Hogging Keys (BigKeys Audit)
Scan the dataset to identify large structures without blocking execution:
```bash
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" --bigkeys
```

### 7.3 Trigger Manual Disk Snapshot
Force a non-blocking background write of the dataset to disk:
```bash
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" BGSAVE
```

### 7.4 Monitor Real-Time Latency Spikes
```bash
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" --latency-history
```