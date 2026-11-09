# The mirror pass reads its own arguments

Card 929 (S1), the advisor's ruling, narrowed by review rounds 1 and 2 of ES #82. A deploy script runs root's mirror's git with a home of its own (`env -i … HOME="$MIRROR_HOME" … "$MIRROR_GIT" -C "$MIRROR" …`), and the hook-bypass scan (decision: the-hook-bypass-scan-has-one-copy) reads that `HOME=` and that `env -i` as routes. One pass in `scripts/hook-bypass-scan.sh` lets the read-only forms through, and nothing else; the `decision:` comment beside `MIRROR` points here. In a line the pass clears, only that `HOME=` and that `-i` stop being findings. Every rule still reads the rest, and the de-quoted and decoded copies are taken from the cleared line, so they cannot bring the two back.

**The whole logical line, one word rule (review r2, F1 to F3).** The pass reads the line from its first character. It may open with blanks and one of `NAME=$(`, `local NAME=$(`, `NAME() {`, `{` or `(`. Then come `env -i`, assignments, `HOME=` one quoted variable, more assignments, a git word, `-C` and one word, at most one `-c gpg.program="$X"`, and `fetch`, `rev-parse`, `log`, `cat-file` or `merge-base`. Its arguments run to the line end, which may close with `)`, `;` or `; }`. Every word passes one rule: the git word, the `-C` word, the subcommand, each argument and each assignment's value. A word is either bash-literal, from `[A-Za-z0-9_./:@^~+=%-]` only, or exactly one double-quoted variable, `"$NAME"` or `"${NAME}"`. So nothing that bash expands into other words passes:
- no brace, glob or bracket (`{--upload-pack=x,}`, `?-upload-pack=x`, `[-]-upload-pack=x`, or `-C {/m,-c,core.sshCommand=…}`);
- no parameter operator, quoted or not (`${U:---upload-pack=…}`, `${U/#/…}`);
- no array, positional or every-argument word (`"${arr[@]}"`, `"${arr[*]}"`, `"$@"`, `"$*"`, `"$1"`);
- no unquoted variable, which bash splits and globs;
- no quote of any other shape (a subcommand argument may also join single-quoted parts, as below), no backslash or `$'…'`, and no redirection, separator, substitution or comment.

A tilde at a word start, or after `=` or `:`, is a variable too (`~-` is `$OLDPWD`), so it refuses the pass. Two words are exceptions, each written exactly: the one `-c` and the one `GIT_SSH_COMMAND` below.

**Single-quoted parts in an argument (round 3, (iii)).** After the subcommand, an argument may also join single-quoted parts (`'…'` holding no quote and no blank) to literal ones, as in `--format='%G?|%GF|%GK'`, `'+refs/heads/main:refs/heads/main'` or `'refs/heads/main^{commit}'`. Bash does nothing inside single quotes, so the word git sees is the word with its quotes taken out. No `$'` can form: a literal part never holds a `$`, and a variable word stands alone. The pass takes the quotes out of every argument before it reads one, so each option is judged as git sees it, against the same lists. `'--upload-pack=x'`, `--'upload-pack'=x` and `-'n'` refuse, as does a quote opened and never closed. Only the values of `--format=` and `--pretty=` may hold other characters, and a `--format=` value is only ever text to git. Double quotes stay allowed only as one whole `"$NAME"`, because bash expands inside them: `"${U:-…}"`, `"$@"` and `"$U"x` all refuse. The git word, the `-C` word, the subcommand and every assignment take no quotes but the one variable form.

**What may stand before `env` (round 3).** Only the openings above. A word there such as `eval`, `ssh host` or `watch` makes a shell parse the expanded values again as code. A quote, backtick or `$'` there puts the rest of the line in a string. And `cmd &&` is a second command. So each of these keeps the line a finding.

**The git word and PATH (F3, F5).** The git word is `git`, the `git` of a system directory (`/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/local/bin`, `/usr/local/sbin`), or one quoted variable whose name holds `GIT` or `git`. So `/tmp/x/git` refuses, and so does a braced or globbed path. `PATH` is one quoted variable, or a colon list of those directories, each named whole. An empty entry (`/usr/bin::/bin`, `/usr/bin:`, or an empty `PATH=`) is the working directory, so it refuses, and so does `/usr/bin/../../tmp`, because a `PATH` picks the git, ssh and gpg that run.

**Env names (B2, R6).** Each assignment's name must be `PATH`, `GNUPGHOME`, `GIT_NO_REPLACE_OBJECTS`, `HOME` (the one quoted variable home; a second `HOME=`, or an XDG home, is still a finding) or `SSH_KEY`. The one other name allowed is `GIT_SSH_COMMAND`, written exactly as `GIT_SSH_COMMAND='ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes'` (or `"${SSH_KEY}"`). It is single-quoted, so bash hands it on untouched, and the sh git runs it with expands the key once, quoted, as the argument of `-i`. Any other key name, another `-o`, an unquoted key, a double-quoted command (bash would paste the key's value into the command text) or any other value refuses the pass. Any other name refuses it too: `GIT_PROXY_COMMAND` and `GIT_ASKPASS` run their values, `GIT_ALLOW_PROTOCOL=ext` lets an `ext::` remote run a command, and `LD_PRELOAD` or `GIT_EXEC_PATH` swap the code that runs.

**One -c (R1).** Only `-c gpg.program="$X"`, which `log --format=%G…` checks signatures with. Unquoted, it word-splits into a second `-c`, so `gpg.program=$GPG` refuses the pass. So do `gpg.ssh.program`, `gpg.x509.program`, any other key, a second `-c`, a suffix on the variable, and a `-c` before `-C`.

**Each argument, and the end of options (R7).** A variable argument must come after `--end-of-options`, which each subcommand's list holds. After it, git reads every word as a remote, revision or object, never as an option. Run on git 2.39.5 (this host's version, in a throwaway container) and on 2.43 (review r2):
- `fetch --end-of-options "--upload-pack=…"` is a "strange pathname … blocked";
- `log -1 --end-of-options "--output=…"` writes nothing;
- `rev-parse --verify --end-of-options --git-path` fails the verify;
- `cat-file commit --end-of-options --textconv` and `merge-base --is-ancestor --end-of-options --octopus` are "Not a valid object name".

A plain `--` is not enough, because only fetch reads it that way. A literal argument that does not open with `-` passes. A literal option passes only on its subcommand's list, compared exactly:
- `fetch`: `--quiet`, `--no-tags`, `--prune`. So no `--upload-pack` or any prefix of it, and no `--depth`, `-q` or `--QUIET`.
- `rev-parse`: `--verify`, `--quiet`.
- `log` (R2): `-<n>`, `-n` with a number next, `--format=…` and `--pretty=…` (literal or single-quoted values). No `--ext-diff`, `--textconv`, `-p`, `--patch`, `-u`, or `--output=`, which writes a file.
- `cat-file` (R3): exactly `commit`, `tree`, `blob`, `tag`, `-t`, `-s`, `-e` or `-p`, then an optional `--end-of-options`, then one object that does not open with `-`. A variable object needs that `--end-of-options`. No `--textconv`, `--filters`, `--path` or `--batch…`.
- `merge-base` (R4): `--is-ancestor`.

Each subcommand is a builtin, which no alias can hide, and none makes a commit. `verify` is not a git command (git would run the isolated home's `alias.verify`), so it stays off the list. `rev-parse --verify` is the read.

**Known limits.** The scan reads text, not values. A variable's value is trusted to name what it should:
- `"$GPG"` names the program `log` runs for `%G?`.
- `"$MIRROR_GIT"`, or a `PATH` from a variable, names the git that runs.
- The `.gitconfig` and `.ssh/config` under `"$MIRROR_HOME"`, the mirror repository's own config, and `GNUPGHOME`'s files can each name a command, which git, ssh or gpg then runs: `remote.<name>.uploadpack`, `core.sshCommand`, `protocol.ext.allow`, `ProxyCommand`. Root on the deploy host writes these files.

A line is read alone. One inside a heredoc, or inside a string opened on an earlier line, is read as code, and a shell that parses it again (`bash <<EOF`, `eval "$x"`) turns its values into code. That is the `bash -c` gap of the scan's own decision. A function or alias named `env` or `git` changes what runs; its body is judged as usual. A prefix kept in a variable with no subcommand (`local GIT="env -i … HOME=$H $MIRROR_GIT -C $M"`), and a function handed on as a runner (`ci_evidence … mirror_run`), stay findings or unseen (card 931).

The deploy lines as written today (GC `scripts/deploy.sh`:86-89 and GW :343-346, `mirror_run`) stay findings until they are rewritten:
- The runner hands on `"$@"`. Write one function per call instead.
- Its `GIT_SSH_COMMAND` is double-quoted with an unquoted `$SSH_KEY`. Write it as the one shape above.
- Each variable needs `--end-of-options` before it. The quoted refspec, `'refs/heads/main^{commit}'` and `--format='%G?|%GF|%GK'` pass as written (single-quoted parts).

A line the pass cannot clear is rewritten as one function per call, whose body names the subcommand and spells out its arguments: `mirror_sig() { env -i PATH=/usr/bin:/bin HOME="$MIRROR_HOME" GNUPGHOME="$GNUPG" GIT_NO_REPLACE_OBJECTS=1 "$MIRROR_GIT" -C "$MIRROR" -c gpg.program="$GPG" log -1 --format='%G?|%GF|%GK' --end-of-options "$MERGE_SHA"; }`, read as `IFS='|' read -r sig gf gk <<<"$(mirror_sig)"`.
