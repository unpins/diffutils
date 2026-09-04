# diffutils

[GNU diffutils](https://www.gnu.org/software/diffutils/) — `cmp`, `diff`, `diff3`, and `sdiff`, in a single self-contained binary built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/diffutils/actions/workflows/diffutils.yml/badge.svg)](https://github.com/unpins/diffutils/actions)
![Linux](https://img.shields.io/badge/Linux-%E2%9C%93-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-%E2%9C%93-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-%E2%9C%93-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install diffutils`.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin diffutils diff -u old.txt new.txt
unpin diffutils cmp a.bin b.bin
unpin diffutils diff3 mine.txt base.txt yours.txt
```

To install the programs onto your PATH:

```bash
unpin install diffutils
```

`unpin install diffutils` creates the `cmp`, `diff`, `diff3`, and `sdiff` commands.

## Programs

| command | what it does |
| --- | --- |
| `diff` | compare files line by line |
| `cmp` | compare two files byte by byte |
| `diff3` | compare three files line by line |
| `sdiff` | merge two files interactively, side by side |

## Man pages

`cmp.1`, `diff.1`, `diff3.1`, and `sdiff.1` are embedded in the binary — read with `unpin man diffutils`.

## Build locally

```bash
nix build
./result/bin/diffutils --version
```

## Manual download

The [Releases](https://github.com/unpins/diffutils/releases) page has standalone binaries.

## Build notes

- **Multicall:** the unpin-llvm engine compiles diffutils to bitcode and self-folds `cmp`/`diff`/`diff3`/`sdiff` into one binary, on Windows as well as Linux and macOS.
- **Windows:** `diff3` and `sdiff` normally `popen` an external `diff`; with no `fork` they call the folded `diff` in-process instead, so no external `diff` is needed. One residual limitation: the C runtime lists directory entries in the system's ANSI code page, so a file whose name it cannot represent comes back as `?` and `diff -r` reports `No such file or directory` for that one file — the rest of the tree still compares.
- **Man pages:** `cmp.1`, `diff.1`, `diff3.1`, and `sdiff.1` are embedded; read with `unpin man diffutils`.
- **Tests:** the native `make check` is skipped — gnulib's own multi-threaded (`*-mt`, `test-thread_create`) and getopt meta-tests fail under static-musl threads in the build sandbox. diffutils' own functional tests (33/33) pass.

