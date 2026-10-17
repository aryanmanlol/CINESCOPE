#!/usr/bin/env bash
# =============================================================================
# scripts/00_env_check.sh
# Verifies that all required tools are installed and at the expected versions.
# Run this AFTER the setup script to confirm everything is working.
#
# Usage (WSL Ubuntu):
#   cd ~/cinescope
#   bash scripts/00_env_check.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Colour

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    local expected_pattern="$3"

    printf "  %-25s " "$name"
    local output
    if output=$(eval "$cmd" 2>&1); then
        if echo "$output" | grep -qE "$expected_pattern"; then
            echo -e "${GREEN}✓${NC}  $(echo "$output" | head -1)"
            ((PASS++)) || true
        else
            echo -e "${YELLOW}?${NC}  Got: $(echo "$output" | head -1) | Expected pattern: $expected_pattern"
            ((FAIL++)) || true
        fi
    else
        echo -e "${RED}✗${NC}  Command failed: $cmd"
        ((FAIL++)) || true
    fi
}

echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   CineScope Environment Check         ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════╝${NC}"
echo ""

# ── 1. System ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}[1/7] System${NC}"
check "OS"          "lsb_release -d"               "Ubuntu 22"
check "WSL"         "uname -r"                     "WSL"
check "User"        "whoami"                       ".*"
echo ""

# ── 2. Java ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}[2/7] Java${NC}"
check "java"        "java -version"                "1\.8|11|17"
check "javac"       "javac -version"               "javac"
check "JAVA_HOME"   "echo \$JAVA_HOME"             "/usr/lib/jvm|/usr/local"
echo ""

# ── 3. Hadoop ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}[3/7] Hadoop${NC}"
check "hadoop"      "hadoop version"               "Hadoop 3\."
check "hdfs"        "hdfs version"                 "Hadoop 3\."
check "HADOOP_HOME" "echo \$HADOOP_HOME"           "/opt/hadoop|/usr/local/hadoop"
check "SSH self"    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost echo ok" "ok"
echo ""

# ── 4. Hive ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}[4/7] Hive${NC}"
check "hive"        "hive --version"               "Hive 3\."
check "HIVE_HOME"   "echo \$HIVE_HOME"             "/opt/hive|/usr/local/hive"
echo ""

# ── 5. Pig ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[5/7] Pig${NC}"
check "pig"         "pig -version"                 "Pig version 0\.17"
check "PIG_HOME"    "echo \$PIG_HOME"              "/opt/pig|/usr/local/pig"
echo ""

# ── 6. HBase ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}[6/7] HBase${NC}"
check "hbase"       "hbase version"                "HBase 2\."
check "HBASE_HOME"  "echo \$HBASE_HOME"            "/opt/hbase|/usr/local/hbase"
echo ""

# ── 7. Python ─────────────────────────────────────────────────────────────────
echo -e "${BOLD}[7/7] Python venv${NC}"
check "python3"     "python3 --version"            "Python 3\.1[0-9]"
if [[ -f ~/cinescope/venv/bin/activate ]]; then
    source ~/cinescope/venv/bin/activate
    check "venv/streamlit"  "streamlit --version"         "Streamlit"
    check "venv/pandas"     "python3 -c 'import pandas; print(pandas.__version__)'"  "[0-9]"
    check "venv/happybase"  "python3 -c 'import happybase; print(\"ok\")'"          "ok"
    check "venv/scikit"     "python3 -c 'import sklearn; print(sklearn.__version__)'" "[0-9]"
    deactivate
else
    echo -e "  ${YELLOW}venv not found at ~/cinescope/venv — run the setup script first${NC}"
    ((FAIL++)) || true
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASSED: $PASS${NC}   ${RED}FAILED: $FAIL${NC}"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✓ All checks passed. Environment is ready.${NC}"
else
    echo -e "  ${RED}${BOLD}✗ $FAIL check(s) failed. Fix above errors and re-run.${NC}"
fi
echo ""
