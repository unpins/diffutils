# Upstream diffutils is four binaries — cmp, diff, diff3, sdiff — built from
# object files in src/. To honour the unpins one-pkg-one-bin rule we post-link
# them into a single multicall ELF/Mach-O.
#
# Why this is the *simple* Recipe-A case (cf. util-linux's 123-tool auto-scan):
# the four programs share exactly one helper object — src/system.o, compiled
# once and linked into all four — and the ONLY symbol they collide on is `main`
# (every other top-level name in cmp.c/diff.c/diff3.c/sdiff.c, incl. `usage`,
# `check_stdout`, `fatal`, is `static`). So this is the findutils shape: rename
# each `main`, link the union of objects once, dispatch on argv[0].
#
#   1. Let `make` run upstream normally → cmp/diff/diff3/sdiff plus every .o
#      (src/{cmp,diff,diff3,sdiff,analyze,context,dir,ed,ifdef,io,normal,side,
#      system,util}.o, src/libver.a, lib/libdiffutils.a) land in the tree.
#   2. Recompile each tool's main TU with `-Dmain=<tool>_main` so cpp rewrites
#      the symbol BEFORE compilation. We must do it at preprocessor time, not
#      via `objcopy --redefine-sym` on the existing .o: pkgsStatic uses fat-LTO,
#      and objcopy only renames the native side — lto-plugin reads the bitcode
#      side at final link and still sees `main`, leaving the dispatcher's
#      `<tool>_main` refs unresolved. (The mingw path, ./windows.nix, also
#      recompiles, but mainly because diff3/sdiff must pick up -DUNPIN_MULTICALL.)
#   3. Compile a dispatcher.o (basename(argv[0]) → <tool>_main) via the shared
#      Recipe-A generator (lib.multicallTableDispatcherC).
#   4. Delegate the final link to src/Makefile via an injected
#      `unpin-multicall.mk`. Reason (same as findutils): `$(LDADD)` resolves to
#      a dozen configure-driven vars (CLOCK_TIME_LIB, HARD_LOCALE_LIB, LIBINTL,
#      LIBSIGSEGV, LIBUNISTRING, MBRTOWC_LIB, SETLOCALE_NULL_LIB, GETRANDOM_LIB,
#      …) that differ per target. Letting make substitute them against src/'s
#      own context keeps every detail intact. We reuse src/Makefile's own
#      `$(LINK)` recipe macro for the compiler + flags.
#   5. Strip upstream's four binaries and replace with one `diffutils` plus
#      cmp/diff/diff3/sdiff applet symlinks. `lib.withAliases` harvests the
#      symlinks, embeds the names in the binary's `unpin/aliases`, and strips
#      them.
{ lib }:
pkgs:
let
  # Custom Makefile fragment lives in src/. $(top_builddir) is one level up so
  # multicall/dispatcher.o and lib/libdiffutils.a resolve; the renamed mains,
  # the shared helper objects and libver.a are src-relative (make runs -C src).
  multicallMk = pkgs.writeText "unpin-multicall.mk" ''
    MULTI_OUT ?= $(top_builddir)/multicall/diffutils

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

  multicall = pkgs.pkgsStatic.diffutils.overrideAttrs (old: {
    pname = "diffutils-multi";

    # Collapse to a single output (nixpkgs splits out an `info` output; we ship
    # only the binary + man, so a separate info output would be left empty).
    outputs = [ "out" ];

    # diff3 and sdiff normally run `diff` as an *external* program (fork+execvp
    # of whatever `diff` is on PATH; popen on no-fork hosts). In a single
    # standalone binary there is no external `diff` to find, so that would break
    # the moment the binary runs without our applet symlinks on PATH. This patch
    # gates both call sites behind `UNPIN_MULTICALL`: instead of execvp-ing, the
    # folded `diff_main` is called IN-PROCESS — here (fork hosts) in a forked
    # child for state isolation; on no-fork hosts (mingw, see ./windows.nix) via
    # a temp-file capture. Same principle as playground/git's mc_try_dispatch.
    # The patch also makes diff's check_stdout fflush (not fclose) the shared
    # stdout under UNPIN_MULTICALL, so an in-process diff_main doesn't close the
    # caller's stdout. The `#ifdef` keeps upstream's behaviour for the normal
    # build (the throwaway standalone diff3/diff that `make` links don't carry
    # diff_main); only the `.renamed` objects below carry the define — diff.o
    # for check_stdout, diff3.o/sdiff.o for the call sites. See the patch for the
    # fork / optind / flush details.
    patches = (old.patches or [ ]) ++ [ ./diffutils-inprocess.patch ];

    # Patching src/diff3.c + src/sdiff.c (above) bumps their mtime past the
    # shipped man/diff3.1 + man/sdiff.1, so make re-fires the per-page rule
    # `<tool>.1: <tool>.c <tool>.x` → runs `man/help2man`, whose
    # `#!/usr/bin/env perl` shebang has no /usr/bin/env in the sandbox →
    # `Error 126`. The tarball already ships the complete 3.12 pages, so stop
    # the regeneration: drop the `$(SRC_VERSION_C) help2man` aggregate prereq
    # (version.c is rebuilt every run, which would otherwise always re-trigger)
    # and `touch` the pages so they out-date the just-patched sources. Same fix,
    # same reason as ./windows.nix — needed here only since this patch now also
    # edits sources. nixpkgs leaves postPatch present-but-null on this host
    # (`or ""` wouldn't catch it), so guard explicitly.
    postPatch = (if (old.postPatch or null) == null then "" else old.postPatch) + ''
      substituteInPlace man/Makefile.in \
        --replace-fail '$(dist_man1_MANS): $(SRC_VERSION_C) help2man' '$(dist_man1_MANS):'
      touch man/*.1
    '';

    # Skip upstream's `make check`: the only failures are gnulib's own
    # multi-threaded / getopt tests (`test-thread_create` glthread_create,
    # `test-getopt-*` optind), which break under musl-static threads in the nix
    # sandbox — environment artifacts, not diffutils behaviour. action-build
    # smoke-tests the real binary instead. (Also moot: postBuild renames each
    # main out of the tree, so re-running upstream tests here is meaningless.)
    doCheck = false;

    # `diff -l` (--paginate) shells out to `pr`. nixpkgs bakes the absolute
    # `${coreutils}/bin/pr` store path via PR_PROGRAM, which (a) makes coreutils
    # a runtime closure dep — against the no-/nix/store-at-runtime rule — and
    # (b) is a dead path on the user's machine anyway. Replace it with bare
    # `pr` so diff looks it up on PATH at runtime. coreutils stays a build-only
    # input; with the store path gone it's no longer referenced by the output.
    configureFlags =
      (builtins.filter (f: !(lib.hasPrefix "PR_PROGRAM=" f)) (old.configureFlags or [ ]))
      ++ [ "PR_PROGRAM=pr" ];

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall
      # applets.list (TSV name<TAB>fn) for the shared Recipe-A dispatcher
      # generator. cmp/diff/diff3/sdiff are 1:1; a bare/unknown invocation
      # (incl. CI's renamed smoke binary) routes to diff (defaultApplet), whose
      # getopt handles --version regardless of argv[0].
      printf 'cmp\tcmp\ndiff\tdiff\ndiff3\tdiff3\nsdiff\tsdiff\n' > multicall/applets.list
${lib.multicallTableDispatcherC { name = "diffutils"; defaultApplet = "diff"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Source-level rename: pre-process each main TU with `-Dmain=<tool>_main`
      # so cpp rewrites the name before compilation, producing a .o (fat-LTO
      # bitcode + native) where the symbol is already <tool>_main on both sides.
      # CPPFLAGS override is safe: automake's compile rule is
      # `$(CC) $(DEFS) $(DEFAULT_INCLUDES) $(INCLUDES) $(AM_CPPFLAGS) $(CPPFLAGS) …`
      # — DEFS (HAVE_CONFIG_H) and the -I../lib includes come from configure
      # output / AM_CPPFLAGS, not the env CPPFLAGS slot we replace here.
      # diff.o/diff3.o/sdiff.o get -DUNPIN_MULTICALL: diff.o for the check_stdout
      # fflush guard; diff3.o/sdiff.o for the in-process call sites (which is also
      # why those two only resolve at the multicall link — diff_main is provided
      # by diff.o.renamed, not by a standalone diff3/sdiff). cmp.o needs neither.
      rm -f src/cmp.o src/diff.o src/diff3.o src/sdiff.o
      make -C src cmp.o   CPPFLAGS="-Dmain=cmp_main"
      make -C src diff.o  CPPFLAGS="-Dmain=diff_main -DUNPIN_MULTICALL"
      make -C src diff3.o CPPFLAGS="-Dmain=diff3_main -DUNPIN_MULTICALL"
      make -C src sdiff.o CPPFLAGS="-Dmain=sdiff_main -DUNPIN_MULTICALL"
      mv src/cmp.o   src/cmp.o.renamed
      mv src/diff.o  src/diff.o.renamed
      mv src/diff3.o src/diff3.o.renamed
      mv src/sdiff.o src/sdiff.o.renamed

      install -m644 ${multicallMk} src/unpin-multicall.mk
      make -C src -f Makefile -f unpin-multicall.mk multicall-link
    '';

    postInstall = (old.postInstall or "") + ''
      rm -f $out/bin/cmp $out/bin/diff $out/bin/diff3 $out/bin/sdiff
      install -m755 multicall/diffutils $out/bin/diffutils
      for n in ${lib.concatStringsSep " " appletAliases}; do
        ln -s diffutils $out/bin/$n
      done
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "diffutils";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
