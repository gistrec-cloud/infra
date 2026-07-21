# ─── Managed MySQL: RETIRED 2026-07-21 ───
# The shared managed Yandex MySQL cluster "projects" (id c9qiev78afki77pa8jo1,
# live since 2022) was destroyed once every database had migrated to the
# self-hosted MySQL 8.0 primary on finland-01 (ansible/roles/mysql). Off-site
# backups now ride the mysql-backup SA (bucket gistrec-cloud, prefix mysql/),
# verified by an S3 restore-drill before the teardown. Kept as a tombstone so
# the removal reads clearly in git history instead of a vanished file.
