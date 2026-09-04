# Changelog

## [Unreleased]

### Fixed

- `diff3` and `sdiff` now use the `diff` inside this binary. They were looking
  for a separate `diff` program on the system instead: on a machine that has
  one they quietly used it — a different program, possibly a different version —
  and on a machine without one they failed outright (`diff3: subsidiary program
  'diff' not found`). Windows was already correct; every other platform was not.

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones (400 KB to 436 KB). Checked on Windows 10 against the previous binary:
  all four programs report their version, and `diff`, `diff3`, `sdiff` and `cmp`
  produce byte-identical output.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.
