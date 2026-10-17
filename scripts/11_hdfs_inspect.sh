#!/usr/bin/env bash
# =============================================================================
# scripts/11_hdfs_inspect.sh
# Inspects HDFS health, block layout, and disk usage.
# Run after 10_ingest_hdfs.sh to verify data was loaded correctly.
#
# Usage (WSL Ubuntu):
#   bash scripts/11_hdfs_inspect.sh 2>&1 | tee reports/hdfs_inspect.txt
# =============================================================================

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

section() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
}

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  CineScope — HDFS Inspection Report  ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
echo "  Timestamp: $(date)"

# ─────────────────────────────────────────────────────────────────────────────
section "1. Cluster Overview (dfsadmin -report)"
# Shows: live DataNodes, total/used/free capacity, block pool usage
hdfs dfsadmin -report 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
section "2. HDFS Directory Listing"
echo "  Top-level /cinescope structure:"
hdfs dfs -ls -R /cinescope 2>/dev/null || echo "  (No data yet — run 10_ingest_hdfs.sh first)"

# ─────────────────────────────────────────────────────────────────────────────
section "3. Disk Usage by Directory"
echo "  (Shows logical size and disk usage with replication)"
hdfs dfs -du -h -s /cinescope/* 2>/dev/null | sort -k1 -h || echo "  No data"

# ─────────────────────────────────────────────────────────────────────────────
section "4. Block Analysis — ratings.csv (the critical file)"
echo "  This shows how ratings.csv is split into HDFS blocks."
echo "  With 64 MB block size, a 700 MB file → ~11 blocks → ~11 map tasks"
echo ""

RATINGS_PATH="/cinescope/raw/ratings/ratings.csv"
if hdfs dfs -test -e "$RATINGS_PATH" 2>/dev/null; then
    hdfs fsck "$RATINGS_PATH" \
        -files -blocks -locations \
        2>/dev/null | grep -v "^Connecting\|^FSCK\|^Status\|^\.$"
else
    echo "  ratings.csv not yet in HDFS. Run 10_ingest_hdfs.sh first."
fi

# ─────────────────────────────────────────────────────────────────────────────
section "5. Block Analysis — All Raw Files"
hdfs fsck /cinescope/raw \
    -files -blocks \
    2>/dev/null | grep -E "\.csv|blocks=|replication=" | head -30 || echo "  No data"

# ─────────────────────────────────────────────────────────────────────────────
section "6. HDFS Health Check"
echo "  Expected output: 'The filesystem under path / is HEALTHY'"
hdfs fsck / 2>/dev/null | grep -E "HEALTHY|CORRUPT|MISSING|Status" || true

# ─────────────────────────────────────────────────────────────────────────────
section "7. HDFS Configuration Confirmation"
echo "  Block size configured:"
hdfs getconf -confKey dfs.blocksize 2>/dev/null
echo "  Replication factor configured:"
hdfs getconf -confKey dfs.replication 2>/dev/null
echo "  NameNode address:"
hdfs getconf -confKey fs.defaultFS 2>/dev/null

echo ""
echo -e "${GREEN}${BOLD}✓ HDFS inspection complete.${NC}"
echo -e "  Full output saved to: reports/hdfs_inspect.txt (if piped)"
echo ""
