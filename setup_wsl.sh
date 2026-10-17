#!/usr/bin/env bash
# =============================================================================
# setup_wsl.sh  —  CineScope Complete Environment Setup Script
#
# Run ONCE on a fresh WSL2 Ubuntu 22.04 installation.
# This script installs and configures:
#   - OpenJDK 8, SSH (Hadoop needs passwordless SSH to localhost)
#   - Hadoop 3.3.6 (pseudo-distributed)
#   - Hive 3.1.3
#   - Pig 0.17.0 (with Hadoop 3 compatibility fix)
#   - HBase 2.5.7 (standalone, using HDFS)
#   - Python 3.10 virtualenv with all dependencies
#   - Copies dataset from /mnt/c into ~/cinescope/data/raw/
#
# ⚠️  READ FIRST:
#   1. Make sure WSL2 has internet access (ping 8.8.8.8)
#   2. This takes ~20-30 min on a first run (large downloads)
#   3. Run with: bash setup_wsl.sh 2>&1 | tee setup.log
#      (saves a full log in case something fails)
#
# Usage (WSL Ubuntu):
#   bash ~/cinescope/setup_wsl.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these if your dataset path is different
# ─────────────────────────────────────────────────────────────────────────────

# Path to the extracted dataset on Windows (accessible from WSL via /mnt/c/)
# Adjust the folder name inside 'Downloads' to match yours
WINDOWS_DATASET_DIR="/mnt/c/Users/aryan/Downloads"

# Where we look for the CSV files (try common extracted folder names)
POSSIBLE_DATASET_DIRS=(
    "$WINDOWS_DATASET_DIR/the-movies-dataset"
    "$WINDOWS_DATASET_DIR/movies-dataset"
    "$WINDOWS_DATASET_DIR/archive"
    "$WINDOWS_DATASET_DIR"
)

# Software versions — pinned for reproducibility
HADOOP_VERSION="3.3.6"
HIVE_VERSION="3.1.3"
PIG_VERSION="0.17.0"
HBASE_VERSION="2.5.7"

# Installation base directory
INSTALL_DIR="/opt"

# Project directory in WSL Linux filesystem (NOT /mnt/c — too slow)
PROJECT_DIR="$HOME/cinescope"

# ─────────────────────────────────────────────────────────────────────────────
# COLOUR HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo ""; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"; }
ok()    { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()  { echo -e "  ${YELLOW}⚠ $1${NC}"; }
die()   { echo -e "  ${RED}✗ FATAL: $1${NC}"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────
step "Step 0/10: Pre-flight checks"

# Must be running in WSL2
if ! uname -r | grep -qi "wsl"; then
    warn "This doesn't look like WSL (kernel: $(uname -r)). Continuing anyway..."
fi

# Must have internet
if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
    die "No internet access. WSL2 networking issue. Try: wsl --shutdown && restart WSL."
fi
ok "Internet access confirmed"

# Must NOT be root (Hadoop doesn't like running as root in pseudo-distributed)
if [[ $EUID -eq 0 ]]; then
    die "Do not run as root. Run as your regular user with sudo access."
fi

# Find the dataset
DATASET_DIR=""
for d in "${POSSIBLE_DATASET_DIRS[@]}"; do
    if [[ -f "$d/ratings.csv" ]] || [[ -f "$d/ratings_small.csv" ]]; then
        DATASET_DIR="$d"
        break
    fi
done

if [[ -z "$DATASET_DIR" ]]; then
    warn "Could not auto-find the dataset. Searched in:"
    for d in "${POSSIBLE_DATASET_DIRS[@]}"; do echo "    $d"; done
    echo ""
    echo "  Please enter the full WSL path to the folder containing ratings.csv:"
    read -r DATASET_DIR
    if [[ ! -f "$DATASET_DIR/ratings.csv" ]] && [[ ! -f "$DATASET_DIR/ratings_small.csv" ]]; then
        die "Still can't find ratings.csv in $DATASET_DIR. Aborting."
    fi
fi
ok "Dataset found at: $DATASET_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: System packages
# ─────────────────────────────────────────────────────────────────────────────
step "Step 1/10: Installing system packages"

sudo apt-get update -qq
sudo apt-get install -y \
    openjdk-8-jdk \
    openssh-server \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    wget \
    curl \
    unzip \
    net-tools \
    lsof \
    rsync \
    build-essential \
    2>&1 | tail -5

ok "System packages installed"

# Set JAVA_HOME for OpenJDK 8
JAVA_HOME_PATH=$(dirname $(dirname $(readlink -f $(which java))))
ok "JAVA_HOME: $JAVA_HOME_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: SSH passwordless login to localhost (required by Hadoop)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 2/10: Configuring passwordless SSH to localhost"

# Start SSH service
sudo service ssh start

# Generate SSH key if it doesn't exist
if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa -q
    ok "SSH key generated"
fi

# Add to authorized keys
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Trust localhost (skip host key confirmation)
ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null
ssh-keyscan -H 0.0.0.0   >> ~/.ssh/known_hosts 2>/dev/null

# Test
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost echo "SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
    ok "Passwordless SSH to localhost works"
else
    warn "SSH test failed — Hadoop scripts may prompt for password. Try: sudo service ssh restart"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Download and install Hadoop 3.3.6
# ─────────────────────────────────────────────────────────────────────────────
step "Step 3/10: Installing Hadoop $HADOOP_VERSION"

HADOOP_DIR="$INSTALL_DIR/hadoop-$HADOOP_VERSION"

if [[ -d "$HADOOP_DIR" ]]; then
    warn "Hadoop already installed at $HADOOP_DIR — skipping download"
else
    HADOOP_TAR="hadoop-$HADOOP_VERSION.tar.gz"
    HADOOP_URL="https://downloads.apache.org/hadoop/common/hadoop-$HADOOP_VERSION/$HADOOP_TAR"

    echo "  Downloading Hadoop (this may take a few minutes)..."
    wget -q --show-progress -O "/tmp/$HADOOP_TAR" "$HADOOP_URL"

    echo "  Extracting..."
    sudo tar -xzf "/tmp/$HADOOP_TAR" -C "$INSTALL_DIR"
    sudo chown -R "$USER:$USER" "$HADOOP_DIR"
    rm "/tmp/$HADOOP_TAR"
    ok "Hadoop $HADOOP_VERSION installed at $HADOOP_DIR"
fi

# Copy our config files into Hadoop
echo "  Copying CineScope config files into Hadoop..."
for xml in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do
    if [[ -f "$PROJECT_DIR/config/hadoop/$xml" ]]; then
        # Substitute ${user.name} with actual username in the XML
        sed "s/\${user.name}/$USER/g" "$PROJECT_DIR/config/hadoop/$xml" \
            > "$HADOOP_DIR/etc/hadoop/$xml"
        ok "Installed $xml"
    else
        warn "Config file not found: $PROJECT_DIR/config/hadoop/$xml"
    fi
done

# Set JAVA_HOME in hadoop-env.sh (required)
HADOOP_ENV="$HADOOP_DIR/etc/hadoop/hadoop-env.sh"
if ! grep -q "export JAVA_HOME=$JAVA_HOME_PATH" "$HADOOP_ENV"; then
    echo "export JAVA_HOME=$JAVA_HOME_PATH" | sudo tee -a "$HADOOP_ENV" >/dev/null
    ok "JAVA_HOME set in hadoop-env.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Download and install Hive 3.1.3
# ─────────────────────────────────────────────────────────────────────────────
step "Step 4/10: Installing Hive $HIVE_VERSION"

HIVE_DIR="$INSTALL_DIR/apache-hive-$HIVE_VERSION-bin"

if [[ -d "$HIVE_DIR" ]]; then
    warn "Hive already installed at $HIVE_DIR — skipping download"
else
    HIVE_TAR="apache-hive-$HIVE_VERSION-bin.tar.gz"
    HIVE_URL="https://downloads.apache.org/hive/hive-$HIVE_VERSION/$HIVE_TAR"

    echo "  Downloading Hive..."
    wget -q --show-progress -O "/tmp/$HIVE_TAR" "$HIVE_URL"

    echo "  Extracting..."
    sudo tar -xzf "/tmp/$HIVE_TAR" -C "$INSTALL_DIR"
    sudo chown -R "$USER:$USER" "$HIVE_DIR"
    rm "/tmp/$HIVE_TAR"
    ok "Hive $HIVE_VERSION installed at $HIVE_DIR"
fi

# Copy Hive config
if [[ -f "$PROJECT_DIR/config/hive/hive-site.xml" ]]; then
    sed "s/\${user.name}/$USER/g" "$PROJECT_DIR/config/hive/hive-site.xml" \
        > "$HIVE_DIR/conf/hive-site.xml"
    ok "hive-site.xml installed"
fi

# Fix Guava conflict: Hive 3 ships with Guava 14; Hadoop 3 needs Guava 27
# This is a well-known compatibility issue
echo "  Fixing Guava conflict (Hive 3 + Hadoop 3)..."
GUAVA_HIVE="$HIVE_DIR/lib/guava-14.0.1.jar"
GUAVA_HADOOP="$HADOOP_DIR/share/hadoop/common/lib/guava-27.0-jre.jar"
if [[ -f "$GUAVA_HIVE" ]] && [[ -f "$GUAVA_HADOOP" ]]; then
    mv "$GUAVA_HIVE" "$GUAVA_HIVE.bak" 2>/dev/null || true
    cp "$GUAVA_HADOOP" "$HIVE_DIR/lib/"
    ok "Guava conflict fixed (replaced 14.0.1 with 27.0-jre)"
else
    warn "Could not fix Guava — Hive may have errors loading. Manual fix may be needed."
fi

# Initialize Hive metastore schema (Derby)
METASTORE_DIR="$HOME/cinescope-hive-metastore"
if [[ ! -d "$METASTORE_DIR/metastore_db" ]]; then
    echo "  Initializing Hive metastore schema (Derby)..."
    mkdir -p "$METASTORE_DIR"
    cd "$METASTORE_DIR"
    "$HIVE_DIR/bin/schematool" -dbType derby -initSchema 2>&1 | tail -5
    cd "$PROJECT_DIR"
    ok "Hive metastore initialized"
else
    ok "Hive metastore already initialized"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Download and install Pig 0.17.0 (with Hadoop 3 fix)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 5/10: Installing Pig $PIG_VERSION (with Hadoop 3 compatibility fix)"

PIG_DIR="$INSTALL_DIR/pig-$PIG_VERSION"

if [[ -d "$PIG_DIR" ]]; then
    warn "Pig already installed at $PIG_DIR — skipping download"
else
    PIG_TAR="pig-$PIG_VERSION.tar.gz"
    PIG_URL="https://downloads.apache.org/pig/pig-$PIG_VERSION/$PIG_TAR"

    echo "  Downloading Pig..."
    wget -q --show-progress -O "/tmp/$PIG_TAR" "$PIG_URL"

    echo "  Extracting..."
    sudo tar -xzf "/tmp/$PIG_TAR" -C "$INSTALL_DIR"
    sudo chown -R "$USER:$USER" "$PIG_DIR"
    rm "/tmp/$PIG_TAR"
    ok "Pig $PIG_VERSION installed at $PIG_DIR"
fi

#
# ⚠️  HADOOP 3 COMPATIBILITY FIX FOR PIG 0.17
#
# Problem: Pig 0.17 was built against Hadoop 2.x. In Hadoop 3, the
# mapreduce JARs moved from:
#   $HADOOP_HOME/share/hadoop/mapreduce1/  (Hadoop 2)
# to:
#   $HADOOP_HOME/share/hadoop/mapreduce/   (Hadoop 3)
#
# Pig's pig-env.sh constructs PIG_CLASSPATH using the old path, so
# Hadoop 3 classes are missing → "ClassNotFoundException" at runtime.
#
# Fix: Set PIG_CLASSPATH explicitly in pig-env.sh to include all
# Hadoop 3 JARs. Also set PIG_HADOOP_VERSION=23 to suppress a warning.
#
echo "  Applying Hadoop 3 compatibility fix to pig-env.sh..."
PIG_ENV="$PIG_DIR/conf/pig-env.sh"

# Create/overwrite pig-env.sh with our fixes
cat > "$PIG_ENV" << 'EOF'
# pig-env.sh — CineScope Pig configuration with Hadoop 3 fixes

# ── Hadoop 3 Classpath Fix ──────────────────────────────────────────────────
# Pig 0.17 was built for Hadoop 2. We manually build PIG_CLASSPATH to include
# all Hadoop 3 JARs that Pig needs.
# Without this, Pig throws ClassNotFoundException on Hadoop 3.
for jar in \
    "$HADOOP_HOME/share/hadoop/common"/*.jar \
    "$HADOOP_HOME/share/hadoop/common/lib"/*.jar \
    "$HADOOP_HOME/share/hadoop/hdfs"/*.jar \
    "$HADOOP_HOME/share/hadoop/hdfs/lib"/*.jar \
    "$HADOOP_HOME/share/hadoop/mapreduce"/*.jar \
    "$HADOOP_HOME/share/hadoop/mapreduce/lib"/*.jar \
    "$HADOOP_HOME/share/hadoop/yarn"/*.jar \
    "$HADOOP_HOME/share/hadoop/yarn/lib"/*.jar; do
    if [[ -f "$jar" ]]; then
        PIG_CLASSPATH="$PIG_CLASSPATH:$jar"
    fi
done
export PIG_CLASSPATH

# ── Suppress "Pig built for Hadoop 2" warning ───────────────────────────────
export PIG_HADOOP_VERSION=23   # Tells Pig to treat Hadoop as 2.3-compatible

# ── Memory ──────────────────────────────────────────────────────────────────
export PIG_HEAPSIZE=512   # MB for Pig client JVM

# ── Java Home ───────────────────────────────────────────────────────────────
# Inherited from system JAVA_HOME
EOF

ok "pig-env.sh updated with Hadoop 3 fix"

# Download Pig's CSVExcelStorage (piggybank) - needed for Phase 2
echo "  Checking for piggybank.jar (CSVExcelStorage for multi-line CSV)..."
PIGGYBANK="$PIG_DIR/lib/piggybank.jar"
if [[ ! -f "$PIGGYBANK" ]]; then
    # piggybank is included in Pig distribution
    PIGGYBANK_DIST="$PIG_DIR/contrib/piggybank/java/piggybank.jar"
    if [[ -f "$PIGGYBANK_DIST" ]]; then
        cp "$PIGGYBANK_DIST" "$PIGGYBANK"
        ok "piggybank.jar copied to $PIGGYBANK"
    else
        warn "piggybank.jar not found in Pig distribution. Build it manually if needed for Phase 2."
    fi
else
    ok "piggybank.jar already present"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Download and install HBase 2.5.7
# ─────────────────────────────────────────────────────────────────────────────
step "Step 6/10: Installing HBase $HBASE_VERSION"

HBASE_DIR="$INSTALL_DIR/hbase-$HBASE_VERSION"

if [[ -d "$HBASE_DIR" ]]; then
    warn "HBase already installed at $HBASE_DIR — skipping download"
else
    HBASE_TAR="hbase-$HBASE_VERSION-bin.tar.gz"
    HBASE_URL="https://downloads.apache.org/hbase/$HBASE_VERSION/$HBASE_TAR"

    echo "  Downloading HBase..."
    wget -q --show-progress -O "/tmp/$HBASE_TAR" "$HBASE_URL"

    echo "  Extracting..."
    sudo tar -xzf "/tmp/$HBASE_TAR" -C "$INSTALL_DIR"
    sudo chown -R "$USER:$USER" "$HBASE_DIR"
    rm "/tmp/$HBASE_TAR"
    ok "HBase $HBASE_VERSION installed at $HBASE_DIR"
fi

# Copy HBase config
if [[ -f "$PROJECT_DIR/config/hbase/hbase-site.xml" ]]; then
    sed "s/\${user.name}/$USER/g" "$PROJECT_DIR/config/hbase/hbase-site.xml" \
        > "$HBASE_DIR/conf/hbase-site.xml"
    ok "hbase-site.xml installed"
fi

# Set JAVA_HOME in hbase-env.sh
HBASE_ENV="$HBASE_DIR/conf/hbase-env.sh"
if ! grep -q "JAVA_HOME=$JAVA_HOME_PATH" "$HBASE_ENV"; then
    echo "export JAVA_HOME=$JAVA_HOME_PATH" | sudo tee -a "$HBASE_ENV" >/dev/null
fi

# Set HBase memory in hbase-env.sh (tuned for 8 GB WSL)
cat >> "$HBASE_ENV" << EOF

# CineScope memory settings (tuned for 8 GB WSL)
export HBASE_MASTER_OPTS="-Xms256m -Xmx512m"
export HBASE_REGIONSERVER_OPTS="-Xms256m -Xmx512m"
export HBASE_MANAGES_ZK=true   # HBase manages its own ZooKeeper
EOF
ok "HBase memory settings configured"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: Configure environment variables (~/.bashrc)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 7/10: Setting environment variables in ~/.bashrc"

BASHRC_MARKER="# ── CineScope Environment Variables ──"

if grep -q "$BASHRC_MARKER" ~/.bashrc; then
    warn "Environment variables already in ~/.bashrc — skipping (remove manually to reset)"
else
    cat >> ~/.bashrc << EOF

$BASHRC_MARKER
# Generated by CineScope setup_wsl.sh

# Java
export JAVA_HOME=$JAVA_HOME_PATH
export PATH=\$JAVA_HOME/bin:\$PATH

# Hadoop
export HADOOP_HOME=$HADOOP_DIR
export HADOOP_INSTALL=\$HADOOP_HOME
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export YARN_HOME=\$HADOOP_HOME
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_HOME/lib/native
export PATH=\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin:\$PATH

# Hadoop Streaming JAR (used in all MapReduce Streaming jobs)
export STREAMING_JAR=\$(ls \$HADOOP_HOME/share/hadoop/tools/lib/hadoop-streaming-*.jar 2>/dev/null | head -1)

# Hive
export HIVE_HOME=$HIVE_DIR
export HIVE_CONF_DIR=\$HIVE_HOME/conf
export PATH=\$HIVE_HOME/bin:\$PATH

# Pig
export PIG_HOME=$PIG_DIR
export PATH=\$PIG_HOME/bin:\$PATH
export PIG_CLASSPATH=\$HADOOP_HOME/etc/hadoop:\$PIG_HOME/lib/*

# HBase
export HBASE_HOME=$HBASE_DIR
export PATH=\$HBASE_HOME/bin:\$PATH

# CineScope Project
export CINESCOPE_HOME=$PROJECT_DIR
export CINESCOPE_CONFIG=\$CINESCOPE_HOME/config/project_config.yaml
export PATH=\$CINESCOPE_HOME/scripts:\$PATH

# Python venv (auto-activate when in project dir)
if [[ -f \$CINESCOPE_HOME/venv/bin/activate ]]; then
    source \$CINESCOPE_HOME/venv/bin/activate
fi
# ── End CineScope ──────────────────────────────────────────────────────────
EOF
    ok "Environment variables written to ~/.bashrc"
fi

# Apply immediately for this session
source ~/.bashrc 2>/dev/null || true
export HADOOP_HOME="$HADOOP_DIR"
export HIVE_HOME="$HIVE_DIR"
export PIG_HOME="$PIG_DIR"
export HBASE_HOME="$HBASE_DIR"
export PATH="$HADOOP_DIR/bin:$HADOOP_DIR/sbin:$HIVE_DIR/bin:$PIG_DIR/bin:$HBASE_DIR/bin:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: Python virtualenv + packages
# ─────────────────────────────────────────────────────────────────────────────
step "Step 8/10: Creating Python 3.10 virtualenv and installing packages"

VENV_DIR="$PROJECT_DIR/venv"

if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    ok "Virtualenv created at $VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# Upgrade pip first
pip install --quiet --upgrade pip

echo "  Installing Python packages (this may take 3-5 min)..."
pip install --quiet \
    streamlit==1.35.0 \
    plotly==5.22.0 \
    pandas==2.2.2 \
    pyarrow==16.1.0 \
    numpy==1.26.4 \
    scipy==1.13.1 \
    scikit-learn==1.5.0 \
    happybase==1.2.0 \
    nltk==3.8.1 \
    pyyaml==6.0.1 \
    thrift==0.20.0 \
    Pillow==10.3.0 \
    requests==2.32.2 \
    2>&1 | tail -3

# Download NLTK data needed for text processing
python3 -c "
import nltk
nltk.download('punkt', quiet=True)
nltk.download('stopwords', quiet=True)
nltk.download('wordnet', quiet=True)
print('NLTK data downloaded')
"

deactivate
ok "Python packages installed"

# Save requirements.txt
pip freeze --path "$VENV_DIR/lib" 2>/dev/null || true
cat > "$PROJECT_DIR/requirements.txt" << 'EOF'
# CineScope Python dependencies
# Install with: pip install -r requirements.txt
# (after activating the venv: source venv/bin/activate)

streamlit==1.35.0
plotly==5.22.0
pandas==2.2.2
pyarrow==16.1.0
numpy==1.26.4
scipy==1.13.1
scikit-learn==1.5.0
happybase==1.2.0
nltk==3.8.1
pyyaml==6.0.1
thrift==0.20.0
Pillow==10.3.0
requests==2.32.2
EOF
ok "requirements.txt written"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: Copy dataset into Linux filesystem + create samples
# ─────────────────────────────────────────────────────────────────────────────
step "Step 9/10: Copying dataset into $PROJECT_DIR/data/raw/"

RAW_DIR="$PROJECT_DIR/data/raw"
mkdir -p "$RAW_DIR"

REQUIRED_FILES=(
    "ratings.csv"
    "ratings_small.csv"
    "movies_metadata.csv"
    "links.csv"
    "keywords.csv"
    "credits.csv"
    "links_small.csv"
)

COPIED=0
for fname in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$DATASET_DIR/$fname" ]]; then
        if [[ ! -f "$RAW_DIR/$fname" ]]; then
            echo "  Copying $fname..."
            cp "$DATASET_DIR/$fname" "$RAW_DIR/$fname"
            ok "$fname copied ($(du -sh "$RAW_DIR/$fname" | cut -f1))"
        else
            ok "$fname already in $RAW_DIR"
        fi
        ((COPIED++)) || true
    else
        warn "$fname not found in $DATASET_DIR — skipping"
    fi
done

echo ""
echo "  Copied $COPIED / ${#REQUIRED_FILES[@]} files"

# Inspect actual headers (don't trust the brief blindly)
echo ""
echo -e "${BOLD}  Dataset header inspection:${NC}"
for f in ratings_small.csv movies_metadata.csv links.csv; do
    if [[ -f "$RAW_DIR/$f" ]]; then
        echo "  ── $f ──"
        head -2 "$RAW_DIR/$f" | cut -c1-120
        echo "  Rows: $(wc -l < "$RAW_DIR/$f" | tr -d ' ')"
    fi
done

# Create sample files for local pipe tests
echo ""
echo "  Creating sample files for pipe tests..."
SAMPLE_DIR="$PROJECT_DIR/data/sample"
mkdir -p "$SAMPLE_DIR"

# ratings sample: skip header, take 1000 rows
if [[ -f "$RAW_DIR/ratings_small.csv" ]]; then
    head -1 "$RAW_DIR/ratings_small.csv" > "$SAMPLE_DIR/ratings_sample.csv"
    tail -n +2 "$RAW_DIR/ratings_small.csv" | head -1000 >> "$SAMPLE_DIR/ratings_sample.csv"
    ok "ratings_sample.csv (1000 rows)"
fi

# movies sample: 200 rows
if [[ -f "$RAW_DIR/movies_metadata.csv" ]]; then
    head -1 "$RAW_DIR/movies_metadata.csv" > "$SAMPLE_DIR/movies_sample.csv"
    tail -n +2 "$RAW_DIR/movies_metadata.csv" | head -200 >> "$SAMPLE_DIR/movies_sample.csv"
    ok "movies_sample.csv (200 rows)"
fi

# Create MEDIUM scale ratings (~2M rows) by taking first 2M rows of ratings.csv
if [[ -f "$RAW_DIR/ratings.csv" ]]; then
    RATINGS_ROWS=$(wc -l < "$RAW_DIR/ratings.csv")
    echo "  ratings.csv has $RATINGS_ROWS rows"
    if [[ $RATINGS_ROWS -gt 2000000 ]]; then
        if [[ ! -f "$RAW_DIR/ratings_medium.csv" ]]; then
            echo "  Creating ratings_medium.csv (2M rows)..."
            head -1 "$RAW_DIR/ratings.csv" > "$RAW_DIR/ratings_medium.csv"
            tail -n +2 "$RAW_DIR/ratings.csv" | head -2000000 >> "$RAW_DIR/ratings_medium.csv"
            ok "ratings_medium.csv created ($(du -sh "$RAW_DIR/ratings_medium.csv" | cut -f1))"
        else
            ok "ratings_medium.csv already exists"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: Format HDFS and do initial start
# ─────────────────────────────────────────────────────────────────────────────
step "Step 10/10: Formatting HDFS NameNode and starting services"

HADOOP_TMP="$HOME/cinescope-hadoop-tmp"

if [[ -d "$HADOOP_TMP/dfs/name" ]]; then
    warn "HDFS already formatted at $HADOOP_TMP — skipping format"
    warn "If you want a fresh start: rm -rf $HADOOP_TMP && re-run this script"
else
    echo "  Formatting NameNode..."
    hdfs namenode -format -nonInteractive -force 2>&1 | grep -E "INFO|ERROR|WARN" | tail -10
    ok "NameNode formatted"
fi

echo ""
echo "  Starting services..."
bash "$PROJECT_DIR/scripts/01_start_services.sh"

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  ✓  CineScope Setup Complete!                     ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Reload your shell: source ~/.bashrc"
echo "  2. Verify environment: bash scripts/00_env_check.sh"
echo "  3. Check HDFS: hdfs dfs -ls /"
echo "  4. Test Hive: beeline -u \"jdbc:hive2://localhost:10000\" -n root -e 'show databases;'"
echo "  5. Test HBase: echo \"status\" | hbase shell"
echo "  6. Open web UIs in Windows browser:"
echo "       HDFS:  http://localhost:9870"
echo "       YARN:  http://localhost:8088"
echo "       HBase: http://localhost:16010"
echo ""
echo -e "${YELLOW}Note: Run 'source ~/.bashrc' or open a new terminal for env vars to take effect.${NC}"
echo ""
