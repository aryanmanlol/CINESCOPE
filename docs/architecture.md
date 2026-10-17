# CineScope — System Architecture

## Mermaid Architecture Diagram

```mermaid
flowchart TD
    subgraph SOURCES["📁 Data Sources (Windows /mnt/c)"]
        R["ratings.csv\n26M rows"]
        M["movies_metadata.csv\n45k rows"]
        L["links.csv\nbridges movieId↔tmdbId"]
        K["keywords.csv"]
        C["credits.csv"]
    end

    subgraph WSL["🐧 WSL2 Ubuntu 22.04 (Linux filesystem ~/cinescope)"]

        subgraph HDFS["HDFS — Hadoop 3.3.6 (64MB blocks, replication=1)"]
            RAW["/cinescope/raw/\nraw CSVs"]
            CLEAN["/cinescope/clean/\nPig-cleaned TSVs"]
            WH["/cinescope/warehouse/\nHive ORC tables"]
            MR_OUT["/cinescope/mr/\nMapReduce outputs"]
            SERVING_HDFS["/cinescope/serving/\nexported parquet"]
        end

        subgraph BATCH["⚙️ Batch Processing Layer"]
            direction TB
            PIG["Apache Pig 0.17\nETL: clean, join, dedup\nparse JSON genres\nPig Latin + UDF"]
            HIVE["Apache Hive 3.1.3\nORC tables (Snappy)\nPartitioned by year\nBucketed by movie\nBayesian WR, RANK()"]
            CF["MapReduce — CF\nJob 1: User Vectors\nJob 2: Pair Similarity\nJob 3: Top-K Neighbors"]
            SEARCH["MapReduce — Search\nJob A: Postings (TF)\nJob B: TF-IDF + BM25"]
            NB["MapReduce — Naive Bayes\nTrain: counts job\nClassify: map-only"]
            KM["MapReduce — K-Means\nIterative driver loop\nCombiner for partial sums"]
        end

        subgraph SERVING["🗃️ Serving Layer"]
            HBASE["HBase 2.5.7\n'movies' table\ncf: meta, cf, stats\nrow key = movieId\nThrift port 9090"]
            PARQUET["data/serving/\n*.parquet files\n(fallback when HBase\nis not running)"]
        end

        subgraph DASHBOARD["🎬 Streamlit Dashboard (port 8501)"]
            HOME["Home / Discover\nBayesian top movies\nPoster grid by genre"]
            RECS["Because You Liked...\nCF + Content blend\nExplanation chips"]
            SRCH["Search\nTF-IDF vs BM25\nLive index stats"]
            PRED["Genre Predictor\nNaive Bayes model\nProbability bars"]
            INS["Insights\nAll Plotly charts\nPre-aggregated only"]
            PIPE["Pipeline Explorer\njob_metrics.csv\nHDFS stats"]
        end

    end

    SOURCES -->|"hdfs dfs -put\n10_ingest_hdfs.sh"| RAW
    RAW --> PIG
    PIG --> CLEAN
    CLEAN --> HIVE
    CLEAN --> CF
    CLEAN --> SEARCH
    CLEAN --> NB
    HIVE -->|"movie whitelist\ndistributed cache"| CF
    HIVE -->|"feature vectors"| KM
    HIVE --> WH
    CF --> MR_OUT
    SEARCH --> MR_OUT
    NB --> MR_OUT
    KM --> MR_OUT
    WH --> SERVING_HDFS
    MR_OUT --> SERVING_HDFS
    SERVING_HDFS -->|"60_export_serving.sh\nhdfs dfs -get"| PARQUET
    SERVING_HDFS -->|"50_load_hbase.sh\nhappybase batch"| HBASE
    HBASE -->|"Thrift API\nhappybase"| HOME
    HBASE --> RECS
    PARQUET -->|"fallback"| HOME
    PARQUET --> RECS
    PARQUET --> SRCH
    PARQUET --> PRED
    PARQUET --> INS
    PARQUET --> PIPE
```

---

## Component Responsibilities

### HDFS (Unit 2)
- **NameNode**: Stores filesystem metadata (file → block mapping). Does NOT store data.
- **DataNode**: Stores actual 64 MB blocks. One DataNode in pseudo-distributed mode.
- **Block size = 64 MB**: ratings.csv (~700 MB) splits into ~11 blocks → ~11 map tasks.
- **Replication = 1**: Single DataNode, so we can't replicate. Real clusters use 3.

### Pig ETL (Unit 4 — Pig)
- Reads malformed CSV (CSVExcelStorage handles embedded newlines/quotes)
- Filters bad rows (non-numeric id), deduplicates, joins with links
- Parses genres (stored as `[{'id': 18, 'name': 'Drama'}, ...]`) via Jython UDF
- Output: clean tab-delimited files in `/cinescope/clean/`

### Hive Warehouse (Unit 4 — Hive)
- External tables over cleaned HDFS data (no data copy)
- Managed ORC tables with Snappy compression for analytics
- Ratings partitioned by `rating_year` (partition pruning skips irrelevant years)
- Ratings bucketed by `movie_id` (sort-merge join without full shuffle)
- Computes: avg rating, Bayesian WR, genre stats, temporal analysis, choropleth data

### MapReduce Jobs (Unit 3 + Unit 6)
- **CF 3-job chain**: User vectors → pair similarities → top-K neighbors
- **Search 2-job chain**: Postings (TF) → TF-IDF/BM25 weights
- **Naive Bayes**: Training count job + map-only classification job
- **K-Means**: Iterative jobs with combiner (partial sum optimization)

### HBase Serving (Unit 4 — HBase)
- Pre-loaded with movie metadata + CF neighbors + cluster labels
- Row key = zero-padded movieId (enables efficient prefix scans)
- Dashboard reads via Thrift; falls back to parquet files if HBase is down

### Streamlit Dashboard (Unit 5 — Visualization)
- ALL charts built from pre-aggregated Hive/MR outputs (never scans raw data)
- Poster URLs: `https://image.tmdb.org/t/p/w342{poster_path}`
- Session state tracks liked movies (no user login required)

---

## Data Flow: A Rating Arrives

```
User rates a movie (in production)
  → Flume agent captures event
  → Written to HDFS /cinescope/raw/ratings/ as Avro
  → Nightly Pig job cleans and deduplicates
  → Hive recomputes Bayesian WR and stats
  → MapReduce CF job updates similarity scores
  → Results loaded into HBase
  → Dashboard serves updated recommendations next morning
```

(In our batch project, steps 1-2 are replaced by `hdfs dfs -put ratings.csv`)

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Execution engine | MapReduce (not Tez/Spark) | Syllabus requirement; demonstrates MR concepts |
| Metastore | Derby embedded | Zero-config for single-user dev |
| HBase mode | Standalone | Minimal JVMs; sufficient for serving |
| Block size | 64 MB (not 128) | More visible block splits for demonstration |
| Replication | 1 | Single DataNode constraint |
| CF algorithm | Item-based (not user-based) | Scales better: movie catalog < user count |
| Search | TF-IDF + BM25 | Demonstrates both models; enables comparison |
| Pig → Hadoop 3 | Custom pig-env.sh | Classpath fix for moved MR jars |
| Hive → Hadoop 3 | Replace Guava 14 with 27 | Known Hive 3 / Hadoop 3 dependency clash |
