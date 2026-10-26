#!/usr/bin/env bash
# The cases for scripts/hook-bypass-scan.sh: one per route, comments, near misses, and git failing (Fineprint's, plus ES's routes).
# HOOK_BYPASS_SCAN names the scanner under test (mutants). A fixture line's @ is dropped as it is written: it splits
# each route below, since the scanner drops an empty quote pair and would read this file as the routes.
# shellcheck disable=SC2016,SC1003
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${HOOK_BYPASS_SCAN:-${SCRIPT_DIR}/hook-bypass-scan.sh}"
[[ -r "${SCAN}" ]] || { printf 'hook-bypass-scan-test: %s is missing, so these cases examined nothing.\n' "${SCAN}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILURES=0
PASSED=0
ok()  { printf 'ok   %s\n' "$*"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# A fresh repository holding the file and a clean one, untracked: the scan lists them as gitleaks does.
fixture() { # <file> <line>... -> repo path
    local repo
    repo="$(mktemp -d "${WORK}/case.XXXXXX")"
    git -C "${repo}" init -q
    mkdir -p "${repo}/$(dirname -- "$1")"
    local lines=("${@:2}")
    printf '%s\n' "${lines[@]//@/}" >"${repo}/$1"
    printf 'clean\n' >"${repo}/clean.txt"
    printf '%s' "${repo}"
}

# <label> <want rc> <file> <line>...: rc 1 must name <file>:${AT:-1}.
expect() {
    local label="$1" want="$2" at="${AT:-1}" repo rc out
    repo="$(fixture "${@:3}")"
    rc=0; out="$(bash "${SCAN}" "${repo}" 2>&1)" || rc=$?
    if [[ "${rc}" -ne "${want}" ]]; then
        bad "${label}: exit ${rc}, wanted ${want}: ${out}"
    elif [[ "${want}" -eq 1 && "${out}" != *"hook-bypass-scan: $3:${at}:"* ]]; then
        bad "${label}: refused without naming $3:${at}: ${out}"
    else
        ok "${label}"
    fi
}

# --- each route is a finding ------------------------------------------------
expect 'the long flag' 1 scripts/a.sh 'git commit --no-@verify -m x'
expect 'a prefix of the long flag, in capitals' 1 scripts/a.sh 'git commit --No-@Veri -m x'
expect "husky's off switch" 1 scripts/a.sh 'HUSKY@=0 git commit -m x'
expect 'the -c form' 1 scripts/a.sh 'git -c core.hooks@Path=/dev/null commit -m x'
expect 'the config form, with a space' 1 scripts/a.sh 'git config core.hooks@Path .githooks'
expect 'the config form, key in single quotes' 1 scripts/a.sh "git config 'core.hooks@Path' .githooks"
expect 'the config form, key in double quotes' 1 scripts/a.sh 'git config "core.hooks@Path" .githooks'
for shim in GLOBAL SYSTEM NOSYSTEM COUNT KEY_0 VALUE_0 PARAMETERS; do
    expect "the GIT_CONFIG_${shim} shim" 1 scripts/a.sh "export GIT_CONFIG_@${shim}=x"
done
expect 'a short cluster carrying n' 1 scripts/a.sh 'git commit -q@n -m x'
expect 'the short flag alone' 1 scripts/a.sh 'git -C "$dir" commit -@n -m x'
expect 'the short flag after a double-quoted message' 1 scripts/a.sh 'git commit -m "msg" -@n'
expect 'the short flag after a single-quoted message' 1 scripts/a.sh "git commit -m 'x' -@n"
expect 'the short flag after an escaped quote inside a message' 1 scripts/a.sh 'git commit -m "a \" b" -@n'
expect 'the short flag in an argv array' 1 tests/A.php "\$p = new Process(['git', 'commit', '-@n']);"
expect 'the short flag later in an argv array' 1 e2e/a.js "spawn('git', ['commit', '-m', 'x', '-@qn']);"
expect 'a top-level file named like an awk assignment' 1 'a=b.sh' 'git commit --no-@verify -m x'
AT=2 expect 'the line after a comment that ends in a backslash' 1 scripts/a.sh '# a note \' 'git commit --no-@verify -m x'
expect 'the short flag on a continuation line' 1 scripts/a.sh 'git commit -q \' '    -@n -m x'
expect 'a last line that ends in a backslash' 1 scripts/a.sh 'git commit --no-@verify \'
expect 'a commit made below the hooks' 1 scripts/a.sh 'tree=$(git commit-@tree HEAD^{tree} -m x)'
expect 'a shell case arm is code, not a comment' 1 scripts/a.sh '    *) git commit --no-@verify ;;'
expect 'a PHP string' 1 tests/A.php "    \$command = 'git commit --no-@verify';"
expect 'a Markdown file outside docs/' 1 README.md 'Run `git commit --no-@verify` when it blocks.'
expect 'a manifest' 1 composer.json '"hooks": "git config core.hooks@Path .githooks"'
expect 'a JSON-escaped key' 1 composer.json '"hooks": "git config \"core.hooks@Path\" .githooks"'
expect 'the short flag in single quotes' 1 scripts/a.sh "git commit '-@n' -m x"
expect 'the short flag in double quotes' 1 scripts/a.sh 'git commit "-@n" -m x'
expect 'a quoted cluster carrying n, after a message' 1 scripts/a.sh "git commit -m x '-a@n'"
expect 'a quoted cluster that ends in m' 1 scripts/a.sh 'git commit "-@nm" x'
AT=4 expect 'an argv array, one element per line' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-@n'," ']);'
AT=4 expect 'a shell array, one element per line' 1 scripts/a.sh 'args=(' '    git' '    commit' '    -@n' ')'
AT=3 expect 'an argv array that goes on to one element per line' 1 tests/A.php "\$p = new Process(['git', 'commit'," "    '-m', 'x'," "    '-q@n'," ']);'
expect 'the long flag on a continuation line' 1 scripts/a.sh 'git commit -q \' '    --no-@verify'
expect 'a quoted flag after a single-quoted message' 1 scripts/a.sh "git commit -m 'msg' '-@n'"
expect 'a quoted flag after a double-quoted message' 1 scripts/a.sh 'git commit -m "$msg" "-@n"'
expect 'a quoted flag after a message glued to -m' 1 scripts/a.sh "git commit -m'msg' '-@n'"
expect 'a quoted cluster after a quoted author' 1 scripts/a.sh "git commit --author 'A' '-a@n'"
expect 'a quoted flag before a closing double quote' 1 tests/A.php "exec(\"git commit -m x '-@n'\");"
expect 'a quoted flag before a closing single quote' 1 tests/A.php "Process::fromShellCommandline('git commit \"-@n\"');"
expect 'a quoted flag before a closing paren' 1 scripts/a.sh "x=\$(git commit '-@n')"
expect 'the short flag before the paren of $(...)' 1 scripts/a.sh 'x=$(git commit -@n)'
expect 'the short flag before the paren of a subshell' 1 scripts/a.sh '(git commit -@n)'
AT=4 expect 'one element per line, the closer on the last' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-@n']);"
AT=4 expect 'a shell array, the closer on the last element' 1 scripts/a.sh 'args=(' '    git' '    commit' '    -@n)'
AT=6 expect 'one element per line, past a call' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-m'," '    sprintf("%s", $m),' "    '-@n'," ']);'
AT=5 expect 'one element per line, past a ternary' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    \$q ? '-q' : '-v'," "    '-@n'," ']);'
AT=5 expect 'a shell array with a blank line in it' 1 scripts/a.sh 'args=(' '    git' '    commit' @ '    -@n' ')'
AT=4 expect 'one element per line, a call chained on the closer' 1 tests/A.php '(new Process([' "    'git'," "    'commit'," "    '-@n']))->run();"
AT=4 expect 'one element per line, more arguments after the closer' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-@n'], \$cwd);"
AT=4 expect 'one element per line, a quoted argument after the closer' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-@n'], '/tmp');"
AT=4 expect 'one element per line, a keyword with a quoted value after the closer' 1 scripts/a.py 'subprocess.run([' '    "git",' '    "commit",' '    "-@n"], cwd="/repo")'
AT=3 expect 'one element per line, an options object holding a string after the closer' 1 scripts/a.js 'spawn("git", [' "  'commit'," "  '-@n'], { stdio: 'inherit' });"
AT=4 expect 'one element per line, a method with a quoted argument on the closer' 1 scripts/a.js 'const c = [' "  'git'," "  'commit'," "  '-@n'].join(' ');"
AT=4 expect 'one element per line, a comment with an apostrophe after the closer' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-@n']); // don't"
AT=4 expect 'one element per line, a paren inside a quoted element before the closer' 1 tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '--author=A (B)', '-@n']);"
AT=4 expect 'one element per line, the opener after a quoted key' 1 .vscode/tasks.json '{' '  "args": [' '    "commit",' '    "-@n"' '  ]' '}'

# --- the routes the ES suite scan names that Fineprint's port lacked ------------
expect 'the shortest prefix of the long flag' 1 scripts/a.sh 'git commit --no-@v -m x'
expect 'any GIT_CONFIG_ name' 1 scripts/a.sh 'export GIT_CONFIG_@ANYTHING=x'
expect 'another home, inline' 1 scripts/a.sh 'HOM@E=/tmp/x git commit -m x'
expect 'another home, exported' 1 scripts/a.sh 'export GIT_X=1 HOM@E=/tmp/x'
expect 'another home, through env' 1 scripts/a.sh 'runuser -u nobody -- env HOM@E="$dir" git commit -m x'
expect 'another home, in a PHP heredoc' 1 tests/A.php '    export HOM@E={SANDBOX}'
expect 'another config home' 1 scripts/a.sh 'XDG_CONFIG_HOM@E=/tmp/x git commit -m x'
expect 'a commit stood up from an import stream' 1 scripts/a.sh 'git fast-@import <stream'
expect 'an object written straight to the store' 1 scripts/a.sh 'git hash-@object -w --stdin <f'
expect 'a short cluster carrying n after merge' 1 scripts/a.sh 'git merge -@n other'
expect 'the short flag after merge in an argv array' 1 tests/A.php "\$p = new Process(['git', 'merge', '-@n', 'x']);"
AT=3 expect 'merge, one element per line' 1 scripts/a.sh 'args=(' '    merge' '    -@n' ')'
expect 'a read on the line does not hide a write' 1 scripts/a.sh 'git config --get core.hooks@Path || git config core.hooks@Path x'

# --- the rest of the line is judged up to a command end, and only quoted strings are blanked --
expect 'the short flag after an unquoted $(...)' 1 scripts/a.sh 'git commit $(true) -@n'
expect 'the short flag after a backtick substitution' 1 scripts/a.sh 'git commit --amend -m x `true` -@n'
expect 'the short flag after a word that starts with git-' 1 scripts/a.sh 'git commit -F git-msg.txt -@n'
expect 'the short flag after a quoted commit' 1 scripts/a.sh 'git "commit" -@n'
expect 'the hooks key split mid-word by a continuation' 1 scripts/a.sh 'git -c core.hooks\' 'Path=x commit -m x'
expect 'the short flag after a redirection to a descriptor' 1 scripts/a.sh 'git commit 2>&1 -@n'
expect 'the short flag after an &> redirection' 1 scripts/a.sh 'git commit &>/dev/null -@n'
expect 'the short flag glued to a substitution' 1 scripts/a.sh 'git commit $(true)-@n'
expect 'the short flag before a closing backtick' 1 scripts/a.sh 'x=`git commit -@n`'
expect 'n inside an unquoted $(...), judged as ES judges it' 1 scripts/a.sh 'git commit -q -m $(head -@n 1 msg.txt)'
expect 'n after a second git, with no separator' 1 scripts/a.sh 'both git commit -q -m x git log -@n 1'

# --- a read passes only with nothing after the key but a command end ------------
expect 'a read followed by an unset' 1 scripts/a.sh 'git config --get core.hooks@Path --unset'
expect 'a read followed by a replace-all' 1 scripts/a.sh 'git config --get core.hooks@Path --replace-all /dev/null'
expect 'a read of the double-quoted key followed by an unset' 1 scripts/a.sh 'git config --get "core.hooks@Path" --unset'
expect 'a read of the single-quoted key followed by a replace-all' 1 scripts/a.sh "git config --get 'core.hooks@Path' --replace-all /dev/null"
expect 'a read of a key glued to an empty string' 1 scripts/a.sh 'git config --get core.hooks@Path"" --unset'
expect 'an -e of HOME after a command that is not docker run' 1 scripts/a.sh 'x -e HOM@E=/tmp git commit -m x'
expect 'an -e of HOME after the docker run has ended' 1 scripts/a.sh 'docker run --rm node true && x -e HOM@E=/tmp git commit -m x'

# --- comments are judged as ES judges them, and only --get reads the key -------
expect 'a shell comment' 1 scripts/a.sh '# when it blocks, git commit --no-@verify'
expect 'a PHP docblock line' 1 tests/A.php ' * git commit --no-@verify gets it through'
expect 'a JS line comment' 1 e2e/a.js '// git commit --no-@verify gets it through'
expect 'a comment naming the hooks key' 1 scripts/a.sh '# point core.hooks@Path at .githooks'
expect 'a global unset of the hooks key' 1 scripts/a.sh 'git config --global --unset core.hooks@Path'
expect 'a get-all of the hooks key' 1 scripts/a.sh 'git config --get-all core.hooks@Path'
expect 'the hooks key at the end of a line' 1 scripts/a.sh 'key=core.hooks@Path'
expect 'the hooks key in capitals before a paren' 1 scripts/a.sh 'x=$(git config CORE.HOOKS@PATH)'

# --- an empty quote pair splits a word for nothing, and --no-get is no read ------
expect 'commit split by an empty single-quote pair' 1 scripts/a.sh "git c''ommit -@n"
expect 'commit split by an empty double-quote pair' 1 scripts/a.sh 'git c""ommit -@n'
expect 'the hooks key split by an empty quote pair' 1 scripts/a.sh "git config core.hooks''@Path x"
expect 'the long flag split by an empty quote pair' 1 scripts/a.sh 'git commit --no-""@verify -m x'
expect 'commit split by an empty single-quote pair in a Python argv' 1 scripts/a.py "subprocess.run(['git', 'com''mit', '-@n'])"
expect 'commit split by an empty double-quote pair in a Python argv' 1 scripts/a.py 'subprocess.run(["git", "com""mit", "-@n"])'
expect 'an unset with the read negated' 1 scripts/a.sh 'git config --unset --no-get core.hooks@Path'
expect 'a global unset with the read negated' 1 scripts/a.sh 'git config --global --unset --no-get "core.hooks@Path"'

# --- bash drops a quote or backslash inside a word, so the scan judges each word as bash reads it --
expect 'r2: the long flag with its tail quoted' 1 scripts/a.sh 'git commit --no-"@verify" -m x'
expect 'r2: the long flag with a backslash in it' 1 scripts/a.sh 'git commit --no-\@verify -m x'
expect 'r2: the long flag with its tail ANSI-C quoted' 1 scripts/a.sh "git commit --no-\$'@verify' -m x"
expect 'r2: the short flag with a backslash in it' 1 scripts/a.sh 'git commit -\@n -m x'
expect 'r2: a short cluster with a quoted letter' 1 scripts/a.sh 'git commit -"q"@n -m x'
expect 'r2: the short flag ANSI-C quoted' 1 scripts/a.sh "git commit \$'-@n' -m x"
expect 'r2: the short flag after a redirection glued to commit' 1 scripts/a.sh 'git commit>/dev/null -@n'
expect 'r2: commit with a quoted tail' 1 scripts/a.sh 'git c"ommit" -@n'
expect 'r2: the hooks key with a quoted tail' 1 scripts/a.sh 'git -c core.hooks"@Path"=/dev/null commit -m x'
expect 'r2: the hooks key with a quoted head' 1 scripts/a.sh 'git config "core".hooks@Path x'
expect 'r2: a GIT_CONFIG_ name with a quoted tail' 1 scripts/a.sh 'export GIT_CONFIG_"@GLOBAL"=x'
expect "r2: husky's off switch with the value quoted" 1 scripts/a.sh 'HUSKY="@0" git commit -m x'
expect 'r2: another home with its = quoted' 1 scripts/a.sh 'HOM@E"=/tmp" git commit -m x'
expect 'r2: another home with its = escaped' 1 scripts/a.sh 'HOM@E\=/tmp git commit -m x'
expect 'r2: another home appended to' 1 scripts/a.sh 'HOM@E+=/x git commit -m x'
expect 'r2: another config home with its = quoted' 1 scripts/a.sh 'XDG_CONFIG_HOM@E"="/tmp git commit -m x'
expect 'r2: a commit made below the hooks, half quoted' 1 scripts/a.sh 'tree=$(git commit"-@tree" HEAD^{tree} -m x)'
expect 'r2: a commit from an import stream, half quoted' 1 scripts/a.sh 'git fast"-@import" <stream'
expect 'r2: an object written to the store, its flag quoted' 1 scripts/a.sh 'git hash-@object "-w" --stdin <f'
expect 'r2: a HOME inside a $( after a docker run' 1 scripts/a.sh 'docker run --rm img true $(firejail --env=HOM@E=/tmp git commit -m x)'
expect 'r2: a HOME inside backticks after a docker run' 1 scripts/a.sh 'docker run --rm img true `firejail --env=HOM@E=/tmp git commit -m x`'
expect 'r2: a word that only ends in docker' 1 scripts/a.sh 'mydocker run -e HOM@E=/tmp git commit -m x'
expect 'r2: the short flag inside a quoted command' 1 scripts/a.sh 'bash -c "git commit -@n -m x"'
expect "r2 near miss: an ANSI-C quoted n that is -m's value" 0 scripts/a.sh "git commit -m \$'-@n'"
expect "r2 near miss: a quoted n glued into -m's value" 0 scripts/a.sh 'git commit -m x"-@n"'
expect "r2 near miss: a message holding a quoted n" 0 scripts/a.sh "git commit -m \"run 'lint -@n' first\""
expect 'r2 near miss: a quoted pathspec holding a spaced n' 0 scripts/a.sh 'git commit -q -- "my -@n notes.txt"'
expect 'r2 near miss: a container home before a $(' 0 scripts/e2e.sh 'docker run --rm -e HOM@E=/tmp node npm ci $(x)'

# --- one root-home pass: env -i, the root home among its assignments, then any git, in one command --
expect 'root home: env -i with only the root home, then git' 0 scripts/a.sh 'en@v -i HOM@E=/root git -C / status'
expect 'root home: assignments around the root home, then git' 0 scripts/a.sh 'clone_git() { en@v -i PATH=/usr/bin:/bin HOM@E=/root GIT_NO_REPLACE_OBJECTS=1 git -C / "$@"; }'
expect 'root home: a quoted assignment, then "$GIT_BIN"' 0 scripts/a.sh 'exec en@v -i PATH="$RUN_PATH" HOM@E=/root "$GIT_BIN" fetch'
expect 'root home: git through ${GIT_BIN}' 0 scripts/a.sh 'en@v -i HOM@E=/root ${GIT_BIN} fetch'
expect 'root home: git on the continuation line' 0 scripts/a.sh 'en@v -i PATH=/usr/bin:/bin HOM@E=/root GIT_TERMINAL_PROMPT=0 \' '    "$GIT_BIN" -c credential.helper= "$@"'
expect 'root home refused: a path under /root' 1 scripts/a.sh 'en@v -i HOM@E=/root/x git status'
expect 'root home refused: /root with a suffix' 1 scripts/a.sh 'en@v -i HOM@E=/rootx git status'
expect 'root home refused: another home' 1 scripts/a.sh 'en@v -i HOM@E=/tmp git status'
expect 'root home refused: a home from a variable' 1 scripts/a.sh 'en@v -i HOM@E="$X" git status'
expect 'root home refused: a second HOME before it' 1 scripts/a.sh 'en@v -i HOM@E=/tmp HOM@E=/root git status'
expect 'root home refused: a second HOME after it' 1 scripts/a.sh 'en@v -i HOM@E=/root HOM@E=/tmp git status'
expect 'root home refused: a HOME after the git call' 1 scripts/a.sh 'en@v -i HOM@E=/root git status HOM@E=/tmp'
expect 'root home refused: a HOME in a later command' 1 scripts/a.sh 'en@v -i HOM@E=/root git status; HOM@E=/tmp git status'
expect 'root home refused: a HOME after &&' 1 scripts/a.sh 'en@v -i HOM@E=/root git status && HOM@E=/tmp x'
expect 'root home: bash next' 0 scripts/a.sh 'en@v -i HOM@E=/root bash "$TREE/$SCRIPT"'
expect 'root home: docker compose next' 0 scripts/a.sh 'en@v -i PATH="$P" HOM@E=/root docker compose up'
expect 'root home refused: env -i alone, then git after a separator' 1 scripts/a.sh 'en@v -i HOM@E=/root; git status'
expect 'root home refused: git after an assignment and a separator' 1 scripts/a.sh 'en@v -i HOM@E=/root X=1; git status'
expect 'root home: a command named like git' 0 scripts/a.sh 'en@v -i HOM@E=/root gitx status'
expect "root home: gate-run.sh's exec form" 0 scripts/a.sh 'exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOM@E=/root LANG=C.UTF-8 \' '    GATE_RUN_DIR="$run" GATE_RUN_T_SRC="${GATE_RUN_T_SRC:-}" \' '    /bin/bash "$run/lib/scripts/lib/gate/run.sh" "$app" "$sha" "$script" "$@"'
expect "root home: gate/run.sh's app-gate form" 0 scripts/a.sh 'env -i PATH="$RUN_PATH" HOM@E=/root LANG=C.UTF-8 TERM=dumb \' '    GATE_COMPOSE="bash $LIB/compose.sh" CI_GIT="$tgit" GATE_LEDGER="$RUN/status" \' '    bash "$TREE/$SCRIPT" "$@"'
expect "root home: gate/compose.sh's dc form" 0 scripts/lib/compose.sh 'dc() { env -i PATH="$RUN_PATH" HOM@E=/root docker compose --project-directory "$TREE" "$@"; }'
expect 'root home refused: env without -i' 1 scripts/a.sh 'env HOM@E=/root git status'
expect 'root home refused: no env -i at all' 1 scripts/a.sh 'HOM@E=/root git status'
expect 'root home refused: a word that only ends in env' 1 scripts/a.sh 'myenv -i HOM@E=/root git status'

# --- r3: a home taken away is another home; so is one a builtin sets, with no assignment --
expect 'r3: env with -i and no home' 1 scripts/a.sh 'en@v -i PATH=/usr/bin git commit -m x'
expect 'r3: env with -i after another option' 1 scripts/a.sh 'en@v -v -i git commit'
expect 'r3: env with -i in a cluster' 1 scripts/a.sh 'en@v -iv git commit'
expect 'r3: env with the long ignore flag' 1 scripts/a.sh 'en@v --ignore-environment git commit'
expect 'r3: env with a lone dash' 1 scripts/a.sh 'en@v - PATH=/x git commit'
expect 'r3: env with -i inside $(...)' 1 scripts/a.sh 'x=$(en@v -i git commit -m x)'
expect 'r3: env with a quoted -i after &&' 1 scripts/a.sh 'true && en@v "-i" git commit'
expect 'r3: env -u of the home' 1 scripts/a.sh 'env -u HOM@E git commit'
expect 'r3: env --unset= of the home' 1 scripts/a.sh 'env --unset=HOM@E git commit'
expect 'r3: env --unset of the home' 1 scripts/a.sh 'env --unset HOM@E git commit'
expect 'r3: env -u glued to the home' 1 scripts/a.sh 'env -uHOM@E git commit'
expect 'r3: env -u of the config home, after -v' 1 scripts/a.sh 'env -v -u XDG_CONFIG_HOM@E git commit'
expect 'r3: unset of the home' 1 scripts/a.sh 'unset HOM@E'
expect 'r3: unset -v of the home' 1 scripts/a.sh 'unset -v HOM@E'
expect 'r3: unset of two names, one the home' 1 scripts/a.sh 'unset FOO HOM@E'
expect 'r3: unset of the quoted config home after a separator' 1 scripts/a.sh 'true; unset "XDG_CONFIG_HOM@E"; git commit'
expect 'r3: an index of the home' 1 scripts/a.sh 'HOM@E[0]=/tmp git commit'
expect 'r3: an index of the config home, appended' 1 scripts/a.sh 'XDG_CONFIG_HOM@E[1]+=x'
expect 'r3: read into the home' 1 scripts/a.sh 'read HOM@E'
expect 'r3: read -r into the home' 1 scripts/a.sh 'read -r HOM@E'
expect 'r3: read with a quoted prompt into the home' 1 scripts/a.sh 'read -p "Home: " HOM@E'
expect 'r3: read of two names, one the home' 1 scripts/a.sh 'IFS= read -r A HOM@E <f'
expect 'r3: readarray into the home' 1 scripts/a.sh 'readarray -t HOM@E <f'
expect 'r3: read into the home inside backticks' 1 scripts/a.sh 'x=`read HOM@E`'
expect 'r3: printf -v into the home' 1 scripts/a.sh 'printf -v HOM@E /tmp'
expect 'r3: printf -v glued to the config home' 1 scripts/a.sh 'printf -vXDG_CONFIG_HOM@E %s x'
expect 'r3: a local home' 1 scripts/a.sh 'f() { local HOM@E; git commit; }'
expect 'r3: a declared home' 1 scripts/a.sh 'declare -x HOM@E'
expect 'r3: a home no longer exported' 1 scripts/a.sh 'export -n HOM@E'
expect 'r3: a loop over the home' 1 scripts/a.sh 'for HOM@E in /tmp; do git commit; done'
expect 'r3: let on the home' 1 scripts/a.sh 'let HOM@E++'
expect 'r3: an arithmetic set of the home' 1 scripts/a.sh '(( HOM@E = 1 ))'
expect 'r3: getopts into the home' 1 scripts/a.sh 'while getopts ab HOM@E; do git commit; done'
expect 'r3: getopts into the config home, quoted optstring' 1 scripts/a.sh 'getopts "a:b" XDG_CONFIG_HOM@E'
expect 'r3: wait -n -p into the home' 1 scripts/a.sh 'wait -n -p HOM@E'
expect 'r3: wait -p glued to the config home' 1 scripts/a.sh 'wait -n -pXDG_CONFIG_HOM@E'
expect 'r3: a coproc named the home' 1 scripts/a.sh 'coproc HOM@E { git commit; }'
expect 'r3: a coproc named the config home' 1 scripts/a.sh 'coproc XDG_CONFIG_HOM@E { git commit; }'
expect 'r3 near miss: getopts into another name' 0 scripts/a.sh 'getopts ab opt'
expect 'r3 near miss: wait -p into another name' 0 scripts/a.sh 'wait -n -p pid'
expect 'r3 near miss: a coproc with no name' 0 scripts/a.sh 'coproc { git status; }'
expect 'r3 near miss: a coproc named MY_HOME' 0 scripts/a.sh 'coproc MY_HOM@E { true; }'
expect "r3 known gap: env with -i before a shell that runs git, a pass until the rule reads inside -c" 0 scripts/a.sh "en@v -i PATH=/bin bash -c 'git commit'"
expect 'r3 known gap: env with -i before "$@", as gate/run.sh does, where the caller decides whether git runs' 0 scripts/a.sh 'en@v -i PATH=/bin "$@"'
expect 'r3: env with -i in a cluster ending in -C dir, then git' 1 scripts/a.sh 'en@v -iC /repo git commit -m x'
expect 'r3: env with -i in a cluster ending in -u name, then git' 1 scripts/a.sh 'en@v -iu FOO git commit -m x'
expect 'r3: env with -i, then -C dir, then git' 1 scripts/a.sh 'en@v -i -C /repo git'
expect 'r3: env with -vi, then -C dir, then git' 1 scripts/a.sh 'en@v -vi -C /r git'
expect 'r3: env with -iu of the home' 1 scripts/a.sh 'en@v -iu HOM@E git'
expect 'r3 near miss: env with -iC dir before python' 0 scripts/a.sh 'en@v -iC / /usr/bin/python3 -I x.py'
expect 'r3: a nameref to the home' 1 scripts/a.sh 'declare -n r=HOM@E; r=/tmp; git commit -m x'
expect 'r3: a local nameref to the home' 1 scripts/a.sh 'local -n r=HOM@E'
expect 'r3: a typeset nameref to the config home' 1 scripts/a.sh 'typeset -n r=XDG_CONFIG_HOM@E'
expect 'r3: a nameref in a cluster, double-quoted' 1 scripts/a.sh 'declare -gn r="HOM@E"'
expect 'r3: a nameref after another option, single-quoted' 1 scripts/a.sh "local -r -n r='HOM@E'"
expect 'r3 near miss: a nameref to MY_HOME' 0 scripts/a.sh 'declare -n r=MY_HOM@E'
expect 'r3 near miss: a nameref to HOMEDIR' 0 scripts/a.sh 'declare -n r=HOM@EDIR'
expect 'r3 near miss: env with -i running python, as the gate lib does' 0 scripts/a.sh 'en@v -i PATH=/usr/bin:/bin /usr/bin/python3 -I -c "$X" "$f"'
expect 'r3 near miss: env -u of MY_HOME' 0 scripts/a.sh 'env -u MY_HOM@E x'
expect 'r3 near miss: unset of HOMEDIR' 0 scripts/a.sh 'unset HOM@EDIR'
expect 'r3 near miss: read into MY_HOME' 0 scripts/a.sh 'read -r MY_HOM@E'
expect 'r3 near miss: read into HOMEDIR' 0 scripts/a.sh 'read -r HOM@EDIR'
expect 'r3 near miss: an index of a name that ends in HOME' 0 scripts/a.sh 'MY_HOM@E[0]=x'
expect 'r3 near miss: a read of $HOME' 0 scripts/a.sh 'cd "$HOM@E" && read -r x <<<"$HOM@E"'
expect 'r3 near miss: the word HOME echoed' 0 scripts/a.sh 'echo HOM@E'
expect 'r3 near miss: HOME exported as it is' 0 scripts/a.sh 'export HOM@E'
expect 'r3 near miss: printf -v into another name, of $HOME' 0 scripts/a.sh "printf -v x '%s' \"\$HOM@E\""
expect 'r3 near miss: a loop over paths under $HOME' 0 scripts/a.sh 'for h in "$HOM@E"/a; do :; done'
expect 'r3 near miss: an arithmetic compare of HOME' 0 scripts/a.sh '(( HOM@E == 1 ))'

# --- r3: an include key, plain or conditional, loads a file that can set the hooks key ----
expect 'r3: -c of the include key' 1 scripts/a.sh 'git -c include.pa@th=/tmp/x commit'
expect 'r3: the include key in capitals' 1 scripts/a.sh 'git -c INCLUDE.PA@TH=/x commit'
expect 'r3: --config-env of the include key' 1 scripts/a.sh 'git --config-env=include.pa@th=X commit'
expect 'r3: the include key with a quoted tail' 1 scripts/a.sh 'git -c include."pa@th"=/x commit'
expect 'r3: -c of a conditional include key' 1 scripts/a.sh 'git -c includeI@f.gitdir:/a/.path=/x commit'
expect 'r3: a conditional include key, single-quoted' 1 scripts/a.sh "git -c 'includeI@f.onbranch:main.path'=/x commit"
expect 'r3: the include key in a Python argv' 1 scripts/a.py 'subprocess.run(["git", "-c", "include.pa@th=x", "commit"])'
expect 'r3 near miss: a -c of another key' 0 scripts/a.sh 'git -c user.name=x commit -m x'

# --- docs/ and near misses are not ----------------------------------------------
expect 'a file under docs/' 0 docs/a.md 'git commit --no-@verify'
expect 'an argv array with no n' 0 tests/A.php "\$p = new Process(['git', 'commit', '-q', '-m', 'run -@n']);"
expect 'a plain commit' 0 scripts/a.sh 'git -C "$dir" commit -q -m x'
expect 'a commit with an empty message' 0 scripts/a.sh "git commit -q --allow-empty-message -m ''"
expect 'another long --no- flag' 0 scripts/a.sh 'git log --no-@walk HEAD'
expect 'a container handed its own home' 0 scripts/e2e.sh 'docker run --rm -u 1:1 -e HOM@E=/tmp node npm ci'
expect 'a container handed its home in long form' 0 scripts/e2e.sh 'docker run --rm --env HOM@E=/tmp node npm ci'
expect 'a compose container handed its own home' 0 scripts/e2e.sh 'docker compose run --rm -e HOM@E=/tmp app npm ci'
expect 'a variable that only ends in HOME' 0 scripts/a.sh 'MY_HOM@E=/tmp/x'
expect 'hashing a file without writing it' 0 scripts/a.sh 'git hash-@object f.txt'
expect 'merge-base is not merge' 0 scripts/a.sh 'git merge-@base -a x y'
expect 'a read of the hooks key' 0 scripts/a.sh 'git config --get core.hooks@Path'
expect 'a read of the hooks key inside $(...)' 0 scripts/a.sh 'p=$(git config --get core.hooks@Path) || p='
expect 'a read of the hooks key as an argv string' 0 tests/A.php "    'config --get core.hooks@Path',"
expect 'log -n, no commit' 0 scripts/a.sh 'echo "last: $(git log -@n 1)"'
expect 'n inside the message' 0 scripts/a.sh 'git commit -m "run lint -@n first"'
expect 'n after a separator' 0 scripts/a.sh 'git commit -q -m x; head -@n 1 notes.txt'
expect 'n after &&' 0 scripts/a.sh 'git commit -q -m x && echo -@n done'
expect 'n inside $(...)' 0 scripts/a.sh 'git commit -q -m "$(git log -@n 1 --format=%s)"'
expect 'update-ref moves a ref to a commit that exists' 0 scripts/a.sh 'git update-ref refs/heads/x HEAD'
expect 'a joined line ends where its backslashes do' 0 scripts/a.sh 'git commit -q \' '    -m x' 'echo -@n hi'
expect "a quoted n that is -m's value" 0 scripts/a.sh "git commit -m '-@n'"
expect "a quoted n that is --message's value" 0 scripts/a.sh 'git commit -a --message "-@n"'
expect 'a one-per-line argv whose n is in the message' 0 tests/A.php '$p = new Process([' "    'commit'," "    '-m'," "    'run -@n'," ']);'
expect 'commit in one array and n in the next' 0 tests/A.php "\$a = ['git', 'commit'];" '$b = [' "    '-@n'," '];'
expect 'a one-per-line argv for another command' 0 scripts/a.sh 'args=(' '    git' '    log' '    -@n' '    1' ')'
expect 'n in an array nested inside the argv' 0 tests/A.php '$p = run(' "    'git', 'commit'," "    y(['-@n'," ']));'
expect 'commit and n on lines of a text file' 0 notes.txt 'commit' '-@n'
expect 'a case arm named commit, then another arm' 0 scripts/a.sh 'case "$1" in' '    commit)' '        do_commit' '        ;;' '    -@n)' 'esac'
expect 'an array whose run a closer ends before n' 0 scripts/a.sh 'a=(' '    git' '    commit)' 'status' '-@n'
expect 'a case arm named commit that runs head with a count' 0 scripts/a.sh 'case "$1" in' '    commit) head -@n 1 log ;;' 'esac'
expect 'a quoted word glued to another is one word, not a flag' 0 scripts/a.sh "git commit -q 'a''-@n'"
expect 'a case dispatcher: an arm named commit runs commit, then a dry-run arm' 0 scripts/a.sh 'case "$1" in' '  commit)' '    commit' '    ;;' '  -@n) dry_run=1 ;;' 'esac'
expect 'a bare commit, then fi, then a dry-run arm' 0 scripts/a.sh 'if x; then' '  commit' 'fi' '-@n) y'
expect 'a help heredoc listing commit, then the dry-run flag' 0 scripts/a.sh 'cat <<EOF' 'Commands:' '  commit' '  -@n)  dry run' 'EOF'

# A run left open at the end of one file does not carry into the next.
repo="$(fixture scripts/a.sh 'args=(' '    git')"
printf '    commit\n' >"${repo}/scripts/b.sh"
printf '    -%s) x\n' n >>"${repo}/scripts/b.sh"
rc=0; out="$(bash "${SCAN}" "${repo}" 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]]; then ok 'a run open at the end of one file ends there'; else bad "a run open at the end of one file carried on: exit ${rc}: ${out}"; fi

# --- the scanner skips itself and each path it is given, and nothing else ---------
skip_case() { # <label> <want rc> <skipped path>...: the tree holds scripts/a.sh, a route, and clean.txt
    local repo rc=0
    repo="$(fixture scripts/a.sh 'git commit --no-@verify -m x')"
    bash "${SCAN}" "${repo}" "${@:3}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq "$2" ]]; then ok "$1"; else bad "$1: exit ${rc}, wanted $2"; fi
}
skip_case 'a skipped path is not judged' 0 scripts/a.sh
skip_case 'a skipped path is exact, never a directory' 1 scripts
skip_case 'a skipped path is exact, never a prefix' 1 scripts/a
skip_case 'skipping another file still judges this one' 1 clean.txt
skip_case 'an empty skipped path exits 2' 2 ''

repo="$(fixture scripts/a.sh 'true')"
cp -- "${SCAN}" "${repo}/scripts/hook-bypass-scan.sh"
rc=0; bash "${repo}/scripts/hook-bypass-scan.sh" "${repo}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 0 ]]; then ok 'the scanner does not judge itself'; else bad "the scanner judged itself: exit ${rc}"; fi
rc=0; bash "${SCAN}" "${repo}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then ok "an app's own copy of the scanner is judged"; else bad "an app's own copy of the scanner exited ${rc}, wanted 1"; fi

# --- nothing judged is never a pass ----------------------------------------
repo="$(mktemp -d "${WORK}/empty.XXXXXX")"
git -C "${repo}" init -q
rc=0; bash "${SCAN}" "${repo}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok 'an empty listing exits 2'; else bad "an empty listing exited ${rc}, wanted 2"; fi

repo="$(fixture scripts/a.sh 'true')"
rc=0; HOOK_BYPASS_GIT=false bash "${SCAN}" "${repo}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok 'a failing git exits 2'; else bad "a failing git exited ${rc}, wanted 2"; fi

# A git that lists another tree: its paths are not here, so nothing here was judged.
other="$(fixture scripts/b.sh 'true')"
rc=0; HOOK_BYPASS_GIT="git -C ${other}" bash "${SCAN}" "${repo}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok 'r2: a git that lists another tree exits 2'; else bad "a git that lists another tree exited ${rc}, wanted 2"; fi

rc=0; bash "${SCAN}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok 'no root exits 2'; else bad "no root exited ${rc}, wanted 2"; fi

# Run from a clean repository, so a scan that ignored the failed cd would judge it and pass.
clean="$(fixture scripts/a.sh 'true')"
rc=0; (cd -- "${clean}" && bash "${SCAN}" "${WORK}/no-such-root") >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok 'a root cd cannot enter exits 2'; else bad "a root cd cannot enter exited ${rc}, wanted 2"; fi

# An awk that fails, silent or after a finding: its verdict is not one.
mkdir "${WORK}/awk-silent" "${WORK}/awk-loud"
printf '#!/bin/sh\nexit 2\n' >"${WORK}/awk-silent/awk"
printf '#!/bin/sh\necho scripts/a.sh:1: x\nexit 2\n' >"${WORK}/awk-loud/awk"
chmod +x "${WORK}/awk-silent/awk" "${WORK}/awk-loud/awk"
for how in silent loud; do
    rc=0; PATH="${WORK}/awk-${how}:${PATH}" bash "${SCAN}" "${clean}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 2 ]]; then ok "a ${how} failing awk exits 2"; else bad "a ${how} failing awk exited ${rc}, wanted 2"; fi
done

# An awk whose regex engine never matches ELEMS (mawk 1.3.4 20200120 did) passed every one-per-line argv.
per_line="$(fixture tests/A.php '$p = new Process([' "    'git'," "    'commit'," "    '-@n'," ']);')"
mkdir "${WORK}/awk-misreads"
cat >"${WORK}/awk-misreads/awk" <<'EOF'
#!/usr/bin/env bash
args=("$@")
for i in "${!args[@]}"; do args[i]=${args[i]//"${SHIM_FROM}"/"${SHIM_TO}"}; done
exec "${REAL_AWK}" "${args[@]}"
EOF
chmod +x "${WORK}/awk-misreads/awk"
misread() { # <label> <program text> <what this awk reads instead> <the self-test message it must print>
    local rc=0 err
    err="$(SHIM_FROM="$2" SHIM_TO="$3" REAL_AWK="$(command -v awk)" PATH="${WORK}/awk-misreads:${PATH}" \
        bash "${SCAN}" "${per_line}" 2>&1 >/dev/null)" || rc=$?
    if [[ "${rc}" -eq 2 && "${err}" == *"$4"* ]]; then ok "$1 exits 2"; else bad "$1 exited ${rc} without '$4', wanted 2 with it"; fi
}
misread 'an awk that misreads the element pattern' $'\n    ELEMS = ' $'\n    ELEMS = "\\001" ' 'misreads the argv-element pattern'
misread 'an awk that needs a repeated element' ')*" ELEM' ')+" ELEM' 'misreads the argv-element pattern'
misread 'an awk that misreads the repeated elements' '(" ELEM "[ \t]*,[ \t]*)*" ELEM' '" ELEM' 'misreads repeated argv elements'

if command -v mawk >/dev/null; then
    mkdir "${WORK}/awk-mawk"
    ln -s "$(command -v mawk)" "${WORK}/awk-mawk/awk"
    rc=0; PATH="${WORK}/awk-mawk:${PATH}" bash "${SCAN}" "${per_line}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 1 ]]; then ok 'mawk finds a one-per-line argv'; else bad "mawk on a one-per-line argv exited ${rc}, wanted 1"; fi
else
    printf 'skip mawk finds a one-per-line argv: no mawk here\n'
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    printf 'hook-bypass-scan-test: %d case(s) failed\n' "${FAILURES}" >&2
    exit 1
fi
printf 'hook-bypass-scan-test: all %d cases passed\n' "${PASSED}"
