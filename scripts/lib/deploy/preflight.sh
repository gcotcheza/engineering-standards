# fleet-deploy-lib 2026-09-18 sha256:20799dd7c09b625d76689c79824ec94fa54cb2200fbff31e977ca5a7c56bb67f
# shellcheck shell=bash
# preflight prints what the box looked like and never refuses; refuse_if_dirty is the
# one pre-flight judgement, and it sits ahead of every command that moves the checkout.

preflight() {
    local load avail status
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    avail=$(free -m | awk '/^Mem:/ { print $7 }')
    status=$($HEAVY --status 2>&1 | head -1)
    say "PRE-FLIGHT load $load available ${avail}MB heavy-work $status"
}

refuse_if_dirty() {
    [ -z "$($GIT --no-optional-locks status --porcelain)" ] \
        || refuse "the checkout is dirty; a deploy never fast-forwards over uncommitted work."
}
