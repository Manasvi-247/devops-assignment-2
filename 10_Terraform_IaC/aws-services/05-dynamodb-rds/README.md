# DynamoDB and RDS

Two managed database services that solve different problems. Choosing between
them is mostly a question of whether your access patterns are known in advance.

---

## DynamoDB

A managed NoSQL key value and document store. There is no server to size and no
connection pool, just an HTTP API.

### Structure

| Term | Relational equivalent |
|---|---|
| Table | table |
| Item | row |
| Attribute | column, except items need not share them |

Items in one table can have completely different attributes. Only the key has
to be present.

### Keys decide everything

The **partition key** is hashed to pick a physical partition. A **sort key** is
optional and orders items within that partition.

Together they are the primary key, and they are the only efficient way to read.
Anything else is a `Scan`, which reads the whole table and gets slower as the
table grows. Secondary indexes exist to add access patterns, at the cost of
extra storage and writes.

This is the real difference from SQL. In a relational database you model the
data and write queries later. In DynamoDB you must know the access patterns
first, because they decide the key design, and changing a partition key later
means rewriting the table.

### Capacity

On-demand bills per request and needs no planning. Provisioned is cheaper at
steady high volume and throttles when exceeded.

### Where it fits

Session stores, shopping carts, IoT telemetry, anything with a known lookup
pattern and high request rates. A bad fit for reporting or ad hoc queries.

---

## RDS

Managed relational databases. You still get a real database with SQL, joins and
transactions; AWS takes over the operational work.

### Engines

PostgreSQL, MySQL, MariaDB, Oracle, SQL Server, and Aurora, which is Amazon's
own engine that is wire compatible with PostgreSQL and MySQL.

### What managed means

AWS handles patching, backups, failover and replica setup. You do not get OS
access, which is the trade: no `sudo`, and no extension that is not on the
approved list.

### Multi-AZ and read replicas

These are different things and are often confused.

| | Multi-AZ | Read replica |
|---|---|---|
| Purpose | availability | scaling reads |
| Standby | not readable | readable |
| Failover | automatic | manual promotion |
| Replication | synchronous | asynchronous |

Multi-AZ gives you nothing extra to query. It exists so a zone failure is a
short reconnect rather than an outage.

### Backups

Automated backups support point in time recovery within the retention window,
up to 35 days. Manual snapshots persist until deleted. **Deleting the instance
deletes the automated backups**, so a final snapshot is the thing to take
first.

### Security

Put it in a **private subnet**, allow its port only from the application's
security group rather than a CIDR, enable encryption at rest at creation time
because it cannot be turned on later, and keep the credentials in Secrets
Manager rather than in environment variables.

---

## Choosing

| Need | Service |
|---|---|
| Joins, transactions, ad hoc queries | RDS |
| Known access patterns, very high request rates | DynamoDB |
| Predictable single digit millisecond reads at any scale | DynamoDB |
| An existing application that speaks SQL | RDS |

The TaskBoard application in this repository uses PostgreSQL precisely because
its queries are relational and small. On AWS it would be an RDS instance in a
private subnet.
