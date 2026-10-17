#!/usr/bin/env bash
# =============================================================================
# scripts/01_start_services.sh
# Starts all CineScope services in the correct order:
#   1. HDFS (NameNode + DataNode)
#   2. YARN (ResourceManager + NodeManager)
#   3. MapReduce Job History Server
#   4. Hive Metastore + HiveServer2
#   5. HBase (Master + RegionServer + ZooKeeper)
#   6. HBase Thrift Server (for Python/happybase)
#
# Usage (WSL Ubuntu):
#   cd ~/cinescope
#   bash scripts/01_start_services.sh
# =============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR=~/cinescope/logs
mkdir -p "$LOG_DIR"

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ $1${NC}"
}

ok() { echo -e "  ${GREEN}✓ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }

# ── Source environment variables ──────────────────────────────────────────────
if [[ -f ~/.bashrc ]]; then
    source ~/.bashrc
fi

echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   CineScope — Starting Services       ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════╝${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: HDFS
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 1/6 — Starting HDFS (NameNode + DataNode)"

# Check if already running
if hdfs dfsadmin -report &>/dev/null; then
    warn "HDFS already running — skipping start"
else
    start-dfs.sh 2>&1 | tee "$LOG_DIR/hdfs_start.log" | tail -5
    sleep 5
    # Verify
    if hdfs dfsadmin -report &>/dev/null; then
        ok "HDFS started successfully"
    else
        echo -e "${RED}✗ HDFS failed to start. Check: $LOG_DIR/hdfs_start.log${NC}"
        exit 1
    fi
fi

# Create CineScope HDFS directory structure if it doesn't exist
echo "  Creating HDFS directory structure..."
for dir in \
    /cinescope/raw/ratings \
    /cinescope/raw/movies \
    /cinescope/raw/links \
    /cinescope/raw/keywords \
    /cinescope/raw/credits \
    /cinescope/clean \
    /cinescope/warehouse \
    /cinescope/mr \
    /cinescope/serving \
    /tmp/hive; do
    hdfs dfs -mkdir -p "$dir" 2>/dev/null || true
done
hdfs dfs -chmod 777 /tmp/hive 2>/dev/null || true
ok "HDFS directories ready"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: YARN
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 2/6 — Starting YARN (ResourceManager + NodeManager)"

if yarn node -list 2>/dev/null | grep -q "RUNNING"; then
    warn "YARN already running — skipping start"
else
    start-yarn.sh 2>&1 | tee "$LOG_DIR/yarn_start.log" | tail -5
    sleep 5
    ok "YARN started"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: MapReduce Job History Server
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 3/6 — Starting MapReduce Job History Server"

if jps | grep -q "JobHistoryServer"; then
    warn "JobHistoryServer already running"
else
    mapred --daemon start historyserver 2>&1 | tee "$LOG_DIR/historyserver_start.log"
    sleep 3
    ok "Job History Server started"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Hive Metastore + HiveServer2
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 4/6 — Starting Hive Metastore + HiveServer2"

if jps | grep -q "RunJar"; then
    warn "Hive services appear to be running already"
else
    echo "  Starting Hive Metastore (background)..."
    nohup hive --service metastore \
        > "$LOG_DIR/metastore.log" 2>&1 &
    METASTORE_PID=$!
    echo "  Metastore PID: $METASTORE_PID"

    echo "  Waiting 10s for metastore to initialize..."
    sleep 10

    echo "  Starting HiveServer2 (background)..."
    nohup hive --service hiveserver2 \
        > "$LOG_DIR/hiveserver2.log" 2>&1 &
    HS2_PID=$!
    echo "  HiveServer2 PID: $HS2_PID"

    echo "  Waiting 15s for HiveServer2 to initialize..."
    sleep 15
    ok "Hive Metastore + HiveServer2 started"
    echo "  Logs: $LOG_DIR/metastore.log | $LOG_DIR/hiveserver2.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: HBase
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 5/6 — Starting HBase (standalone with HDFS)"

if jps | grep -q "HMaster"; then
    warn "HBase already running"
else
    start-hbase.sh 2>&1 | tee "$LOG_DIR/hbase_start.log" | tail -5
    sleep 8
    if jps | grep -q "HMaster"; then
        ok "HBase started"
    else
        echo -e "${YELLOW}  ⚠ HBase may not have started cleanly. Check: $LOG_DIR/hbase_start.log${NC}"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: HBase Thrift Server
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 6/6 — Starting HBase Thrift Server (port 9090)"

if jps | grep -q "ThriftServer"; then
    warn "Thrift server already running"
else
    nohup hbase thrift start -p 9090 \
        > "$LOG_DIR/hbase_thrift.log" 2>&1 &
    THRIFT_PID=$!
    sleep 5
    ok "HBase Thrift server started (PID: $THRIFT_PID)"
    echo "  Log: $LOG_DIR/hbase_thrift.log"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY: jps + Web UIs
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
echo -e "${BOLD}  Running Java Processes (jps):${NC}"
jps | sort
echo ""
echo -e "${BOLD}  Web UIs (open in Windows browser):${NC}"
echo -e "  ${GREEN}HDFS NameNode:${NC}        http://localhost:9870"
echo -e "  ${GREEN}YARN ResourceManager:${NC} http://localhost:8088"
echo -e "  ${GREEN}Job History Server:${NC}   http://localhost:19888"
echo -e "  ${GREEN}HBase Master:${NC}         http://localhost:16010"
echo ""
echo -e "${BOLD}  Beeline connection:${NC}"
echo -e "  ${CYAN}beeline -u \"jdbc:hive2://localhost:10000\" -n root${NC}"
echo ""
echo -e "${GREEN}${BOLD}✓ All services started. CineScope is ready.${NC}"
echo ""
