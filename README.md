# Kasm DB

Forked version of Postgres 12 build logic located [here](https://github.com/docker-library/postgres/tree/master/12/alpine) to allow us to add modules and configure to our needs.

# Module loading

Any additional modules installed need to be added to our centralized postgres conf here: 

https://gitlab.com/kasm-technologies/internal/kasm_backend/-/blob/develop/install/conf/database/postgresql.conf#L677

IE: 

```
shared_preload_libraries = 'pgaudit'	# (change requires restart)
```
