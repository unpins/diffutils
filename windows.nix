# diffutils for Windows-x86_64 via mingw (native PE), built FROM x86_64-linux
# through `mingwStaticCross`, so it lands under packages.x86_64-linux."windows-x86_64".
#
# Upstream diffutils is a first-class native-Windows target (the author wrote
# the no-fork code paths + gnulib's cmd.exe `system-quote`; NEWS: "designed to
# build with Cygwin or MinGW"). mingw is the catalog's preferred native Windows
# backend; we use it here — rather than cosmo — for a real PE. The cost is that
# `diff -r` enumerates directories through msvcrt readdir, which mangles
# non-ASCII filenames (see docs/platforms/mingw.md); that limitation is the only
# thing cosmo would buy, and it is the accepted trade for a native binary.
#
# Two diffutils-on-mingw specifics:
#   1. `diff3`/`sdiff` have no `fork()`, so upstream spawns `diff` via
#      `popen("cmd.exe /c diff …")` — an EXTERNAL program, which our single
#      binary doesn't ship. diffutils-inprocess.patch's fork-free branch
#      (`UNPIN_INPROC_NOFORK`, taken when !HAVE_WORKING_FORK) instead captures
#      the folded `diff_main`'s stdout to a temp file and calls it in-process.
#      Validated on Linux via -DUNPIN_TEST_NOFORK before shipping here.
#   2. nixpkgs' diffutils pulls `coreutils` (for the `pr` paginator `diff -l`
#      uses); on mingw that drags coreutils-x86_64-w64-mingw32, which dies in
#      gnulib `lib/savewd.c` on `waitpid`. We override `coreutils` to the native
#      one (build-time presence only — PR_PROGRAM is set to bare `pr` below).
#
# Hand-rolled multicall recipe (Windows-only — linux/darwin self-fold through
# the unpin-llvm engine instead; see flake.nix): rename each tool's `main` →
# {cmp,diff,diff3,sdiff}_main, ship a dispatcher.o, link the union of objects
# with libver.a + lib/libdiffutils.a. mingw gcc has no fat-LTO, so the rename
# could be objcopy, but diff3/sdiff must be RECOMPILED anyway (to pick up
# -DUNPIN_MULTICALL); we recompile all four for uniformity.
{ unpins-lib }:
pkgs:
let
  mingwPkgs = unpins-lib.lib.mingwStaticCross pkgs;

  multicallMk = mingwPkgs.buildPackages.writeText "unpin-multicall.mk" ''
    MULTI_OUT ?= $(top_builddir)/multicall/diffutils.exe

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    $(MULTI_OUT): \
        $(top_builddir)/multicall/dispatcher.o \
        cmp.o.renamed diff.o.renamed diff3.o.renamed sdiff.o.renamed \
        analyze.o context.o dir.o ed.o ifdef.o io.o normal.o side.o system.o util.o \
        libver.a $(top_builddir)/lib/libdiffutils.a
    	$(LINK) \
    		$(top_builddir)/multicall/dispatcher.o \
    		cmp.o.renamed diff.o.renamed diff3.o.renamed sdiff.o.renamed \
    		analyze.o context.o dir.o ed.o ifdef.o io.o normal.o side.o system.o util.o \
    		libver.a $(top_builddir)/lib/libdiffutils.a \
    		$(CLOCK_TIME_LIB) $(HARD_LOCALE_LIB) $(LIBTHREAD) $(LIBCSTACK) \
    		$(LIBINTL) $(LIBSIGSEGV) $(LIBUNISTRING) $(MBRTOWC_LIB) \
    		$(LIBC32CONV) $(SETLOCALE_NULL_LIB) $(GETRANDOM_LIB)
  '';

  appletAliases = [ "cmp" "diff" "diff3" "sdiff" ];

  patched = (mingwPkgs.diffutils.override { coreutils = pkgs.coreutils; }).overrideAttrs (oa: {
    pname = "diffutils-multi";

    outputs = [ "out" ];

    # diffutils-inprocess.patch makes diff3/sdiff run the folded `diff` in
    # process. On mingw (no fork) the fork-free branch is the one compiled —
    # gated on -DUNPIN_MULTICALL, set on the diff3/sdiff recompiles below. No
    # cosmo-only patch here: mingw's errno (ELOOP) are integer constants so
    # diff.c's NOFOLLOW_SYMLINK_ERRNO enum builds, and mingw libc has no
    # `timespec_cmp` to collide with gnulib's.
    patches = (oa.patches or [ ]) ++ [ ./diffutils-inprocess.patch ];

    # mingw maps `execvp` to `_execvp`, whose prototype is `const char *const *`;
    # diff3.c/sdiff.c cast their argv to `(char **)`, which gcc-15 rejects as a
    # hard `-Wincompatible-pointer-types` error by default. Those execvp calls
    # live only in the upstream `#else` (non-UNPIN_MULTICALL) branch that the
    # normal `make` compiles but we discard — the recompiled .renamed objects
    # take the in-process path and contain no execvp. Downgrade the error so the
    # throwaway standalone objects still build.
    NIX_CFLAGS_COMPILE = (oa.NIX_CFLAGS_COMPILE or "") + " -Wno-error=incompatible-pointer-types";

    # Drop the baked `${coreutils}/bin/pr` PR_PROGRAM store path → bare `pr`
    # (looked up on PATH at runtime; coreutils stays build-only). Pin the
    # configure CACHE var: a *relative* PR_PROGRAM gets re-resolved against PATH
    # by AC_PATH_PROG (re-baking a store path), so `ac_cv_path_PR_PROGRAM=pr` is
    # what makes `#define PR_PROGRAM "pr"` stick. Same as native (flake.nix).
    configureFlags =
      (builtins.filter (f: !(pkgs.lib.hasPrefix "PR_PROGRAM=" f)) (oa.configureFlags or [ ]))
      ++ [ "ac_cv_path_PR_PROGRAM=pr" ];

    # Patching src/diff3.c + src/sdiff.c bumps their mtime past the shipped
    # man/diff3.1 + man/sdiff.1, so make re-fires `<tool>.1: <tool>.c <tool>.x`
    # → runs `man/help2man ./<tool>` (a mingw .exe that can't exec on the Linux
    # build host). The tarball ships the complete 3.12 pages, so stop the
    # regeneration: drop the `$(SRC_VERSION_C) help2man` aggregate prereq and
    # `touch` the pages so they out-date the patched sources. Same fix as the
    # other recipes. nixpkgs leaves postPatch present-but-null on this host.
    postPatch = (if (oa.postPatch or null) == null then "" else oa.postPatch) + ''
      substituteInPlace man/Makefile.in \
        --replace-fail '$(dist_man1_MANS): $(SRC_VERSION_C) help2man' '$(dist_man1_MANS):'
      touch man/*.1
    '';

    postBuild = (oa.postBuild or "") + ''
      mkdir -p multicall
      # applets.list (TSV name<TAB>fn) + shared Recipe-A dispatcher generator.
      # cmp/diff/diff3/sdiff are 1:1; an unknown/bare
      # name (incl. CI's renamed smoke.exe) routes to diff (defaultApplet). The
      # helper's copy_basename strips a trailing `.exe` and a `\\` dir prefix
      # before matching.
      printf 'cmp\tcmp\ndiff\tdiff\ndiff3\tdiff3\nsdiff\tsdiff\n' > multicall/applets.list
${unpins-lib.lib.multicallTableDispatcherC { name = "diffutils"; defaultApplet = "diff"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Recompile each main with -Dmain=<tool>_main; diff3/sdiff additionally get
      # -DUNPIN_MULTICALL so their patched call sites dispatch to the in-process
      # diff_main (provided at the multicall link by diff.o.renamed). Append to
      # $CPPFLAGS rather than replace, to keep any mingw-cross define/include.
      rm -f src/cmp.o src/diff.o src/diff3.o src/sdiff.o
      make -C src cmp.o   CPPFLAGS="$CPPFLAGS -Dmain=cmp_main"
      make -C src diff.o  CPPFLAGS="$CPPFLAGS -Dmain=diff_main -DUNPIN_MULTICALL"
      make -C src diff3.o CPPFLAGS="$CPPFLAGS -Dmain=diff3_main -DUNPIN_MULTICALL"
      make -C src sdiff.o CPPFLAGS="$CPPFLAGS -Dmain=sdiff_main -DUNPIN_MULTICALL"
      mv src/cmp.o   src/cmp.o.renamed
      mv src/diff.o  src/diff.o.renamed
      mv src/diff3.o src/diff3.o.renamed
      mv src/sdiff.o src/sdiff.o.renamed

      install -m644 ${multicallMk} src/unpin-multicall.mk
      make -C src -f Makefile -f unpin-multicall.mk multicall-link
    '';

    postInstall = (oa.postInstall or "") + ''
      rm -f $out/bin/cmp.exe $out/bin/diff.exe $out/bin/diff3.exe $out/bin/sdiff.exe
      install -m755 multicall/diffutils.exe $out/bin/diffutils.exe
    '';
  });
in
unpins-lib.lib.withAliases mingwPkgs
  {
    primary = "diffutils.exe";
    aliases = appletAliases;
  }
  patched
