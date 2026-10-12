# nx::camera — reserved

Not implemented yet. This directory intentionally contains no code.

What belongs here once stage 1 starts:

* One shared camera model (intrinsics, extrinsics, clip conventions) used by every
  experiment, so the Forge side and the Mitsuba side cannot drift apart.
* The exact `to_world` matrix that `scenes/*.xml` feeds to Mitsuba, plus the
  conversion into whatever The-Forge's `Camera` expects.
* Colour space and white point handling — because "the images differ" is a camera
  or colour pipeline mismatch far more often than it is a shading bug.

Until then, experiments construct their own matrices, and drift is caught by
`scenes/stage0_checkerboard.xml` during stage 0.
