# One base vetting for every gate

Scribly, KidsQuest and Reflection each copied the same block that vets a gate's `--base <sha>`: the base is a commit, an ancestor of HEAD, behind origin/main, and, when HEAD is already merged, at or below the first parent of the main-line commit that took HEAD in. The third copy is where C1 says extract, so the block is now `base_vet` in `scripts/lib/deploy/base.sh`, and apps adopt it in their own pull requests.

The caller hands in its git as the trailing words of the call, a word list (`git-as app -C tree`) or a function name (`git_owner`), because the apps reach git differently and the lib must not guess. The apps' second lines differ (the fetch hint, and Reflection's hint after the not-an-ancestor sentence), so those lines are arguments; every first sentence is the copies' own, word for word, because the apps' tests assert them.

Two fixes ride the move. Every `merge-base --is-ancestor` reads exit 0 as yes and 1 as no, and anything else refuses with a sentence naming the exit: Scribly and KidsQuest read an error in the floor loop as "not an ancestor" and broke early, which floors too late and accepts a base inside the merge. And `base_vet_armed` closes the gap between vetting and arming: the base is vetted against HEAD, the ledger arms on the HEAD it reads later, so a gate calls it after `gate_ledger_arm` with `GATE_ARMED_SHA` and refuses when that commit no longer holds the base. It checks ancestry only; a head that moved and still holds the base is not re-vetted for the floor, and a gate that wants that runs `base_vet` again against the armed commit.

A refusal returns 2 rather than exiting, because a gate calls `base_vet` inside `$(...)` and decides itself to exit 2, before its trap can record anything.
