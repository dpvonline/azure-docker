<?php
// Called by nc-convert.sh inside the nextcloud container (stdin, PGPW in env).
// Writes the Postgres settings in one go, like ConvertType::saveDBInfo() does via
// setSystemValues(), in the same file format Nextcloud itself writes.
$file = '/var/www/html/config/config.php';
include $file;
$password = getenv('PGPW');
if ($password === false || $password === '') {
    fwrite(STDERR, "PGPW fehlt\n");
    exit(1);
}
$CONFIG['dbtype'] = 'pgsql';
$CONFIG['dbname'] = 'nextcloud';
$CONFIG['dbhost'] = 'postgres';
$CONFIG['dbuser'] = 'nextcloud';
$CONFIG['dbpassword'] = $password;
// dbport would still say 3306 (MariaDB); mysql.utf8mb4 is meaningless on Postgres.
unset($CONFIG['dbport'], $CONFIG['mysql.utf8mb4']);
file_put_contents($file, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n", LOCK_EX);
echo "config.php geschrieben\n";
