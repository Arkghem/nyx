# patches

Changes to The-Forge are stored as patches. `forge/` is a submodule: upstream stays
clean and updatable, and our modifications never sit in its working tree.

## Why not a fork

The submodule-plus-patch combination keeps "update upstream" and "our changes"
independent: `git -C forge fetch && git -C forge checkout <new SHA>`, then reapply
the patches. Conflicts then surface inside a patch, where they are visible, instead
of hiding in a branch nobody dares to rebase.

The cost is that patches drift as upstream moves, so every patch has to be able to
explain, in words, what problem it solves.

## Workflow

```bash
cd forge
git switch -c nyx/<topic>            # based on the pinned SHA
# ... make changes ...
git diff > ../patches/<topic>.patch  # export
git switch --detach <pinned SHA>     # return to a clean state
git branch -D nyx/<topic>
```

Applying an existing patch:

```bash
cd forge
git apply --check ../patches/<topic>.patch   # dry run first
git apply ../patches/<topic>.patch
```

## Patch list

None yet. The first one is expected to be "make it build on Xcode 26": the upstream
project pins `c++14` and sets `GCC_TREAT_WARNINGS_AS_ERRORS=YES`, which newer
toolchains are very good at turning into build failures in code nobody is going to
fix here. `scripts/build_forge.sh` first tries to get around it by overriding that
setting on the command line. If that is not enough, the fix goes here as a patch and
gets registered below.

| Patch | Problem it solves | Upstream SHA |
|---|---|---|
| (none) | | |

## Naming and registration

- File name: `<topic>.patch`, kebab-case, describing the change — no dates.
- Every patch is registered in the table above: what it solves, which SHA it was
  based on, and what has to be reconfigured after applying it.
