# T9's check follows the shared deploy lib

Apps no longer vendor the deploy lib: their gates source `${DEPLOY_LIB}/ledger.sh`, with `DEPLOY_LIB` pinned to `/srv/engineering-standards/scripts/lib/deploy`. `gate-image-tags.sh` followed only sources inside the app tree, so every bare `docker compose` call below that source line came out unjudged and the check went red. Reflection's browser gate moved its ledger arm below such a call to get past it, which card 717 (arm before anything runs) forbids.

The check now resolves a source path that starts with `$DEPLOY_LIB/` or `${DEPLOY_LIB}/` against `scripts/lib/deploy` of the standards clone the check itself is running from, and accepts the result only when its real path is still inside that directory. Apps run the check from `/srv/engineering-standards`, the same clone `DEPLOY_LIB` names, so the file read is the file the gate sources. Nothing else outside the app tree is followed: not another variable, not a literal absolute path, not a `..` climbing out of the lib. A copy of the check with no `lib/deploy` beside it follows nothing outside the tree at all, so an empty lib path never matches every path.

Cases 65 to 67 in `gate-image-tags-test.sh` hold each part, and each goes red when its line is deleted.
