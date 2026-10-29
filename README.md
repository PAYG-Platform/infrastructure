# Shared Infrastructure — Cloud RabbitMQ & Redis Tier

<p align="left">
  <img src="https://img.shields.io/badge/Docker_Compose-v2.20+-2496ED?style=flat-square&logo=docker&logoColor=white" alt="Docker Compose" />
  <img src="https://img.shields.io/badge/RabbitMQ-3.13_Alpine-FF6600?style=flat-square&logo=rabbitmq&logoColor=white" alt="RabbitMQ" />
  <img src="https://img.shields.io/badge/Redis-7_Alpine-DC382D?style=flat-square&logo=redis&logoColor=white" alt="Redis" />
  <img src="https://img.shields.io/badge/Protocols-AMQPS_%26_Rediss_(TLS)-009688?style=flat-square" alt="Protocols" />
  <img src="https://img.shields.io/badge/Architecture-Bounded_Memory_(100--250MB)-4EBA6F?style=flat-square" alt="Memory Architecture" />
</p>

This repository hosts the dedicated, high-efficiency **RabbitMQ message broker** and **Redis cache/FSM state tier**. It provides a self-hosted, cloud-like messaging and state backbone for distributed microservices with native **TLS/SSL encryption (`amqps://` & `rediss://`)** and strict **bounded memory engineering** (stable ~100MB–250MB footprint).

---

## 📑 Table of Contents

- [Architectural Topology](#-architectural-topology)
- [Repository Structure](#-repository-structure)
- [Quick Start: Single-Server Deployment](#-quick-start-single-server-deployment)
- [Dual-Server Deployment (Dedicated VPS Nodes)](#-dual-server-deployment-dedicated-vps-nodes)
- [Enabling Native SSL/TLS Encryption (AMQPS & Rediss)](#-enabling-native-ssltls-encryption-amqps--rediss)
- [Connecting External Microservices](#-connecting-external-microservices)
- [Memory Engineering & Optimization Overview](#-memory-engineering--optimization-overview)
- [Security, Firewall & Access Control](#-security-firewall--access-control)
- [Diagnostic & Maintenance Runbook](#-diagnostic--maintenance-runbook)
- [Documentation Directory](#-documentation-directory)

---

## 🏛️ Architectural Topology

```
[ Microservice VPS 1 ]      [ Microservice VPS 2 ]      [ Microservice VPS 3 ]
   (e.g., IAM Service)        (e.g., Billing Service)     (e.g., Node Fleet)
            │                            │                            │
            │ TLS Encrypted              │ TLS Encrypted              │ TLS Encrypted
            │ AMQPS :5671                │ AMQPS :5671 & Rediss :6379 │ AMQPS :5671
            ▼                            ▼                            ▼
══════════════════════════════════════════════════════════════════════════════════
               Dedicated Shared Infrastructure Node (This Server)
══════════════════════════════════════════════════════════════════════════════════
 ┌─────────────────────────────────────────┐  ┌─────────────────────────────────┐
 │       RabbitMQ Broker (:5672/:5671)     │  │       Shared Redis (:6379)      │
 │                                         │  │                                 │
 │  • Capped at 384MB Memory Watermark     │  │  • Hard-Capped at 256MB RAM     │
 │  • 50% Aggressive Disk Paging Ratio     │  │  • Allkeys-LRU Automatic Eviction│
 │  • Basic Metrics Throttling Mode        │  │  • AOF Durability (everysec)    │
 │  • Global Lazy Disk-Backed Queues       │  │  • Native TLS Socket Encryption │
 │  • Loopback Management UI (:15672)      │  │  • High-Entropy Password Guard  │
 └─────────────────────────────────────────┘  └─────────────────────────────────┘
```

---

## 📁 Repository Structure

```text
infrastructure/
├── docker-compose.yml             # Master Compose (Run both together on 1 server)
├── .env.example                   # Master environment variable template
├── .gitignore                     # Ignores data/, dumps, and local secrets
├── README.md                      # This master operations guide
│
├── rabbitmq/                      # 🐇 Dedicated RabbitMQ Subsystem
│   ├── docker-compose.yml         # Standalone Compose (For dedicated RabbitMQ host)
│   ├── config/
│   │   └── rabbitmq.conf          # Low-memory profile, 384MB watermark, TLS listeners
│   ├── scripts/
│   │   ├── apply-policies.sh      # Applies global 'lazy' disk-backed queue policy
│   │   ├── backup.sh              # Exports schema and definition JSON
│   │   └── gc.sh                  # On-demand Erlang VM memory garbage collection
│   ├── data/                      # Persistent Mnesia message store (gitignored)
│   └── DETAIL.md                  # RabbitMQ operations runbook
│
├── redis/                         # ⚡ Dedicated Redis Subsystem
│   ├── docker-compose.yml         # Standalone Compose (For dedicated Redis host)
│   ├── config/
│   │   └── redis.conf             # 256MB maxmemory, allkeys-lru, AOF persistence
│   ├── scripts/
│   │   ├── backup.sh              # Non-blocking BGSAVE & AOF snapshotting
│   │   └── memory-audit.sh        # Scans dataset for big keys and fragmentation
│   ├── data/                      # Persistent RDB/AOF data (gitignored)
│   └── DETAIL.md                  # Redis operations runbook
│
├── certs/                         # 🔐 TLS/SSL Certificates Directory (gitignored)
│   ├── ca.crt                     # Root Certificate Authority
│   ├── rabbitmq/                  # RabbitMQ server certs (server.crt, server.key)
│   └── redis/                     # Redis server certs (server.crt, server.key)
│
├── scripts/                       # 🛠️ Master Cluster Automation
│   ├── bootstrap.sh               # 1-Click setup, permissions, and directory init
│   ├── generate-certs.sh          # Generates Root CA & Server TLS Certificates
│   └── healthcheck-all.sh         # Probes both services over TCP/TLS
│
└── documentations/                # 📚 Permanent Architectural Reference Manuals
    ├── RABBITMQ_ARCHITECTURE_AND_OPTIMIZATION.md
    └── REDIS_ARCHITECTURE_AND_OPTIMIZATION.md
```

---

## 🚀 Quick Start: Single-Server Deployment

Use this mode to run both **RabbitMQ** and **Redis** co-located on a single host (e.g., a $4–$6/month VPS).

### 1. Setup Environment
```bash
# Clone the repository
git clone https://github.com/PAYG-Platform/infrastructure.git /opt/payg-mng/infrastructure
cd /opt/payg-mng/infrastructure

# Copy environment variables template
cp .env.example .env

# Configure passwords in .env
nano .env
```

### 2. Generate TLS Certificates (Optional but Recommended)
```bash
chmod +x scripts/*.sh rabbitmq/scripts/*.sh redis/scripts/*.sh
./scripts/generate-certs.sh
```

### 3. Bootstrap and Launch Stack
```bash
./scripts/bootstrap.sh
```

*The bootstrap script initializes storage directories, pulls container images, starts the stack, and automatically applies the global **Lazy Queue** memory policy.*

---

## 🌐 Dual-Server Deployment (Dedicated VPS Nodes)

If deploying RabbitMQ and Redis on physically separated servers:

### On Server A (Dedicated RabbitMQ Node):
```bash
cd /opt/payg-mng/infrastructure/rabbitmq
cp ../.env.example .env
nano .env

# Launch standalone RabbitMQ
docker compose up -d
./scripts/apply-policies.sh
```

### On Server B (Dedicated Redis Node):
```bash
cd /opt/payg-mng/infrastructure/redis
cp ../.env.example .env
nano .env

# Launch standalone Redis
docker compose up -d
```

---

## 🔒 Enabling Native SSL/TLS Encryption (AMQPS & Rediss)

To encrypt inter-service traffic over the public internet without a VPN/WireGuard mesh:

### 1. Generate Certificates
Run the automated CA and server certificate generator:
```bash
./scripts/generate-certs.sh
```
This generates:
* `certs/ca.crt`: Root CA certificate.
* `certs/rabbitmq/server.{crt,key}`: RabbitMQ server certificate pair.
* `certs/redis/server.{crt,key}`: Redis server certificate pair.

### 2. Start Encrypted Infrastructure
```bash
docker compose up -d
./rabbitmq/scripts/apply-policies.sh
```

### 3. Encrypted Endpoints
* **RabbitMQ AMQPS (TLS):** `port 5671`
* **RabbitMQ AMQP (Plaintext):** `port 5672`
* **Redis Rediss (TLS):** `port 6379`

---

## 🔌 Connecting External Microservices

In your microservices' configuration (`.env` files in `core-services`), set the connection URLs to point to your infrastructure node:

### Option A: Encrypted TLS Connection (Recommended for Cloud/WAN)
```env
# 🔒 RabbitMQ Encrypted Protocol (Port 5671)
RABBITMQ_URL=amqps://admin:<RMQ_PASSWORD>@<INFRA_SERVER_IP>:5671/

# 🔒 Redis Encrypted Protocol (Port 6379)
REDIS_URL=rediss://:<REDIS_PASSWORD>@<INFRA_SERVER_IP>:6379/0
```

### Option B: Plaintext Connection (For Private WireGuard Mesh / VPC)
```env
# RabbitMQ Plaintext Protocol (Port 5672)
RABBITMQ_URL=amqp://admin:<RMQ_PASSWORD>@<INFRA_SERVER_IP>:5672/

# Redis Plaintext Protocol (Port 6379)
REDIS_URL=redis://:<REDIS_PASSWORD>@<INFRA_SERVER_IP>:6379/0
```

---

## 🧠 Memory Engineering & Optimization Overview

Default RabbitMQ and Redis setups often consume multiple gigabytes of memory. This repository enforces strict architectural limits to maintain a **100 MB – 250 MB** steady-state footprint:

| Component | Default Risk | Bounded Optimization Strategy | Operational Result |
| :--- | :--- | :--- | :--- |
| **RabbitMQ Watermark** | Claims host RAM | `vm_memory_high_watermark.absolute = 384MB` | Hard memory ceiling regardless of VPS size |
| **RabbitMQ Paging** | Pages only under high load | `vm_memory_high_watermark_paging_ratio = 0.5` | Begins paging payloads to disk at 192 MB |
| **RabbitMQ Metrics** | ETS tables grow indefinitely | `management.rates_mode = basic`<br>`collect_statistics_interval = 30000` | Prevents metrics memory leaks in management database |
| **RabbitMQ Queues** | Stores messages in RAM | Global **Lazy Policy** (`queue-mode: lazy`) | Payloads committed to disk; RAM holds pointers only (~80% savings) |
| **Redis Memory** | Unbounded growth / OOM | `maxmemory 256mb`<br>`maxmemory-policy allkeys-lru` | Automatically evicts stale keys when saturated |
| **Docker cgroups** | Uncontrolled host usage | Hard kernel limits: `512M` (RMQ), `384M` (Redis) | Protects host operating system from OOM kills |

---

## 🛡️ Security, Firewall & Access Control

### 1. Host UFW Firewall Hardening
Never expose database or messaging ports openly to `0.0.0.0`. Allow ingress traffic **only from your authorized microservice server IPs**:

```bash
# Set strict default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp

# Allow microservice servers to access RabbitMQ (Plaintext 5672 or TLS 5671)
sudo ufw allow from <IAM_SERVER_IP> to any port 5671 proto tcp
sudo ufw allow from <BILLING_SERVER_IP> to any port 5671 proto tcp
sudo ufw allow from <NODE_SERVER_IP> to any port 5671 proto tcp
sudo ufw allow from <TRAFFIC_SERVER_IP> to any port 5671 proto tcp
sudo ufw allow from <TELEGRAM_SERVER_IP> to any port 5671 proto tcp

# Allow microservice servers to access Redis (6379)
sudo ufw allow from <BILLING_SERVER_IP> to any port 6379 proto tcp
sudo ufw allow from <TELEGRAM_SERVER_IP> to any port 6379 proto tcp

# Enable firewall
sudo ufw enable
```

### 2. Secure Web Management Dashboard Access
The RabbitMQ Management Web UI (`15672`) is bound strictly to `127.0.0.1` and is **never exposed publicly**.

To access the dashboard, establish an encrypted SSH tunnel from your local machine:
```bash
ssh -N -L 15672:127.0.0.1:15672 root@<INFRA_SERVER_IP>
```
Then navigate to **`http://localhost:15672`** in your browser (Login: `$RMQ_USER` / `$RMQ_PASSWORD`).

---

## 🩺 Diagnostic & Maintenance Runbook

```bash
# 1. Check live memory consumption of infrastructure containers
docker stats --no-stream

# 2. Audit RabbitMQ queues for accumulation or missing consumers
docker exec -it shared-rabbitmq rabbitmqctl list_queues name messages consumers memory

# 3. Force on-demand Erlang runtime garbage collection (Reclaims free memory)
docker exec -it shared-rabbitmq rabbitmqctl eval 'erlang:garbage_collect().'

# 4. Inspect Redis memory fragmentation and key metrics
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" INFO memory

# 5. Scan Redis for large memory-hogging keys
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" --bigkeys

# 6. Trigger non-blocking Redis background snapshot to disk
docker exec -it shared-redis redis-cli -a "$REDIS_PASSWORD" BGSAVE

# 7. Backup RabbitMQ schemas, users, and queue definitions to JSON
docker exec shared-rabbitmq rabbitmqctl export_definitions /var/lib/rabbitmq/backup_definitions.json
```

---

## 📚 Detailed Documentation

* [🐇 **RabbitMQ Architecture, Deployment & Memory Optimization Manual**](./documentations/RABBITMQ_ARCHITECTURE_AND_OPTIMIZATION.md)
* [⚡ **Redis Architecture, Deployment & Eviction Management Manual**](./documentations/REDIS_ARCHITECTURE_AND_OPTIMIZATION.md)