FROM yugabytedb/yugabyte
RUN dnf -y install iproute-tc jq
WORKDIR /home/yugabyte
ADD print_docdb_requests.sh .
