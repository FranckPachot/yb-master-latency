# yb-master-latency
Docker compose to start YugabyteDB lab with simulated network latency to yb-master

Start it with:
```
docker compose down
docker compose up -d
```

You can check the latency from http://localhost:7000/tablet-server-clocks (here 50 milliseconds):
![image](https://github.com/FranckPachot/yb-master-latency/assets/33070466/4606dae5-9589-4a4c-b6a8-7a9a6e084329)

You can connect to YSQL with:
```
docker compose exec -it yb-tserver ysqlsh -h yb-tserver
```

## Example

Here is an example creating a table with 3 partitions (hash partition for the demo - you probably [don't need it in YugabyteDB](https://www.yugabyte.com/blog/postgresql-advanced-partitioning-by-date/)):
```
\pset pager off
\timing on
drop table if exists t1;
create table t1 ( id bigserial primary key, value int ) partition by hash(id);
select format(
 'create  table %I partition of %I for values with ( modulus %s, remainder %s)'
 , 't1_'||to_char(num,'FM099') , 't1' , max(num)over(), num-1
 ) from generate_series(1,3) num
;
\gexec
insert into t1 (value) select generate_series(1,1000);
\d
```

I can see that the first query in a new connection takes more time, because it has to read the catalog, but next executions have it in cache:
```
yugabyte=# \c
You are now connected to database "yugabyte" as user "yugabyte".
yugabyte=# \timing on
Timing is on.
yugabyte=# update t1 set value=value+1 where id=42;
UPDATE 1
Time: 4410.552 ms (00:04.411)
yugabyte=# update t1 set value=value+1 where id=42;
UPDATE 1
Time: 5.528 ms
yugabyte=# update t1 set value=value+1 where id=42;
UPDATE 1
Time: 5.561 ms
```

If you run it with `explain (analyze, dist)` you will see 77 `Catalog Read Requests` with `Catalog Read Execution Time: 3924.199 ms` for the first execution in a new connection, which is expected given the latency: 77 * 50ms = 3850s

The subsequent executions have the catalog information cached, requiring no additional read requests. One way to pre-warm this cache is to EXPLAIN (without ANALYZE not to execute it) the query that reads all necessary metadata:
```
yugabyte=# \c
You are now connected to database "yugabyte" as user "yugabyte".
yugabyte=# explain update t1 set value=value+1 where id=42;
                                   QUERY PLAN
---------------------------------------------------------------------------------
 Update on t1  (cost=0.00..12.35 rows=3 width=44)
   Update on t1_001
   Update on t1_002
   Update on t1_003
   ->  Index Scan using t1_001_pkey on t1_001  (cost=0.00..4.12 rows=1 width=44)
         Index Cond: (id = 42)
   ->  Index Scan using t1_002_pkey on t1_002  (cost=0.00..4.12 rows=1 width=44)
         Index Cond: (id = 42)
   ->  Index Scan using t1_003_pkey on t1_003  (cost=0.00..4.12 rows=1 width=44)
         Index Cond: (id = 42)
(10 rows)

Time: 4096.334 ms (00:04.096)
yugabyte=# update t1 set value=value+1 where id=42;
UPDATE 1
Time: 8.066 ms
yugabyte=# update t1 set value=value+1 where id=42;
UPDATE 1
Time: 4.623 ms
```

## Tracing requests

If you want more details about the read requests, you can run `\! sh print_docdb_requests.sh` after setting `yb_debug_log_docdb_requests=on`.

Here is an example to show that an EXPLAIN SELECT is not sufficient to cache all catalog info required by an UPDATE:

```
yugabyte=# \c
You are now connected to database "yugabyte" as user "yugabyte".
yugabyte=# explain select from t1 where id=42;
                                   QUERY PLAN
--------------------------------------------------------------------------------
 Append  (cost=0.00..4.12 rows=1 width=0)
   ->  Index Scan using t1_001_pkey on t1_001  (cost=0.00..4.11 rows=1 width=0)
         Index Cond: (id = 42)
(3 rows)

Time: 3736.814 ms (00:03.737)

yugabyte=# set log_statement='all';
SET
Time: 0.424 ms
yugabyte=# set yb_debug_log_docdb_requests=on;
SET
Time: 0.390 ms

yugabyte=# explain (analyze, dist) update t1 set value=value+1 where id=42;
                                                        QUERY PLAN
---------------------------------------------------------------------------------------------------------------------------
 Update on t1  (cost=0.00..12.35 rows=3 width=44) (actual time=6.985..6.985 rows=0 loops=1)
   Update on t1_001
   Update on t1_002
   Update on t1_003
   ->  Index Scan using t1_001_pkey on t1_001  (cost=0.00..4.12 rows=1 width=44) (actual time=0.769..0.773 rows=1 loops=1)
         Index Cond: (id = 42)
         Storage Table Read Requests: 1
         Storage Table Read Execution Time: 0.505 ms
         Storage Table Rows Scanned: 1
         Storage Table Write Requests: 1
   ->  Index Scan using t1_002_pkey on t1_002  (cost=0.00..4.12 rows=1 width=44) (actual time=5.484..5.484 rows=0 loops=1)
         Index Cond: (id = 42)
         Storage Table Read Requests: 1
         Storage Table Read Execution Time: 0.413 ms
         Storage Flush Requests: 1
         Storage Flush Execution Time: 4.207 ms
   ->  Index Scan using t1_003_pkey on t1_003  (cost=0.00..4.12 rows=1 width=44) (actual time=0.541..0.541 rows=0 loops=1)
         Index Cond: (id = 42)
         Storage Table Read Requests: 1
         Storage Table Read Execution Time: 0.388 ms
 Planning Time: 103.317 ms
 Execution Time: 7.103 ms
 Storage Read Requests: 3
 Storage Read Execution Time: 1.306 ms
 Storage Rows Scanned: 1
 Storage Write Requests: 1
 Catalog Read Requests: 6
 Catalog Read Execution Time: 306.243 ms
 Catalog Write Requests: 0
 Storage Flush Requests: 1
 Storage Flush Execution Time: 4.207 ms
 Storage Execution Time: 311.756 ms
 Peak Memory Usage: 82 kB
(33 rows)

Time: 420.568 ms
```
There are 6 additional `Catalog Read Requests` which are visible as `kCatalog` operations:
```
yugabyte=# \! sh print_docdb_requests.sh

2024-05-09 20:49:26.806 UTC [2343] LOG:  statement: set yb_debug_log_docdb_requests=on;
2024-05-09 20:49:45.305 UTC [2343] LOG:  statement: explain (analyze, dist) update t1 set value=value+1 where id=42;
Flushing kCatalog num ops: 1:  pg_attribute (1)
Flushing kCatalog num ops: 1:  pg_operator_oprname_l_r_n_index (1)
Flushing kCatalog num ops: 1:  pg_operator (1)
Flushing kCatalog num ops: 1:  pg_proc (1)
Flushing kCatalog num ops: 1:  pg_proc (1)
Flushing kCatalog num ops: 1:  pg_type (1)
Flushing kTransactional num ops: 1:  t1_001 (1)
Flushing kTransactional num ops: 1:  t1_002 (1)
Flushing kTransactional num ops: 1:  t1_003 (1)
Flushing kCatalog num ops: 1:  pg_class (1)
```

## ysql_catalog_preload_additional_tables=true

When starting the `yb-tserver` with `--ysql_catalog_preload_additional_tables=true` in the docker compose file, the first statement is much faster because [more](https://github.com/yugabyte/yugabyte-db/blame/2.23.0.1141/src/postgres/src/backend/utils/cache/relcache.c#L2737) tables are [loaded at connection time](https://github.com/yugabyte/yugabyte-db/blame/2.23.0.1141/src/postgres/src/backend/utils/cache/relcache.c#L2853)
```
yugabyte=# \c
You are now connected to database "yugabyte" as user "yugabyte".

yugabyte=# \! curl -s yb-tserver:9000/varz?raw | grep preload
--ysql_catalog_preload_additional_table_list=
--ysql_catalog_preload_additional_tables=true
--ysql_minimal_catalog_caches_preload=false


yugabyte=# explain (analyze, dist) update t1 set value=value+1 where id=42;
..
 Planning Time: 206.543 ms
 Execution Time: 57.668 ms
...
 Catalog Read Requests: 8
 Catalog Read Execution Time: 407.792 ms
...

```
