# yb-master-latency
Docker compose to start YugabyteDB with latency simulated network latency to yb-master

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










