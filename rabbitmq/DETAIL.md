# RabbitMQ Subsystem — Standalone Architecture & Operations Runbook

<p align="left">
  <img src="https://img.shields.io/badge/Subsystem-RabbitMQ_Broker-FF6600?style=flat-square&logo=rabbitmq&logoColor=white" alt="RabbitMQ" />
  <img src="https://img.shields.io/badge/Container-3.13_Management_Alpine-black?style=flat-square&logo=docker" alt="Docker" />
  <img src="https://img.shields.io/badge/Protocols-AMQP_(5672)_%7C_AMQPS_(5671)-009688?style=flat-square" alt="Protocols" />
  <img src="https://img.shields.io/badge/Memory_Baseline-100MB--220MB-4EBA6F?style=flat-square" alt="Memory" />
</p>

This subsystem operates as the dedicated, high-efficiency asynchronous message broker tier. It can be deployed as an isolated standalone node on a dedicated VPS or alongside Redis via the root infrastructure compose file.

It features **dual-listener encryption (AMQP/AMQPS)**, **384MB hard memory limits**, and **NVMe-backed Lazy Queues** to prevent default Erlang VM memory bloat.

---

## 📑 Table of Contents
1. [Directory Layout](#1-directory-layout)
2. [Standalone Host Deployment](#2-standalone-host-deployment)
3. [Memory Engineering & `rabbitmq.conf` Architecture](#3-memory-engineering--rabbitmqconf-architecture)
4. [The Operations Scripts Guide](#4-the-operations-scripts-guide)
   - [4.1 `scripts/apply-policies.sh` (Lazy Queue Policy)](#41-scriptsapply-policiessh-lazy-queue-policy)
   - [4.2 `scripts/backup.sh` (Definition & Schema Snapshot)](#42-scriptsbackupsh-definition--schema-snapshot)
   - [4.3 `scripts/gc.sh` (On-Demand Erlang Memory Reclaim)](#43-scriptsgcsh-on-demand-erlang-memory-reclaim)
5. [Enabling Native AMQPS (TLS/SSL on Port 5671)](#5-enabling-native-amqps-tlsssl-on-port-5671)
6. [Queue Auditing & Troubleshooting Alarms](#6-queue-auditing--troubleshooting-alarms)
7. [CLI Operations Quick Reference](#7-cli-operations-quick-reference)

---

## 1. Directory Layout

When running on a dedicated host (e.g., `/opt/payg-mng/infrastructure/rabbitmq`), the isolated layout is structured as follows:

```text
infrastructure/rabbitmq/
├── docker-compose.yml       # Standalone compose for this host only
├── .env.example             # Credential template for this service
├── .env                     # Local credentials (gitignored)
├── DETAIL.md                # This comprehensive operations guide
├── config/
│   └── rabbitmq.conf        # Production low-memory & TLS listener configuration
├── scripts/
│   ├── apply-policies.sh    # Waits for broker ready & enforces disk-backed lazy queues
│   ├── backup.sh            # Gzip-compressed export of definitions and users
│   └── gc.sh                # Non-blocking per-process Erlang garbage collection
├── certs/                   # (Optional) TLS certificates for port 5671
│   ├── ca.crt
│   ├── server.crt
│   └── server.key
└── data/                    # Persistent Mnesia node database (gitignored)
```

---

## 2. Standalone Host Deployment

Use this procedure if you deploy RabbitMQ on its own isolated server.

### Step 1: Initialize Local Environment
```bash
cd /opt/payg-mng/infrastructure/rabbitmq

# Copy template
cp .env.example .env

# Set secure credentials
nano .env
```
Ensure you provide a strong 32+ character string for `RMQ_PASSWORD`.

### Step 2: Set Directory Permissions
RabbitMQ runs as internal container user `rabbitmq` (UID `999`):
```bash
mkdir -p data backups
chmod 777 data backups
chmod +x scripts/*.sh
```

### Step 3: Launch Standalone Broker
```bash
docker compose up -d
```

### Step 4: Apply Bounded-Memory Policies
```bash
./scripts/apply-policies.sh
```

---

## 3. Memory Engineering & `rabbitmq.conf` Architecture

Unconfigured RabbitMQ nodes commonly consume 1 GB to 2.5 GB of RAM due to four defaults:
1. **Host-Proportional High Watermark (0.4):** Claims 40% of host RAM before activating memory flow control [1].
2. **Management Plugin ETS Table Bloat:** Collects fine-grained message rates every 5 seconds, filling in-memory ETS tables indefinitely [2, 3].
3. **Erlang Binary Allocator Retention:** Erlang's memory allocators do not return freed binary chunks to the Linux kernel immediately [1].
4. **Classic RAM Queue Buffering:** Message bodies remain in memory until forced to disk under heavy RAM alarms [4].

### How `config/rabbitmq.conf` Solves This:
```ini
# 1. HARD CEILING: Fixes RAM cap strictly at 384 MB regardless of host RAM
vm_memory_high_watermark.absolute = 384MB

# 2. EARLY DISK PAGING: Forces payloads to disk at 50% of watermark (192 MB)
vm_memory_high_watermark_paging_ratio = 0.5

# 3. STATS INGESTION THROTTLING: Disables granular per-message charts in Web UI
management.rates_mode = basic
collect_statistics_interval = 30000

# 4. PRUNING IN-MEMORY METRICS: Drops fine-grained metrics after 5 minutes
management.sample_retention_policies.global.minute = 5
```

---

## 4. The Operations Scripts Guide

The `scripts/` directory provides three production automation tools. All scripts include **automatic container detection**—they seamlessly identify whether RabbitMQ is running as `standalone-rabbitmq` (isolated host) or `shared-rabbitmq` (unified host).

---

### 4.1 `scripts/apply-policies.sh` (Lazy Queue Policy)

#### What It Does:
1. Verifies that the Docker container is running.
2. Loops against `rabbitmq-diagnostics -q ping` until the Erlang node is fully responsive (up to 30 attempts).
3. Executes `rabbitmqctl set_policy Lazy "^.*" '{"queue-mode":"lazy"}' --apply-to queues`.
4. Queries and prints active broker policies to confirm activation.

#### Why It Is Necessary:
By default, RabbitMQ holds all message payloads in RAM [4]. A **Lazy Queue** writes message bodies directly to storage the moment they arrive at the exchange, keeping only lightweight metadata in memory [4]. This reduces queue memory consumption by up to **80%** with zero message loss [4].

#### How to Run:
```bash
# Run immediately after starting the broker or after adding new vhosts
./scripts/apply-policies.sh
```

#### Expected Output:
```text
==========================================================
🐇 RabbitMQ Policy Provisioner
🎯 Target Container: standalone-rabbitmq
==========================================================
⏳ Waiting for RabbitMQ broker to accept administrative commands...
✅ RabbitMQ node is fully operational and responsive.
⚙️  Applying global 'Lazy' Queue policy across all queues...
📋 Verifying active policies on default vhost (/)...
Listing policies for vhost "/" ...
vhost   name   pattern  apply-to  definition           priority
/       Lazy   ^.*      queues    {"queue-mode":"lazy"} 0
==========================================================
✨ Success! Global Lazy Queue policy is active.
==========================================================
```

---

### 4.2 `scripts/backup.sh` (Definition & Schema Snapshot)

#### What It Does:
1. Checks that the broker is online.
2. Triggers `rabbitmqctl export_definitions /tmp/...` inside the container.
3. Securely copies the JSON schema out to the host's `backups/` directory.
4. Validates that the exported JSON is non-empty.
5. Gzip-compresses the file into `rabbitmq_definitions_YYYY-MM-DD_HHMMSS.json.gz`.
6. Prunes historical backups older than 14 days (`RETENTION_DAYS=14`).

#### What It Backs Up:
* All Virtual Hosts (`/`, custom vhosts)
* All Users, password hashes, and access tags
* All Exchanges, routing bindings, and dead-letter configurations
* All Queue parameters and applied policies (`Lazy`)

*(Note: In message-driven architectures, backing up definitions is the gold standard because brokers are ephemeral; once schemas are restored, microservices reconnect and resume flow).*

#### How to Run Manually:
```bash
./scripts/backup.sh
```

#### Automating via Nightly Cron (Recommended):
```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /opt/payg-mng/infrastructure/rabbitmq/scripts/backup.sh >> /var/log/rabbitmq_backup.log 2>&1") | crontab -
```

#### How to Restore a Backup:
```bash
# 1. Uncompress the target archive
gunzip -c backups/rabbitmq_definitions_2026-09-29_030000.json.gz > /tmp/restore.json

# 2. Copy into container and import
docker cp /tmp/restore.json standalone-rabbitmq:/tmp/restore.json
docker exec standalone-rabbitmq rabbitmqctl import_definitions /tmp/restore.json

# 3. Clean up temporary files
docker exec standalone-rabbitmq rm -f /tmp/restore.json
rm -f /tmp/restore.json
```

---

### 4.3 `scripts/gc.sh` (On-Demand Erlang Memory Reclaim)

#### What It Does:
1. Queries and prints the container's memory usage before cleanup using Docker cgroup metrics.
2. Executes an internal Erlang evaluation command across the running node:
   ```erlang
   [erlang:garbage_collect(Pid) || Pid <- erlang:processes()], ok.
   ```
3. Measures and prints the resulting memory footprint.
4. Outputs an itemized memory breakdown (`binary`, `connection_readers`, `queue_procs`).

#### Why It Is Safe for Production:
Unlike the Java Virtual Machine (JVM) which halts application threads during full garbage collection ("stop-the-world"), **Erlang utilizes independent, per-process heaps**. Running `erlang:garbage_collect(Pid)` sweeps each process individually without freezing the node or dropping AMQP connections.

#### How to Run Manually:
```bash
./scripts/gc.sh
```

#### Expected Output:
```text
==========================================================
🧹 RabbitMQ Erlang Garbage Collection (Memory Reclaim)
🎯 Target Container: standalone-rabbitmq
==========================================================
📊 Memory footprint BEFORE GC: 241.6MiB / 512MiB
⏳ Triggering Erlang process garbage collection & allocator cleanup...
📊 Memory footprint AFTER  GC: 114.2MiB / 512MiB

📋 Memory Allocation Breakdown:
  total: 119857152
  connection_readers: 24128
  connection_writers: 18456
  queue_procs: 312000
  binary: 14221056
  allocated_unused: 32184128
==========================================================
✨ Garbage collection completed successfully!
==========================================================
```

#### Automated Periodic Memory Sweeping:
If your cluster experiences regular spikes in message volume, add an automated sweep every 6 hours:
```bash
(crontab -l 2>/dev/null; echo "0 */6 * * * /opt/payg-mng/infrastructure/rabbitmq/scripts/gc.sh >> /var/log/rabbitmq_gc.log 2>&1") | crontab -
```

---

## 5. Enabling Native AMQPS (TLS/SSL on Port 5671)

To protect messages transmitted across untrusted networks or the public internet:

### 1. Place Certificates in `certs/`
Ensure your server keys are placed in `infrastructure/certs/rabbitmq/`:
* `ca.crt`: Root/Intermediate Certificate Authority
* `server.crt`: Server certificate matching your broker domain/IP
* `server.key`: Private key

### 2. Verify Port Mapping in `docker-compose.yml`
```yaml
ports:
  - "5672:5672"   # AMQP (Plaintext)
  - "5671:5671"   # AMQPS (TLS/SSL Encrypted)
  - "127.0.0.1:15672:15672" # Web UI (Localhost loopback)
```

### 3. Connect Microservices via Secure Protocol
```env
RABBITMQ_URL=amqps://admin:secure_password@<BROKER_HOST>:5671/
```

---

## 6. Queue Auditing & Troubleshooting Alarms

### Check for Message Accumulation
If a consumer service goes down, messages buffer in queues:
```bash
docker exec -it standalone-rabbitmq rabbitmqctl list_queues name messages consumers memory
```
* **Healthy state:** `consumers > 0`, `messages` remains near `0`.
* **Bottleneck state:** `consumers = 0` and `messages > 0` indicates the consumer microservice is offline or has unacknowledged message deadlocks.

### Purging a Stuck Queue
```bash
docker exec -it standalone-rabbitmq rabbitmqctl purge_queue <queue_name>
```

### Dealing with Memory Alarms
If memory exceeds the 384MB watermark, RabbitMQ triggers an alarm and **blocks all incoming publishers** to protect itself [1]:
```text
[warning] <0.xxxx.0> memory resource limit alarm set on node rabbit@standalone-rabbitmq
```
#### Emergency Remedy:
1. Run `./scripts/gc.sh` immediately to release allocator blocks.
2. Identify and restart the offline consumer service that stopped draining messages.
3. If necessary, raise the watermark in `config/rabbitmq.conf`:
   ```ini
   vm_memory_high_watermark.absolute = 512MB
   ```
   Apply dynamically without restart:
   ```bash
   docker exec -it standalone-rabbitmq rabbitmqctl set_vm_memory_high_watermark absolute 512MB
   ```

---

## 7. CLI Operations Quick Reference

| Operational Task | Command |
| :--- | :--- |
| **Broker Ping Health** | `docker exec -it standalone-rabbitmq rabbitmq-diagnostics -q ping` |
| **Check Active Watermark** | `docker exec -it standalone-rabbitmq rabbitmq-diagnostics -q memory_breakdown` |
| **List Queues & Consumers**| `docker exec -it standalone-rabbitmq rabbitmqctl list_queues name messages consumers` |
| **List Current Policies** | `docker exec -it standalone-rabbitmq rabbitmqctl list_policies` |
| **Run Garbage Collection**| `./scripts/gc.sh` |
| **Export Definitions** | `./scripts/backup.sh` |
| **Re-Apply Lazy Policy** | `./scripts/apply-policies.sh` |
| **Open Web UI Tunnel** | `ssh -N -L 15672:127.0.0.1:15672 user@<BROKER_IP>` $\to$ `http://localhost:15672` |
