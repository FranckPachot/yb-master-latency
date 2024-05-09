{
curl -s yb-master:7000/dump-entities?raw | jq -r '.tables[] | "table_id"  + "\t" + .table_id + "\t" + .table_name' 
cat /home/yugabyte/data/yb-data/tserver/logs/postgresql-*.log
} | awk '
/LOG:  statement:/{
 print
}
/^table_id\t/{
 t[$2]=$3
}
/Applying operation: { READ/{
 id=gensub(/.* table_id: "([0-9a-f]+)".*/,"\\1",1) 
 c[t[id]]=c[t[id]]+1
}
/Flushing collected operations/{
 sub(/^.*Flushing collected operations, using session type:/,"Flushing") 
 s="" ; for ( i in c ) s=s" "i" ("c[i]")" ; delete c
 print $0": " s
}
'
