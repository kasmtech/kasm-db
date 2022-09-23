# Kasm DB

Forked version of Postgres 12 build logic located [here](https://github.com/docker-library/postgres/tree/master/12/alpine) with additional extensions needed for customer deployments.

# Using this image

This image is pubished at [https://hub.docker.com/r/kasmweb/postgres](https://hub.docker.com/r/kasmweb/postgres) with `kasmweb/postgres:1.11.0` being the current release.

## Existing deployments

In order to integrate this image in an existing Kasm Workspaces deployment the Docker Compose files used for the deployment will need to be modified using the following command:

```
sudo sed -i 's/postgres:12-alpine/kasmweb\/postgres:1.11.0/g' /opt/kasm/current/docker/docker-compose.yaml
```

From here please follow the instructions in the [Custom Extensions](#custom-extensions) section.

## New deployments

In order to use this image you will need to modify the installer's Docker Compose files to point to this new database image. For this example we will be using the current Kasm Workspaces 1.11.0 release:

```
wget https://kasm-static-content.s3.amazonaws.com/kasm_release_1.11.0.18142e.tar.gz
tar -xf kasm_release_1.11.0.18142e.tar.gz
sed -i 's/postgres:12-alpine/kasmweb\/postgres:1.11.0/g' kasm_release/docker/docker-compose-*
```

Before installing be sure to follow the instructions in the [Custom Extensions](#custom-extensions) section.

# Custom Extenstions

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
kasm=# set pgaudit.log = 'read,write,ddl';
SET
kasm=# SELECT name,setting FROM pg_settings WHERE name LIKE 'pgaudit%';
            name            |    setting     
----------------------------+----------------
 pgaudit.log                | read,write,ddl
 pgaudit.log_catalog        | on
 pgaudit.log_client         | off
 pgaudit.log_level          | log
 pgaudit.log_parameter      | off
 pgaudit.log_relation       | off
 pgaudit.log_statement_once | off
 pgaudit.role               | 
(8 rows)
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

