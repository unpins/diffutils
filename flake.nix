{
  description = "GNU diffutils (cmp, diff, diff3, sdiff) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Every target — Linux, macOS and Windows — compiles through the unpin-llvm
  # engine and self-folds `cmp` + `diff` + `diff3` + `sdiff` into one binary.
  #
  # The one thing diffutils needs that a fold does not give for free: diff3 and
  # sdiff RUN diff. Upstream spawns an external one, which a self-contained
  # binary does not ship, so diffutils-inprocess.patch points them at the folded
  # diff instead — see `inproc` below. Windows additionally has no fork, which
  # the same patch covers, and its `coreutils` build-input is overridden to the
  # native one (coreutils-x86_64-w64-mingw32 dies in gnulib lib/savewd.c on
  # waitpid; it is a build-time presence only, since PR_PROGRAM is bare `pr`).
  #
  # The residual Windows cost vs cosmo is `diff -r` mangling non-ASCII filenames
  # through msvcrt readdir; that is the accepted trade for a native PE. See
  # docs/platforms/mingw.md.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      programs = [
        { name = "cmp"; }
        { name = "diff"; }
        { name = "diff3"; }
        { name = "sdiff"; }
      ];

      # diff3 and sdiff run `diff`. Upstream execs an external one (or, with no
      # fork, popen("cmd /c diff")) — and a folded binary ships none, so before
      # this they found the SYSTEM's diff on PATH, or failed outright.
      # diffutils-inprocess.patch calls the folded diff instead, reaching it by
      # the fold's entry symbol for that program: `opt -internalize` keeps only
      # that one external, so it is the only name a sibling applet can call.
      # nix-lib spells it (lib.multicallEntrySym), we only pass it through.
      # With a working fork the call runs in a forked child for state isolation;
      # without one (Windows) diff's stdout is captured to a temp file and it
      # runs in this process.
      entryDiff = ulib.multicallEntrySym { name = "diffutils"; program = "diff"; };
      inproc = drv: drv.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./diffutils-inprocess.patch ];

        # Recompile the three affected objects AFTER the ordinary build, not
        # before: `make` links a standalone diff3 and sdiff, and the entry
        # symbol does not exist there — it is what the fold produces. The fold
        # re-reads each object at the path its capture sidecar recorded, and
        # the module hook's own postBuild is appended after this one, so
        # overwriting them in place is what it picks up. cmp calls nothing.
        # diff.o needs UNPIN_MULTICALL too: the fork-free path runs it in this
        # process, where it must not fclose the shared stdout.
        postBuild = (old.postBuild or "") + ''
          rm -f src/diff.o src/diff3.o src/sdiff.o
          make -C src diff.o   CPPFLAGS="$CPPFLAGS -DUNPIN_MULTICALL"
          make -C src diff3.o  CPPFLAGS="$CPPFLAGS -DUNPIN_MULTICALL -DUNPIN_ENTRY_DIFF=${entryDiff}"
          make -C src sdiff.o  CPPFLAGS="$CPPFLAGS -DUNPIN_MULTICALL -DUNPIN_ENTRY_DIFF=${entryDiff}"
          # …and date the linked programs past them, or `make install` sees the
          # fresher objects and relinks — with the entry symbol still undefined,
          # since only the fold defines it. The install output is discarded by
          # the fold anyway; what must survive is the objects.
          for __p in cmp diff diff3 sdiff; do
            for __f in "src/$__p" "src/$__p.exe"; do
              if [ -f "$__f" ]; then touch "$__f"; fi
            done
          done
        '';

        # Patching src/diff3.c + src/sdiff.c bumps their mtime past the shipped
        # man/diff3.1 + man/sdiff.1, so make re-fires `<tool>.1: <tool>.c` →
        # `help2man ./<tool>`, which RUNS the tool just built — impossible on
        # every cross target. The tarball ships the complete 3.12 pages: drop
        # the regeneration prereq and touch them past the patched sources.
        postPatch = (if (old.postPatch or null) == null then "" else old.postPatch) + ''
          substituteInPlace man/Makefile.in \
            --replace-fail '$(dist_man1_MANS): $(SRC_VERSION_C) help2man' '$(dist_man1_MANS):'
          touch man/*.1
        '';

        # `diff -l` (--paginate) shells out to `pr`. nixpkgs bakes the absolute
        # ${coreutils}/bin/pr via PR_PROGRAM — a /nix/store runtime-closure leak
        # (against the no-store-at-runtime rule). Drop that flag and pin the
        # configure CACHE var to bare `pr`: diffutils' AC_PATH_PROG re-resolves
        # a *relative* PR_PROGRAM against PATH (re-baking a store path), so
        # `PR_PROGRAM=pr` alone does NOT stick — `ac_cv_path_PR_PROGRAM=pr`
        # short-circuits the probe → `#define PR_PROGRAM "pr"`, looked up on
        # PATH at runtime.
        configureFlags =
          (builtins.filter (f: builtins.substring 0 11 f != "PR_PROGRAM=")
            (old.configureFlags or [ ]))
          ++ [ "ac_cv_path_PR_PROGRAM=pr" ];
      });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "diffutils";
      smoke = [ "--unpin-program=diff" "--version" ];
      smokePattern = "diff \\(GNU diffutils\\)";

      # Pure C, no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        inherit programs;
        # The `.exe` on the engine too, so Windows self-folds like the rest
        # instead of carrying its own hand-rolled fold.
        windows = true;
      };

      # coreutils is overridden to the native build one on every platform: it is
      # an unused build-input now (PR_PROGRAM is bare `pr`), and
      # pkgsStatic.coreutils drags pkgsStatic.gmp-with-cxx, whose configure
      # rejects the static build-clang on the Mac builder (and is pointless to
      # build on linux). Skip `make check`: gnulib's own multi-threaded /
      # getopt tests break under musl-static threads in the sandbox.
      build = pkgs: inproc
        ((pkgs.pkgsStatic.diffutils.override { coreutils = pkgs.buildPackages.coreutils; })
          .overrideAttrs (_: { doCheck = false; }));
      # mingw maps `execvp` to `_execvp`, whose prototype is `const char *const *`;
      # diff3.c/sdiff.c cast their argv to `(char **)`, which gcc-15 rejects as a
      # hard -Wincompatible-pointer-types error. Those calls are in the upstream
      # branch the ordinary build compiles and the fold discards — the objects it
      # keeps are the UNPIN_MULTICALL recompiles, which have no execvp at all.
      windowsBuild = pkgs: inproc
        (((ulib.mingwStaticCross pkgs).diffutils.override { coreutils = pkgs.coreutils; })
          .overrideAttrs (old: {
            NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "")
              + " -Wno-error=incompatible-pointer-types";
          }));
    };
}
