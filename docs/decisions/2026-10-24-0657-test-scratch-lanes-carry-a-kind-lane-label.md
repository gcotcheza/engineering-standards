# The deploy-lib suite's scratch directories stay in /srv/worker-scratch and carry a kind=lane label

**Why they stay there.** card 499's lint (block 5) will refuse an unlabelled directory under `/srv/worker-scratch`.
Moving the directories to `TMPDIR` would avoid the rule, but neither can move. The suite's work directory
must sit under a root-owned 755 chain: `summary.sh`'s guard refuses `/tmp`, because everyone can
write there, and `/run` is `noexec`. Gate step 9's app-owned copy stands in for an app's tree, so it
sits under the same non-world-writable parent, and its refusals name the app-owned file as an app's
would.

**The label.** Of the label forms the lint accepts, a directory with no PR takes the `kind=lane` form:
`kind=lane`, `card=537`, `owner=${FLEET_SCRATCH_OWNER:-pv}`, with no `keep=`. A `repo=`/`pr=`
label would be refused without a real PR, and `kind=test` or `pr=none` are refused outright.

**The limit.** The reapers select by `repo=`/`pr=`, so a directory that leaks past the suite's EXIT
trap is not reaped automatically. It shows up as labelled lane work, owned by pv, for a person to
remove. A label with no `keep=` changes nothing in the deploy's own `cleanup_lanekeep` walk.
