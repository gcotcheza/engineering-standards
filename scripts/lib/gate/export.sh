# shellcheck shell=bash disable=SC2034  # EXPORT_* are read by the caller
# The export-tree block of fleet-deploy, fleet-deploy-on-merge and gate-run.sh (C1): one sha's entries, judged
# then written as root from root's own repo. The caller defines mirror_git. decision: gate-run-exports-one-sha

EXPORT_YAML_CHECK='
import sys, yaml
class L(yaml.SafeLoader): pass
def any_tag(loader, suffix, node):
    if isinstance(node, yaml.MappingNode): return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.SequenceNode): return loader.construct_sequence(node, deep=True)
    return loader.construct_scalar(node)
L.add_multi_constructor("!", any_tag)
def walk(x, seen):
    if id(x) in seen: return False
    seen.add(id(x))
    if isinstance(x, dict):
        e = x.get("extends")
        return (isinstance(e, dict) and "file" in e) or any(walk(v, seen) for v in x.values())
    return isinstance(x, list) and any(walk(v, seen) for v in x)
try:
    docs = list(yaml.load_all(open(sys.argv[1], "rb"), Loader=L))
except Exception:
    sys.exit(5)
sys.exit(3 if any(isinstance(d, dict) and "include" in d for d in docs) else 4 if any(walk(d, set()) for d in docs) else 0)
'

export_is_compose() { [[ $1 != */* ]] && case $1 in docker-compose*.yml|docker-compose*.yaml|compose*.yml|compose*.yaml) true ;; *) false ;; esac; }

export_judge() { # sha [all] -> EXPORT_ENTRIES "kind mode obj path"; all puts every entry in kind tree; 1 and EXPORT_ERR on refusal
    local sha=$1 scope=${2:-deploy} m path mode type obj kind meta=()
    EXPORT_ENTRIES=() EXPORT_ERR='' EXPORT_SCOPE=$scope
    mapfile -d '' -t meta < <(mirror_git ls-tree -r -z "$sha"; printf 'rc=%s\0' "$?")
    [ "${meta[-1]:-}" = rc=0 ] || { EXPORT_ERR="git ls-tree at $sha failed"; return 1; }
    unset 'meta[-1]'
    for m in "${meta[@]}"; do
        path=${m#*$'\t'} kind=''
        read -r mode type obj <<<"${m%%$'\t'*}"
        if [ "$scope" = all ]; then kind=tree; else
            ! export_is_compose "$path" || kind=compose
            case /$path in /docker/*|*/Dockerfile*|*/.dockerignore) kind=${kind:-buildcheck} ;; esac
            [ -n "$kind" ] || continue
        fi
        [[ $path =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && /$path/ != */./* && /$path/ != */../* ]] || { EXPORT_ERR="an entry at $sha has a path outside [A-Za-z0-9._/-] or a . or .. component"; return 1; }
        [[ $type == blob && ( $mode == 100644 || $mode == 100755 ) ]] || { EXPORT_ERR="$path at $sha is $type mode $mode, not a plain file"; return 1; }
        EXPORT_ENTRIES+=("$kind $mode $obj $path")
    done
}

export_write() { # sha, run dir -> <kind>/ per judged kind, export-sha; 1 and EXPORT_ERR on refusal, the caller removes the dir
    local sha=$1 dir=$2 e kind mode obj path rc
    if [ "${EXPORT_SCOPE:-}" = all ]; then mkdir -m 755 "$dir/tree"; else mkdir -m 700 "$dir/compose" "$dir/buildcheck"; fi || { EXPORT_ERR="cannot create the export directories in $dir"; return 1; }
    for e in "${EXPORT_ENTRIES[@]}"; do
        read -r kind mode obj path <<<"$e"
        { mkdir -p "$dir/$kind/$(dirname "$path")" && mirror_git cat-file blob "$obj" >"$dir/$kind/$path"; } || { EXPORT_ERR="cannot write $path from $sha"; return 1; }
        if [ "$mode" = 100755 ]; then chmod 755 "$dir/$kind/$path"; else chmod 644 "$dir/$kind/$path"; fi || { EXPORT_ERR="cannot set the mode of $path"; return 1; }
        export_is_compose "$path" || continue
        env -i PATH=/usr/bin:/bin /usr/bin/python3 -I -c "$EXPORT_YAML_CHECK" "$dir/$kind/$path"; rc=$?
        [ "$rc" != 3 ] || { EXPORT_ERR="$path at $sha has a top-level include:, which would read files from the app tree"; return 1; }
        [ "$rc" != 4 ] || { EXPORT_ERR="$path at $sha has an extends: with file:, which would read files from the app tree"; return 1; }
        [ "$rc" = 0 ] || { EXPORT_ERR="$path at $sha could not be read as YAML (python3 exit $rc)"; return 1; }
    done
    printf '%s\n' "$sha" >"$dir/export-sha" || { EXPORT_ERR="cannot write $dir/export-sha"; return 1; }
}
