# shellcheck shell=bash
# dialog-lib.sh (card 581): the one "is a dialog on this pane?" check, vendored byte-identical
# from the standards repo. dialog_on <screen>: rc 0 dialog (lines on stdout), 1 none, 2 no locale.

# The rules hold ❯, │ and a no-break space: a C locale reads them as bytes (card 595).
DIALOG_LOCALE=C.UTF-8

# CSI (colon parameters too, as in \e[4:3m) and OSC 8 links. Its own name: a caller's
# strip_esc must not be shadowed.
dialog_strip_esc(){ sed -E 's/\x1b\[[0-9;:]*[a-zA-Z]//g; s/\x1b\][^\x1b]*\x1b\\//g'; }

dialog_on(){
  local -x LC_ALL="$DIALOG_LOCALE" 2>/dev/null; local s out re='Do you want to proceed\?' c='❯'
  # Fail closed (rc 2). Ask grep, not bash: bash keeps the caller's locale when the pin
  # fails, grep does not.
  printf '%s\n' "$c" | grep -qx . || { printf 'no %s locale: the dialog check cannot read this pane\n' "$DIALOG_LOCALE"; return 2; }
  s="$(printf '%s\n' "$1" | dialog_strip_esc)"
  # A numbered Yes/No line is an option only beside a dialog's own chrome (card 574):
  # a ❯ cursor and/or │ frame on an option row, or the Esc-to-cancel footer. A reply's list is not.
  printf '%s\n' "$s" | grep -qE '^[[:space:]]*❯[[:space:] ]*[0-9]+\.|^[[:space:]]*│([[:space:]]|❯)*[0-9]+\.|Esc to cancel' \
    && re="$re"'|^[[:space:]]*([^[:alnum:]][[:space:]]*){0,2}[0-9]+\.[[:space:]]+(Yes|No)([[:space:],]|$)'
  out="$(printf '%s\n' "$s" | grep -E "$re" || true)"
  # An option block: a `❯ n.` marker with a second numbered option under it.
  if [ -z "$out" ] && printf '%s\n' "$s" | grep -qE '^[[:space:]]*❯[[:space:]]*[0-9]+\.[[:space:]]*[^[:space:]]'; then
    out="$(printf '%s\n' "$s" | grep -E '^[[:space:]]*❯?[[:space:]]*[0-9]+\.[[:space:]]*[^[:space:]]' || true)"
    [ "$(printf '%s\n' "$out" | grep -c .)" -ge 2 ] || out=''
  fi
  # An exit confirmation: Enter-to-confirm beside Esc-to-cancel.
  if [ -z "$out" ] && printf '%s\n' "$s" | grep -q 'Enter to confirm' \
     && printf '%s\n' "$s" | grep -q 'Esc to cancel'; then
    out="$(printf '%s\n' "$s" | grep -E 'Enter to confirm|Esc to cancel' || true)"
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
