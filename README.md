# Kasm DB

Forked version of Postgres 16 build logic located [here](https://github.com/docker-library/postgres/tree/master/16) with additional extensions needed for customer deployments.

# Using this image

This image is published at [https://hub.docker.com/r/kasmweb/postgres](https://hub.docker.com/r/kasmweb/postgres) with `kasmweb/postgres:1.18.0` being the current release, it is automatically deployed as the database container as a part of [Kasm Workspaces](https://kasm.com/downloads).

# Custom Extensions

## PGAudit

[PGAudit](https://www.pgaudit.org/) provides detailed session and/or object audit logging via the standard logging facility provided by PostgreSQL.

## Enabling the extension

### Existing deployments

The PGAudit extension will need to be enabled in `/opt/kasm/current/conf/database/postgresql.conf` this can be achieved with:

```
sudo sed -i "/^#shared_preload_libraries/c\shared_preload_libraries = 'pgaudit'" /opt/kasm/current/conf/database/postgresql.conf
```

Then the services will need to be restarted wth: 

```
sudo /opt/kasm/bin/stop
sudo /opt/kasm/bin/start
```

### New deployments

From the directory your installer is extracted to run: 

```
sed -i "/^#shared_preload_libraries/c\shared_preload_libraries = 'pgaudit'" kasm_release/conf/database/postgresql.conf
```

Now follow the standard installation using your modified installer with both the new image and `postgresql.conf` settings.

## Post deployment

Once the modifications have been made to enable the PGAudit extension you will need to enter the database to configure the extension. In this example we will be enabling logging for read, write, and ddl classes of statements. 

```
sudo docker exec -it kasm_db psql -U kasmapp -d kasm
kasm=# CREATE EXTENSION pgaudit;
CREATE EXTENSION
kasm=# ALTER DATABASE kasm set pgaudit.log='read,write,ddl';
ALTER DATABASE
```

With the extension enabled and configured the default log will produce log entries for the classes of statements you defined in the file `/opt/kasm/current/log/postgres/postgresql-*.log`

Here are the classes available for logging:

* pgaudit.log: Specifies which classes of statements will be logged by session audit logging. The default is none. Possible values are:
  * READ: SELECT and COPY when the source is a relation or a query.
  * WRITE: INSERT, UPDATE, DELETE, TRUNCATE, and COPY when the destination is a relation.
  * FUNCTION: Function calls and DO blocks.
  * ROLE: Statements related to roles and privileges: GRANT, REVOKE, CREATE/ALTER/DROP ROLE.
  * DDL: All DDL that is not included in the ROLE class.
  * MISC: Miscellaneous commands, e.g. DISCARD, FETCH, CHECKPOINT, VACUUM, SET.
  * MISC_SET: Miscellaneous SET commands, e.g. SET ROLE.
  * ALL: Include all of the above.

