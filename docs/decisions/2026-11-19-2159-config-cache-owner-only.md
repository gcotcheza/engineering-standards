# The deploy lib leaves Laravel's cached config owner-only after every config:cache

`bootstrap/cache/config.php` holds APP_KEY and every database password in plain PHP. On 2026-11-19 it was 644 or 755 in all five Laravel apps on prod (card 1031, S8). `php artisan config:cache` writes it again on every deploy, and deploys now run on merge.

Every app runs `config:cache` (or `optimize`, which runs it) through `$COMPOSE`, which is the lib's `compose.sh run`. So `deploy_compose_exec` checks its own arguments after a compose call succeeds: when an `artisan` word comes before a `config:cache` or `optimize` word, it calls `config_cache_private` on the app root. No app needs its own change, and an app that adds such a call later is covered too. fleet-deploy exports every flat file under `scripts/lib/deploy/`, so `config-cache.sh` reaches the run dir with no export change (pv proved this on prod's live run dir, 2026-11-19).

`config_cache_private` makes the file 0600 and then runs the check, so a chmod that did nothing still fails the deploy. Loud is right here (C9). A cache that root owns is refused: config:cache ran as root, and the fix is in the writer. A missing cache after config:cache is refused too.

As root, the chmod runs as the file's own numeric uid and gid through `setpriv`. The tree belongs to the app user, who could swap in a link between the check and the chmod. Run as that uid, the swap can only reach files that uid could change already. `setpriv` takes numbers, because the owner is a container uid that may have no name on the host. pv confirmed on prod that the owner uid is the PHP-FPM worker uid in all five apps, so 0600 keeps the site readable to PHP.

`config_cache_check` is the VERIFY. A deploy or a health row can call it directly, or run `config-cache.sh <app-dir>` as a script. It passes when there is no cached config.

Rejected: a umask of 077 around config:cache. The lib cannot set the umask of a process inside `docker compose exec` or `run` without rewriting the app's command. The chmod straight after the call is what this change guarantees. An app may still wrap its own call in `umask 077` to close the moment between the write and the chmod. A hand-run `artisan config:cache` outside a deploy writes 0644 again, and the next deploy closes it.
