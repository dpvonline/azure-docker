FROM postgres:17

# pgBackRest lives inside the same container as Postgres so archive_command
# can invoke it directly, without cross-container exec gymnastics.
RUN apt-get update \
    && apt-get install -y --no-install-recommends pgbackrest \
    && rm -rf /var/lib/apt/lists/*

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf

# The pgbackrest package locks down /etc/pgbackrest by default; the "postgres"
# user (non-root, runs archive_command) can't traverse/read it otherwise.
RUN chmod 755 /etc/pgbackrest && chmod 644 /etc/pgbackrest/pgbackrest.conf
