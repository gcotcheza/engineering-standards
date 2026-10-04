# fleet-deploy-lib 2026-10-04.3 sha256:15f415afd50cc232e1406426f71f154c0d9ee8637b10cd0d708679efc48c05fc
# shellcheck shell=bash
# A gate names what root runs (GATE_LIB_SUITE, …) by a literal it writes once and only reads after:
# any other write can aim root at a suite nobody reviewed. docs/DECISIONS.md

# gate_literal_once <file> <NAME> <value>: 0 and silent when <file> writes NAME once, as
# NAME=<value>, NAME='<value>' or NAME="<value>" at column 0, and otherwise names it only as ${NAME}.
gate_literal_once() {
    local file=$1 name=$2 value=$3 mentions line own='' others='' scanned=yes
    local -
    set -o pipefail
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'LITERAL refused: [%s] is not a variable name\n' "$name"; return 1; }
    mentions=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' "$file" 2>/dev/null | awk -v name="$name" -v q="'" '
        /^[[:space:]]*#/ { next }
        { probe = $0; gsub(q, "", probe); gsub(/"/, "", probe); gsub(/\\/, "", probe)
          read = index(probe, "${" name "}") > 0
          while ((i = index(probe, "${" name "}")) > 0) probe = substr(probe, 1, i - 1) substr(probe, i + length(name) + 3)
          if (probe ~ ("(^|[^A-Za-z0-9_])" name "([^A-Za-z0-9_]|$)")) print "W" $0; else if (read) print "R" $0 }') || scanned=no
    [ "$scanned" = yes ] || { printf 'LITERAL %s refused: %s could not be scanned, so nothing shows what the gate runs\n' "$name" "$file"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ -z "$own" ] && { [ "$line" = "W$name=$value" ] || [ "$line" = "W$name='$value'" ] || [ "$line" = "W$name=\"$value\"" ]; }; then
            own=${line#W}
        elif [ "${line:0:1}" = W ] || [ -z "$own" ]; then
            others+="${others:+ | }${line#?}"
        fi
    done <<<"$mentions"
    [ -n "$own" ] || { printf 'LITERAL %s refused: %s never writes %s=%s on a line of its own at column 0\n' "$name" "$file" "$name" "$value"; return 1; }
    [ -z "$others" ] || { printf 'LITERAL %s refused: %s names it other than as %s after its one write: %s\n' "$name" "$file" "\${$name}" "$others"; return 1; }
}
