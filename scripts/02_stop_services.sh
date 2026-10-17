#!/usr/bin/env bash
# =============================================================================
# scripts/02_stop_services.sh
# Gracefully stops all CineScope services in reverse order.
# Always stop HBase BEFORE Hadoop (HBase needs HDFS to flush WAL).
#
# Usage (WSL Ubuntu):
#   bash scripts/02_stop_services.sh
# =============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ $1${NC}"
}

echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   CineScope — Stopping Services       ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════╝${NC}"

# ── Stop HBase Thrift Server ──────────────────────────────────────────────────
banner "Stopping HBase Thrift Server"
if jps | grep -q "ThriftServer"; then
    # Find and kill the thrift server process
    THRIFT_PID=$(jps | grep ThriftServer | awk '{print $1}')
    kill "$THRIFT_PID" 2>/dev/null && echo -e "  ${GREEN}✓ Thrift Server stopped (PID $THRIFT_PID)${NC}"
else
    echo -e "  ${YELLOW}Thrift server not running${NC}"
fi

# ── Stop HBase ────────────────────────────────────────────────────────────────
banner "Stopping HBase"
if jps | grep -q "HMaster"; then
    stop-hbase.sh 2>&1 | tail -3
    echo -e "  ${GREEN}✓ HBase stopped${NC}"
else
    echo -e "  ${YELLOW}HBase not running${NC}"
fi
sleep 3

# ── Stop HiveServer2 + Metastore ──────────────────────────────────────────────
banner "Stopping Hive services"
# Kill any RunJar processes (Hive metastore and HiveServer2 run as RunJar)
for PID in $(jps | grep RunJar | awk '{print $1}'); do
    kill "$PID" 2>/dev/null || true
    echo -e "  ${GREEN}✓ Stopped RunJar PID $PID${NC}"
done
sleep 2

# ── Stop Job History Server ───────────────────────────────────────────────────
banner "Stopping MapReduce Job History Server"
if jps | grep -q "JobHistoryServer"; then
    mapred --daemon stop historyserver 2>&1
    echo -e "  ${GREEN}✓ Job History Server stopped${NC}"
else
    echo -e "  ${YELLOW}Job History Server not running${NC}"
fi

# ── Stop YARN ─────────────────────────────────────────────────────────────────
banner "Stopping YARN"
stop-yarn.sh 2>&1 | tail -3
echo -e "  ${GREEN}✓ YARN stopped${NC}"
sleep 2

# ── Stop HDFS ─────────────────────────────────────────────────────────────────
banner "Stopping HDFS"
stop-dfs.sh 2>&1 | tail -3
echo -e "  ${GREEN}✓ HDFS stopped${NC}"

# ── Final jps check ──────────────────────────────────────────────────────────
sleep 2
echo ""
echo -e "${BOLD}Remaining Java processes:${NC}"
JPS_OUT=$(jps 2>/dev/null)
if echo "$JPS_OUT" | grep -vq "^[0-9]* Jps$"; then
    echo "$JPS_OUT"
    echo -e "${YELLOW}  ⚠ Some processes still running. Wait a few seconds and check again.${NC}"
else
    echo -e "  ${GREEN}✓ None. All services stopped cleanly.${NC}"
fi
echo ""
