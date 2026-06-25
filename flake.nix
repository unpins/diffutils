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
      smoke = [ "--version" ];
      smokePattern = "diff \\(GNU diffutils\\)";

      # `diffutils --version` (the bare binary name) routes to diff, so
      # defaultProgram pins it — `diffutils` is not itself one of the applets.
      # Pure C, no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        defaultProgram = "diff";
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
      # sandbox. Also drop the coreutils `${pr}` store-path leak from PR_PROGRAM
      # (diff -l shells out to `pr`; bare `pr` is looked up on PATH at runtime).
      build = pkgs:
        let
          # darwin: pkgsStatic.coreutils drags pkgsStatic.gmp-with-cxx, whose
          # configure rejects the static build-clang ("CC_FOR_BUILD doesn't seem
          # to work") on the Mac builder. coreutils is only a build-time input
          # (PR_PROGRAM is bare `pr`), so swap in the native build coreutils to
          # drop the static gmp dep — same override windows.nix uses for mingw.
          # Linux keeps pkgsStatic.coreutils (its gmp builds fine).
          base =
            if pkgs.stdenv.hostPlatform.isDarwin
            then pkgs.pkgsStatic.diffutils.override { coreutils = pkgs.buildPackages.coreutils; }
            else pkgs.pkgsStatic.diffutils;
        in
        base.overrideAttrs (old: {
          doCheck = false;
          configureFlags =
            (builtins.filter (f: !(pkgs.lib.hasPrefix "PR_PROGRAM=" f)) (old.configureFlags or [ ]))
            ++ [ "PR_PROGRAM=pr" ];
        });
    };
}
