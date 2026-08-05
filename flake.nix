{
  description = "GNU diffutils (cmp, diff, diff3, sdiff) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Linux + macOS: the unpin-llvm engine compiles pkgsStatic.diffutils to
  # bitcode and the standalone self-folds `cmp` + `diff` + `diff3` + `sdiff`
  # into one `diffutils` binary (like coreutils — no hand-rolled fold).
  # Windows: native mingw PE (`windowsBuild = import ./windows.nix …`). The two
  # historical mingw blockers are handled: (1) diff3/sdiff's lack of fork — they
  # `popen` an external `diff` — is replaced by diffutils-inprocess.patch's
  # fork-free in-process `diff_main`; (2) the coreutils-mingw `lib/savewd.c`
  # `waitpid` failure is dodged by overriding `coreutils` to native. The only
  # residual cost vs cosmo is `diff -r` mangling non-ASCII filenames (msvcrt
  # readdir). See docs/platforms/mingw.md.
  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "diffutils";
      windowsBuild = import ./windows.nix { inherit unpins-lib; };
      smoke = [ "--unpin-program=diff" "--version" ];
      smokePattern = "diff \\(GNU diffutils\\)";

      # Pure C, no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        programs = [
          { name = "cmp"; }
          { name = "diff"; }
          { name = "diff3"; }
          { name = "sdiff"; }
        ];
      };
      # Linux + darwin both self-fold through the engine (apps → bitcode →
      # selfFold). diffutils builds no shared lib, so darwin needs no
      # --disable-shared (unlike bzip2's libbz2). Skip `make check`: gnulib's
      # own multi-threaded / getopt tests break under musl-static threads in the
      # sandbox.
      #
      # coreutils is overridden to the native build one on every platform: it is
      # an unused build-input now (PR_PROGRAM is bare `pr`, see below), and
      # pkgsStatic.coreutils drags pkgsStatic.gmp-with-cxx, whose configure
      # rejects the static build-clang on the Mac builder (and is pointless to
      # build on linux).
      build = pkgs:
        (pkgs.pkgsStatic.diffutils.override { coreutils = pkgs.buildPackages.coreutils; }).overrideAttrs (old: {
          doCheck = false;
          # `diff -l` (--paginate) shells out to `pr`. nixpkgs bakes the absolute
          # ${coreutils}/bin/pr via PR_PROGRAM — a /nix/store runtime-closure leak
          # (against the no-store-at-runtime rule). Drop that flag and pin the
          # configure CACHE var to bare `pr`: diffutils' AC_PATH_PROG re-resolves
          # a *relative* PR_PROGRAM against PATH (re-baking a store path), so
          # `PR_PROGRAM=pr` alone does NOT stick — `ac_cv_path_PR_PROGRAM=pr`
          # short-circuits the probe → `#define PR_PROGRAM "pr"`, looked up on
          # PATH at runtime.
          configureFlags =
            (builtins.filter (f: !(pkgs.lib.hasPrefix "PR_PROGRAM=" f)) (old.configureFlags or [ ]))
            ++ [ "ac_cv_path_PR_PROGRAM=pr" ];
        });
    };
}
