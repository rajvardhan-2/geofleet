# GeoFleet: Distributed Fleet Monitoring System

GeoFleet is a distributed, sharded fleet telemetry monitoring application built to demonstrate the **6 core distributed database properties** and the **CAP Theorem** using **native PostgreSQL engine primitives** and a lightweight Python coordinator.

---

## Architecture Overview

```text
                               [ GeoFleet REST Gateway / Coordinator ]
                                           (Port 8000)
                                                │
               ┌────────────────────────────────┴────────────────────────────────┐
               ▼                                                                 ▼
      [ Shard 1: US-EAST ]                                              [ Shard 2: EU-WEST ]
  ┌───────────────────────────┐                                     ┌───────────────────────────┐
  │ Primary Node (Port 5431)  │                                     │ Primary Node (Port 5433)  │
  │  - Writes (Telemetry/GPS) │                                     │  - Writes (Telemetry/GPS) │
  │  - WAL Sender             │                                     │  - WAL Sender             │
  └─────────────┬─────────────┘                                     └─────────────┬─────────────┘
                │ Physical Streaming                                              │ Physical Streaming
                │ Replication                                                     │ Replication
                ▼                                                                 ▼
  ┌───────────────────────────┐                                     ┌───────────────────────────┐
  │ Read Standby (Port 5435)  │                                     │ Read Standby (Port 5434)  │
  │  - Reads (Fleet Queries)  │                                     │  - Reads (Fleet Queries)  │
  │  - Hot Standby            │                                     │  - Hot Standby            │
  └───────────────────────────┘                                     └───────────────────────────┘
```

---

## The 6 Distributed Database Properties

| Property | Native Implementation | How to Verify |
| :--- | :--- | :--- |
| **1. Replication** | PostgreSQL physical streaming replication (`wal_level=replica`, `pg_basebackup -R`). | `SELECT * FROM pg_stat_replication;` shows `< 1ms` replay lag. |
| **2. Fault Tolerance** | Standby promotion via `pg_ctl promote` / `SELECT pg_promote();`. | Run `./scripts/demo_failover.sh`: kills Primary, promotes Standby, verifies writes resume. |
| **3. Availability** | Hot Standby mode (`hot_standby=on`) serves reads during high write throughput or node failures. | `GET /api/vehicles/{region}` routes to replica and never drops during primary crash. |
| **4. Distributed 2PC** | Native Two-Phase Commit (`PREPARE TRANSACTION`, `COMMIT PREPARED`, `ROLLBACK PREPARED`). | `POST /api/transfers/2pc` transfers vehicles atomically across shards; inspect `pg_prepared_xacts`. |
| **5. Recovery** | Write-Ahead Logging (WAL) checkpoint replay guarantees zero data loss (RPO = 0) on crash restart. | `docker kill` $\rightarrow$ restart verifies WAL redo logs on boot. |
| **6. Load Balancing** | Horizontal geographic sharding (US vs EU) + Read/Write connection splitting. | Live stats show writes balanced 50/50 and reads served by standbys. |

---

## CAP Theorem Mapping (Hybrid Architecture)

* **AP Subsystem (Real-Time GPS Telemetry):** Prioritizes **Availability & Partition Tolerance**. Under network partitions between shards, local GPS pings are continuously accepted into local regional primaries (eventual consistency on replicas).
* **CP Subsystem (Cross-Shard Asset Handover):** Prioritizes **Consistency & Partition Tolerance**. Under network partitions, the Two-Phase Commit coordinator aborts transfers rather than risking split-brain or duplicate vehicle assets.

---

## Quick Start Guide

### 1. Start the Distributed Cluster
```bash
cd /Users/sudharsan/.gemini/antigravity/scratch/geofleet
docker compose up -d
```

### 2. Verify Running Containers
```bash
docker compose ps
```
You will see 5 containers running:
* `geofleet-api` (Port `8000`)
* `shard-us-primary` (Port `5431`)
* `shard-us-replica` (Port `5435`)
* `shard-eu-primary` (Port `5433`)
* `shard-eu-replica` (Port `5434`)

### 3. Open Interactive Swagger Docs
Open your browser to:
**`http://localhost:8000/docs`**

---

## Live Demonstration Scripts (For Defense & Presentation)

Open a split terminal and execute the following:

### Terminal 1: Live Cluster Metrics & Invariant Monitor
```bash
./scripts/cluster_stats.sh
```
Displays live streaming pings, replication lag, 2PC in-doubt counts, and asset conservation checks.

### Terminal 2: Run Chaos Demonstrations

#### A. Atomic Two-Phase Commit (Happy Path)
```bash
curl -s -X POST http://localhost:8000/api/transfers/2pc \
  -H "Content-Type: application/json" \
  -d '{"vin": "1HGCR2F83HA100004", "source_region": "US-EAST", "target_region": "EU-WEST"}' | python3 -m json.tool
```

#### B. Simulated Coordinator Crash (In-Doubt 2PC Test)
```bash
# 1. Trigger transfer with chaos flag
curl -s -X POST http://localhost:8000/api/transfers/2pc \
  -H "Content-Type: application/json" \
  -d '{"vin": "1HGCR2F83HA100005", "source_region": "US-EAST", "target_region": "EU-WEST", "simulate_crash_after_prepare": true}' | python3 -m json.tool

# 2. Inspect WAL locks held on both shards
docker exec shard-us-primary psql -U postgres -d geofleet -c "SELECT gid, prepared FROM pg_prepared_xacts;"
docker exec shard-eu-primary psql -U postgres -d geofleet -c "SELECT gid, prepared FROM pg_prepared_xacts;"

# 3. Resolve the in-doubt transaction
curl -s -X POST http://localhost:8000/api/transfers/resolve \
  -H "Content-Type: application/json" \
  -d '{"gid_src": "<gid_from_above>", "gid_tgt": "<gid_from_above>", "action": "commit"}' | python3 -m json.tool
```

#### C. Fault Tolerance & Standby Promotion
```bash
./scripts/demo_failover.sh
```

#### D. CAP Theorem Network Partition Test
```bash
./scripts/demo_cap_partition.sh
```
Severes network to EU shard, demonstrates AP telemetry acceptance in US, demonstrates CP transfer abort across partition, and heals the partition.
