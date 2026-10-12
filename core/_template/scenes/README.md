# Experiment scenes

Scenes that belong to this experiment only.

Scenes shared between experiments, or used to produce Mitsuba references, live in
the repository-level `scenes/` directory. One rule applies to both, and it is the
reason this split exists at all: the Mitsuba XML is the single source of truth, and
any glTF handed to The-Forge is exported from it rather than authored alongside it.
