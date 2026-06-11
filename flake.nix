{
  description = "GNU diffutils (cmp, diff, diff3, sdiff) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Linux/macOS: pkgsStatic.diffutils → post-link multicall recipe in
  # ./multicall.nix folds `cmp` + `diff` + `diff3` + `sdiff` into one
  # `diffutils` binary (lib.withAliases embeds the applet names).
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
      build = pkgs:
        import ./multicall.nix {
          lib = pkgs.lib // unpins-lib.lib;
        } pkgs;
    };
}
