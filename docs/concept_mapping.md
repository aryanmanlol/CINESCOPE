# Syllabus Concept → CineScope File Mapping

This table maps every topic from the Big Data Analytics syllabus
to the specific file(s) in this project that demonstrate it.

---

## Full Concept Mapping Table

| Syllabus Topic | Specific Concept | File(s) | Phase |
|----------------|-----------------|---------|-------|
| **Big Data Introduction** | Why Hadoop, V's of Big Data | `README.md`, `docs/architecture.md` | 0 |
| **Hadoop Ecosystem** | HDFS + YARN + MR + Pig + Hive + HBase | `docs/architecture.md`, `scripts/01_start_services.sh` | 0 |
| **HDFS — Design** | Block storage, NameNode/DataNode, replication | `config/hadoop/hdfs-site.xml`, `scripts/11_hdfs_inspect.sh` | 1 |
| **HDFS — CLI** | dfs -put, -ls, -du, fsck, dfsadmin | `scripts/10_ingest_hdfs.sh`, `scripts/11_hdfs_inspect.sh` | 1 |
| **HDFS — Data Flow** | Write pipeline (client→NN→DN chain) | `docs/architecture.md` | 1 |
| **HDFS — I/O** | InputFormat, block splitting, map tasks | `mapreduce/cf/job1_user_vectors/mapper.py`, `config/hadoop/hdfs-site.xml` | 1, 4A |
| **HDFS — Compression** | gzip (non-splittable) vs bzip2 vs Snappy | `scripts/12_compression_experiment.sh`, `reports/storage_comparison.csv` | 1 |
| **HDFS — Serialization / Avro** | Avro schema, SequenceFile, ORC, Parquet | `scripts/12_compression_experiment.sh` | 1 |
| **Flume / Sqoop (production)** | Where they'd fit in a real pipeline | `docs/concept_mapping.md` (this file) | 1 |
| **MapReduce — Anatomy** | map(), reduce(), shuffle & sort | `mapreduce/cf/job1_user_vectors/` | 4A |
| **MapReduce — Shuffle & Sort** | Partitioner, key sort, merge | `mapreduce/cf/job2_pair_similarity/` (pair explosion section) | 4A |
| **MapReduce — Task Execution** | Attempt IDs, speculative execution, counters | `mapreduce/cf/job1_user_vectors/reducer.py` (counters) | 4A |
| **MapReduce — Types & Formats** | Text, Sequence, custom partitioner | `mapreduce/cf/job3_top_neighbors/` (KeyFieldBasedPartitioner) | 4A |
| **MapReduce — Features** | Combiner, distributed cache, streaming | All `mapreduce/` subdirs | 4A–4D |
| **Pig — Execution Modes** | Local vs MapReduce mode | `scripts/20_run_pig_etl.sh` | 2 |
| **Pig — Pig Latin** | LOAD, FILTER, JOIN, GROUP, FOREACH, STORE | `pig/clean_movies.pig`, `pig/join_links.pig` | 2 |
| **Pig — UDFs** | Jython UDF (parse_genres.py) | `pig/udfs/parse_genres.py` | 2 |
| **Pig — EXPLAIN** | Logical/Physical/MR plan | `scripts/20_run_pig_etl.sh` (EXPLAIN output) | 2 |
| **Pig vs Databases** | Declarative query differences | `docs/concept_mapping.md` (below) | 2 |
| **Hive — Shell / Services** | CLI, HiveServer2, Beeline | `scripts/30_hive_setup.sh`, `scripts/31_hive_analytics.sh` | 3 |
| **Hive — Metastore** | Derby embedded, table schemas, partitions | `config/hive/hive-site.xml`, `hive/01_external_tables.hql` | 3 |
| **Hive — HiveQL** | DDL, DML, window functions, LATERAL VIEW | `hive/03_analytics.hql` | 3 |
| **Hive — Tables** | External vs Managed, ORC, partitioning, bucketing | `hive/02_orc_partitioned_bucketed.hql` | 3 |
| **Hive — UDFs** | TRANSFORM with Python script | `hive/udf/clean_text_transform.py`, `hive/03_analytics.hql` | 3 |
| **Hive vs RDBMS** | No updates, batch-only, partition pruning | `docs/concept_mapping.md` (below) | 3 |
| **HBase — Concepts** | Column families, row keys, regions, ZooKeeper | `hbase/create_tables.hbase`, `docs/concept_mapping.md` | 5 |
| **HBase — Clients** | Shell, Java API (via happybase/Thrift) | `hbase/hbase_shell_demo.md`, `hbase/load_data.py` | 5 |
| **HBase vs RDBMS** | Schema-less, no joins, horizontal scale | `README.md` (comparison table) | 5 |
| **Big SQL** | Comparison with Hive | `docs/concept_mapping.md` (below) | 3 |
| **Visualization — Need** | Why visualize Big Data | `dashboard/pages/4_Insights.py` | 7 |
| **Visualization — Techniques** | Histogram, heatmap, choropleth, scatter | All charts in `dashboard/pages/4_Insights.py` | 7 |
| **Visualization — Big Data Challenges** | Overplotting, latency, 26M points | Pre-aggregation in Hive; sampling for t-SNE | 7 |
| **Collaborative Filtering** | Item-based CF with adjusted cosine | `mapreduce/cf/` (3-job chain) | 4A |
| **Classification** | Multinomial Naive Bayes for genre | `mapreduce/naive_bayes/`, `analysis/nb_eval.py` | 4C |
| **Clustering** | Iterative k-means in MapReduce | `mapreduce/kmeans/`, `analysis/tsne_projection.py` | 4D |
| **Text Data Mining** | TF-IDF, BM25, stemming, inverted index | `mapreduce/search/` | 4B |
| **Information Retrieval Models** | Vector space model, BM25 | `mapreduce/search/jobB_weights/` | 4B |
| **Search Engine Evaluation** | P@10, R@10, MAP, nDCG | `analysis/search_eval.py`, `reports/search_eval_results.csv` | 6 |
| **Spatial-Temporal Data** | Rating by year/month, country choropleth | `hive/04_spatial_temporal.hql`, `dashboard/pages/4_Insights.py` | 3, 7 |

---

## Where Flume and Sqoop Would Fit (Production)

In a **production CineScope** with a real transactional database and live data:

| Tool | Role in Production CineScope |
|------|------------------------------|
| **Apache Flume** | Stream new user ratings from a web API into HDFS in near-real-time. Flume agents would run on web servers, collect rating events, and write Avro-encoded batches to HDFS every 5 minutes. In our batch-only project, we simulate this with `hdfs dfs -put`. |
| **Apache Sqoop** | Import the `movies_metadata` and `links` tables from a relational database (e.g., MySQL populated from TMDB's API) into HDFS. Sqoop generates MapReduce jobs to parallel-import table slices. In our project, we use CSV files directly. |

---

## Pig vs Databases (Comparison)

| Feature | Pig | RDBMS (MySQL) |
|---------|-----|----------------|
| Query language | Pig Latin (procedural, step-by-step) | SQL (declarative) |
| Schema | Schema-on-read | Schema-on-write |
| Optimization | Manual (you choose the order of ops) | Query optimizer |
| Joins | Explicit, must fit in memory or use specific join types | Flexible (hash, merge, loop) |
| Best for | Multi-step ETL transformations on HDFS data | Ad-hoc queries, OLTP |
| Transactions | None | ACID |
| Our use | Clean CSVs, join links, parse JSON genres | N/A |

---

## Hive vs RDBMS (Comparison)

| Feature | Hive | RDBMS (PostgreSQL) |
|---------|------|--------------------|
| Query language | HiveQL (SQL-like) | SQL |
| Execution | MapReduce jobs (batch) | In-process query engine |
| Latency | Minutes (MR overhead) | Milliseconds to seconds |
| Data updates | Append-only (INSERT OVERWRITE) | Full CRUD |
| Schema enforcement | On read (schema-on-read) | On write (strict) |
| Partitioning | Explicit (PARTITIONED BY) | Table partitioning (limited) |
| Bucketing | CLUSTERED BY for join optimization | Index-based |
| Best for | Analytics on 100GB–PB data | OLTP, complex joins |
| Our use | Compute stats, ratings analysis, serve data | N/A |

---

## Big SQL vs Hive (Brief Comparison)

**IBM Big SQL** is an enterprise SQL-on-Hadoop engine (part of IBM Analytics):

| Feature | Big SQL | Hive |
|---------|---------|------|
| ANSI SQL compliance | Higher (full ANSI SQL-2003) | Partial |
| Execution engine | Massively Parallel Processing (MPP) | MapReduce / Tez |
| Latency | Lower (MPP avoids MR overhead) | Higher |
| JDBC/ODBC | Yes (enterprise-grade) | Yes (via HiveServer2) |
| Transactions | ACID (full) | Limited ACID (Hive 3+) |
| Cost | Commercial (IBM) | Free / Apache |
| Our choice | Hive — free, open source, demonstrates MR | — |
