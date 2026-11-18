#!/usr/bin/env bash
# Fixtures only: throwaway trees in a temp dir drive scripts/bash-dashdash-scan.sh.
# BASH_DASHDASH_SCAN_SH points at a scratch copy for the red proofs.
#
#   scripts/bash-dashdash-scan-test.sh
#   BASH_DASHDASH_SCAN_SH=/path/mutant.sh scripts/bash-dashdash-scan-test.sh   the red proofs
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${BASH_DASHDASH_SCAN_SH:-${SCRIPT_DIR}/bash-dashdash-scan.sh}"

fails=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails + 1)); }
equals() { if [ "$2" = "$3" ]; then pass "$1 is [$3]"; else fail "$1 is [$2], expected [$3]"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
n=0
# tree <file> <line>...: a fresh root whose only file is <file> holding the given lines.
tree() {
    n=$((n + 1)); R="${WORK}/t${n}"; mkdir -p "${R}/$(dirname -- "$1")"
    local f=$1; shift; printf '%s\n' "$@" >"${R}/${f}"
}
run() { OUT="$(timeout 20 bash -- "${SCAN}" "$@" 2>&1)"; RC=$?; }
# flags <case> <line>: the line, second in scripts/a.sh, is named and nothing else is.
flags() {
    tree scripts/a.sh '#!/usr/bin/env bash' "$2"; run "${R}"
    equals "$1: exit" "${RC}" 1
    equals "$1: finding" "${OUT}" 'scripts/a.sh:2: bash runs a script operand without -- before it'
}
# clean <case> <line>...: scripts/a.sh holding these lines passes.
clean() {
    local c=$1; shift; tree scripts/a.sh '#!/usr/bin/env bash' "$@"; run "${R}"
    equals "${c}: exit" "${RC}" 0
    equals "${c}: output" "${OUT}" ''
}

flags 'a quoted operand' 'bash "$X"'
flags 'a bare operand' 'bash $X arg'
flags 'a braced operand with options' 'bash -x -e "${X}/run.sh" "$@"'
flags 'an absolute bash' '/bin/bash "$X"'
flags 'bash after ||' 'true || bash "$X"'
flags 'bash after an assignment' 'A=1 B="b c" bash "$X"'
flags 'a command substitution in quotes' 'OUT="$(bash "$X" 2>&1)"'
flags 'a subshell inside a command substitution' 'OUT="$( (true); bash "$X")"'
flags 'a nested command substitution' 'OUT="$(echo "$(bash "$X")")"'
flags 'a set -o option and its name' 'bash -o pipefail "$X"'
flags 'a shopt -O option and its name' 'bash -O extglob "$X"'
flags 'an option turned off with +' 'bash +x "$X"'
flags 'a long option' 'bash --norc "$X"'
flags 'two long options' 'bash --noprofile --norc "$X"'

clean 'operands after --' 'bash -- "$X"' 'bash -x -- "${X}" a' '/bin/bash -- "$X"'
clean 'bash -c takes a string' 'bash -c "$X"' 'bash -ec "$X" sh' "bash -c 'run \"\$1\"' sh \"\$X\""
clean 'bash -s reads stdin' 'bash -s "$X"' 'bash -xs "$X" a'
clean 'an operand that names an option' 'bash -o "$X"' 'bash -xo "$X"'
clean 'operands after -- on a continued line' 'bash -x \' '    -- "$X"'
clean 'a line that does not go on' 'bash -x;' '    "$X"'
clean 'a literal operand' 'bash scripts/run.sh' 'bash ./x.sh'
clean 'a single-quoted string' 'CASE='"'"'bash "$X"'"'"
clean 'a double-quoted string' 'CMD="bash $X/compose.sh"'
clean 'a comment' '# bash "$X"' 'true # bash "$X"'
clean 'a word that ends in bash' 'mybash "$X"' 'x=bash "$X"'
clean 'an escaped quote' 'echo "a \" bash $X"'
clean 'a string after a command substitution' 'OUT="$(true) bash $X"'
clean 'a quoted here-doc body' "cat <<'EOF'" 'bash "$X"' 'EOF'
clean 'an unquoted here-doc body' 'cat <<-EOF' '	bash "$X"' '	EOF'

tree scripts/a.sh '#!/usr/bin/env bash' "cat <<'EOF'" 'bash "$X"' 'EOF' 'bash "$Y"'; run "${R}"
equals 'the line after a here-doc ends: finding' "${OUT}" 'scripts/a.sh:5: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' "echo 'a" 'bash "$X"' "b'" 'bash "$Y"'; run "${R}"
equals 'a string over several lines: finding' "${OUT}" 'scripts/a.sh:5: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'read -r a <<<"bash"' 'bash "$Y"'; run "${R}"
equals 'the line after a here-string: finding' "${OUT}" 'scripts/a.sh:3: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'OUT="$(A=1 \' '    bash "$X")"'; run "${R}"
equals 'a continued command substitution: finding' "${OUT}" 'scripts/a.sh:3: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'bash \' '    "$X"'; run "${R}"
equals 'an operand on a continued line: finding' "${OUT}" 'scripts/a.sh:2: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'bash -x \' '    -o pipefail \' '    "$X"' 'bash "$Y"'; run "${R}"
equals 'options over several continued lines: findings' "${OUT}" 'scripts/a.sh:2: bash runs a script operand without -- before it
scripts/a.sh:5: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'true # a comment ends in \' 'bash "$X"'; run "${R}"
equals 'a comment that ends in a backslash: finding' "${OUT}" 'scripts/a.sh:3: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'cat <<\EOF' "it's here" 'EOF' 'bash "$Y"'; run "${R}"
equals 'a here-doc quoted with a backslash: finding' "${OUT}" 'scripts/a.sh:5: bash runs a script operand without -- before it'
tree scripts/a.sh '#!/usr/bin/env bash' 'cat <<-\EOF' "	it's here" '	EOF' 'bash "$Y"'; run "${R}"
equals 'a tab-stripped here-doc quoted with a backslash: finding' "${OUT}" 'scripts/a.sh:5: bash runs a script operand without -- before it'

tree scripts/lib/deep/b.sh 'bash "$X"'; mkdir -p "${R}/scripts/z"; printf 'bash "$X"\n' >"${R}/scripts/z/c.sh"; run "${R}"
equals 'every *.sh at any depth: exit' "${RC}" 1
equals 'every *.sh at any depth: findings' "${OUT}" "scripts/lib/deep/b.sh:1: bash runs a script operand without -- before it
scripts/z/c.sh:1: bash runs a script operand without -- before it"
tree scripts/a.txt 'bash "$X"'; run "${R}"
equals 'a file that is not *.sh: exit' "${RC}" 0
tree docs/a.sh 'bash "$X"'; mkdir "${R}/scripts"; run "${R}"
equals 'a file outside scripts/: exit' "${RC}" 0

run; equals 'no root: exit' "${RC}" 2
run "${WORK}/no-such-root"; equals 'a root that is not there: exit' "${RC}" 2
mkdir "${WORK}/empty"; run "${WORK}/empty"; equals 'a root without scripts/: exit' "${RC}" 2

if [ "${fails}" -gt 0 ]; then printf '%s failure(s)\n' "${fails}" >&2; exit 1; fi
printf 'bash-dashdash-scan-test: all cases passed\n'
