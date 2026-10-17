# Phase 0 Setup Guide — WSL2 + Hadoop Ecosystem

This document walks you through **every command** to get from a fresh Windows machine
to a fully running CineScope environment. Follow the steps in order.

---

## Quick Reference: Compatible Versions

| Component | Version | Notes |
|-----------|---------|-------|
| WSL2 Ubuntu | 22.04 LTS | Must be WSL2, not WSL1 |
| OpenJDK | **8** (1.8.0_392) | Java 11/17 have module-system issues with Hive 3 |
| Hadoop | **3.3.6** | Latest stable 3.x |
| Hive | **3.1.3** | Latest Hive 3.x compatible with Hadoop 3.3 |
| Pig | **0.17.0** | ⚠️ Built for Hadoop 2 — see compatibility fix below |
| HBase | **2.5.7** | Standalone mode, stores data in HDFS |
| Python | **3.10** (system) | Ubuntu 22.04 default |

---

## STEP A — Install WSL2 on Windows

> **Label: PowerShell (Windows)** — Run as Administrator

```powershell
# 1. Enable WSL2 feature
wsl --install

# 2. (If the above doesn't work on your Windows version, use these two commands)
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# 3. Restart your computer, then run:
wsl --set-default-version 2

# 4. Install Ubuntu 22.04
wsl --install -d Ubuntu-22.04

# 5. Verify
wsl -l -v
# Expected output:
#   NAME            STATE    VERSION
#   Ubuntu-22.04    Running  2       ← Must say VERSION 2
```

After installation, Ubuntu will prompt you to create a username and password.
**Remember this password** — you'll need it for `sudo` commands.

---

## STEP B — Configure WSL2 Memory Limits

> **Label: PowerShell (Windows)** — Run as your regular user (not Admin)

```powershell
# Create the .wslconfig file that limits WSL2's RAM/CPU usage
# This prevents WSL2 from consuming all 16 GB of your RAM
Copy-Item "C:\Users\aryan\.gemini\antigravity-ide\scratch\cinescope\.wslconfig" `
          "C:\Users\aryan\.wslconfig"

# Restart WSL2 to apply the limits
wsl --shutdown
# Wait 5 seconds, then open Ubuntu again
```

The `.wslconfig` sets:
- **Memory: 8 GB** (half of 16 GB — leaves 8 GB for Windows)
- **CPUs: 4 logical cores**
- **Swap: 4 GB** (on-disk fallback memory)

---

## STEP C — Copy Project into WSL2 Filesystem

> **Label: WSL Ubuntu** — Open Ubuntu from Start Menu

**Why the Linux filesystem?** `/mnt/c/` goes through the Windows filesystem driver and is
5-10x slower for Hadoop I/O. All project files and HDFS data must live in the Linux filesystem (`~`).

```bash
# Inside WSL Ubuntu terminal:

# 1. Copy the cinescope project from Windows into your Linux home
cp -r /mnt/c/Users/aryan/.gemini/antigravity-ide/scratch/cinescope ~/cinescope

# 2. Verify the copy
ls ~/cinescope/
# Expected: README.md  config/  data/  docs/  mapreduce/  scripts/  setup_wsl.sh  ...

# 3. Make all shell scripts executable
chmod +x ~/cinescope/scripts/*.sh
chmod +x ~/cinescope/setup_wsl.sh
```

---

## STEP D — Run the Master Setup Script

> **Label: WSL Ubuntu**

```bash
# Run the complete setup (takes 20-30 min on first run due to downloads)
# The 'tee' command saves a log in case something fails
cd ~/cinescope
bash setup_wsl.sh 2>&1 | tee setup.log
```

The script installs everything in this order:
1. System packages (Java 8, SSH, Python 3.10, wget, etc.)
2. Passwordless SSH to localhost (required by Hadoop)
3. Hadoop 3.3.6
4. Hive 3.1.3 (with Guava fix)
5. Pig 0.17.0 (with Hadoop 3 classpath fix)
6. HBase 2.5.7
7. Environment variables in `~/.bashrc`
8. Python virtualenv + all packages
9. Dataset copy + sample creation
10. HDFS format + initial service start

---

## STEP E — Reload Shell and Verify

> **Label: WSL Ubuntu**

```bash
# Apply environment variables to current session
source ~/.bashrc

# Run the verification checklist
cd ~/cinescope
bash scripts/00_env_check.sh
```

**Expected output (all green):**
```
✓ OS           Ubuntu 22.04
✓ WSL          5.15.xxx-microsoft-standard-WSL2
✓ java         openjdk version "1.8.0_392"
✓ javac        javac 1.8.0_392
✓ JAVA_HOME    /usr/lib/jvm/java-8-openjdk-amd64
✓ hadoop       Hadoop 3.3.6
✓ hdfs         Hadoop 3.3.6
✓ HADOOP_HOME  /opt/hadoop-3.3.6
✓ SSH self     ok
✓ hive         Hive 3.1.3
✓ HIVE_HOME    /opt/apache-hive-3.1.3-bin
✓ pig          Pig version 0.17.0
✓ PIG_HOME     /opt/pig-0.17.0
✓ hbase        HBase 2.5.7
✓ HBASE_HOME   /opt/hbase-2.5.7
✓ python3      Python 3.10.x
✓ venv/streamlit  Streamlit, version 1.35.0
✓ venv/pandas     2.2.2
✓ venv/happybase  ok
✓ venv/scikit     1.5.0
PASSED: 20   FAILED: 0
✓ All checks passed. Environment is ready.
```

---

## STEP F — Manual Verification Commands

> **Label: WSL Ubuntu**

Run these one by one to confirm each component works:

### F1. HDFS
```bash
# Check NameNode status
hdfs dfsadmin -report

# List HDFS root (should show /cinescope directories)
hdfs dfs -ls /

# Open in browser (Windows): http://localhost:9870
```

### F2. YARN
```bash
# List running nodes
yarn node -list

# Open in browser (Windows): http://localhost:8088
```

### F3. Hive via Beeline
```bash
# Connect to HiveServer2 (password: leave blank, just press Enter)
beeline -u "jdbc:hive2://localhost:10000" -n root

# Inside beeline:
# 0: jdbc:hive2://localhost:10000> show databases;
# Expected: default
# 0: jdbc:hive2://localhost:10000> !quit
```

### F4. Pig quick test
```bash
# Test Pig in local mode (no HDFS needed)
echo "A = LOAD '~/cinescope/data/sample/ratings_sample.csv' USING PigStorage(',') AS (userId:chararray, movieId:chararray, rating:float, ts:long); DUMP A;" | pig -x local 2>&1 | tail -20
```

### F5. HBase Shell
```bash
# Open HBase shell
hbase shell

# Inside HBase shell:
# hbase:001:0> status
# Expected: 1 active master, 0 backup masters, 1 servers, 0 dead
# hbase:002:0> list
# hbase:003:0> exit
```

### F6. Python packages
```bash
source ~/cinescope/venv/bin/activate
python3 -c "
import streamlit, plotly, pandas, pyarrow, numpy, scipy, sklearn, happybase, nltk, yaml
print('All imports OK')
print(f'  pandas:     {pandas.__version__}')
print(f'  streamlit:  {streamlit.__version__}')
print(f'  sklearn:    {sklearn.__version__}')
"
deactivate
```

---

## Known Issues and Fixes

### Issue 1: "Connection refused" when SSHing to localhost
```bash
sudo service ssh start
# Then retry: ssh localhost
```

### Issue 2: Hive fails with "ClassNotFoundException: com.google.common.base.Joiner"
This is the Guava version conflict. The setup script fixes it, but if it recurs:
```bash
# Verify Guava 27 is in Hive lib:
ls /opt/apache-hive-3.1.3-bin/lib/guava*
# Should show guava-27.0-jre.jar (NOT guava-14.0.1.jar)
```

### Issue 3: Pig fails with "ClassNotFoundException" on Hadoop 3
```bash
# Check pig-env.sh was updated:
cat /opt/pig-0.17.0/conf/pig-env.sh | head -20
# Should show the PIG_CLASSPATH loop
```

### Issue 4: YARN containers killed immediately (OOM)
This is the WSL2 vmem check issue. Verify `yarn-site.xml` has:
```xml
<property>
  <name>yarn.nodemanager.vmem-check-enabled</name>
  <value>false</value>
</property>
```

### Issue 5: HBase can't connect to HDFS
```bash
# Always start HDFS BEFORE HBase
bash ~/cinescope/scripts/01_start_services.sh
# The start script handles ordering automatically
```

### Issue 6: "WARN NativeCodeLoader: Unable to load native-hadoop library"
This is a warning, not an error. Hadoop's native compression libraries aren't compiled for your architecture. Everything still works; only native Snappy compression is unavailable (we use bzip2 instead).

---

## Resource Usage Summary

| Service | RAM | CPU |
|---------|-----|-----|
| NameNode | ~300 MB | Low |
| DataNode | ~300 MB | Low (spikes during I/O) |
| ResourceManager | ~200 MB | Low |
| NodeManager | ~200 MB | Low (spikes during jobs) |
| Hive Metastore | ~300 MB | Low |
| HiveServer2 | ~300 MB | Medium |
| HBase Master | ~256 MB | Low |
| HBase RegionServer | ~512 MB | Medium |
| **Total background** | **~2.4 GB** | Low |
| Per MapReduce mapper | ~1 GB | High |
| Per MapReduce reducer | ~1 GB | High |
| **Available for jobs** | **~5.6 GB** → 3-5 parallel tasks | |

---

## Web UIs (open in Windows browser)

| Service | URL | What it shows |
|---------|-----|----------------|
| HDFS NameNode | http://localhost:9870 | Files, blocks, DataNode health |
| YARN ResourceManager | http://localhost:8088 | Running jobs, container allocation |
| Job History Server | http://localhost:19888 | Completed MR job logs |
| HBase Master | http://localhost:16010 | Table list, region info |
| CineScope Dashboard | http://localhost:8501 | Our Streamlit app |
