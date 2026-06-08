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

