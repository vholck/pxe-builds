# pxe-builds

Network boot images (public). They are deployed by the private repository `vholck/stacks` (compose, lab settings, issues); its `CLAUDE.md` has the lab and the session rules. What follows applies here. The README is for strangers: keep it general, with no lab or private references.

## How a change deploys

A push to `main` builds the changed image and pins it in `vholck/stacks` (`stacks/pxe/.env.override`, deploy key in secret `STACKS_DEPLOY_KEY`), and the boot host redeploys by itself 4 to 11+ minutes later. Every push to an image directory, `dts/` or `build.env` therefore reaches the live stack. Test risky changes on the boot host first. A session that cannot reach the lab works on a branch and does not push to `main`.

## Conventions

- **Public repository:** no passwords, tokens, keys or real e-mail addresses, and no MAC addresses or Pi serials of real boards (use `02:00:00:00:00:01`-style MACs and `1234abcd`-style serials). Private LAN addresses are fine.
- **Build settings** live only in `build.env`. Run-time settings are container variables, documented in each image's README and in `examples/compose/`.
- **No private references in public files:** no issue numbers of `vholck/stacks`, no paths or files of that repository, no "the lab", "the stack" or "the boot host"; describe things for any user of the images.
- **Patches** live under each image's `patches/`, are `-text` in `.gitattributes`, are made with `git diff` against the pinned upstream version, and fail the build when they no longer apply.
- **Deviations from upstream:** a commit that adds, changes or removes a patch, build option or pin updates its row in `UPSTREAM.md` and `UPSTREAM-TRACKING.md` in the same commit. Look for existing work upstream first (PRs, Patchwork series, forks). A new tracker row gets an entry in `.github/upstream-watch.json`.
- **Rules for all platforms:** a design rule is written for Pi 3, Pi 4, Pi 5, x86 BIOS and UEFI, not for the board on the bench.
- **Commits:** conventional prefixes (`feat(rpi-uboot-build): …`, `fix(ipxe-build): …`, `docs: …`, `ci: …`), a body that says what was tested, no `Co-Authored-By` line.
- **Line endings:** LF in the repository; strip CR when copying a script from a Windows working tree to a Linux host.
- Open work is tracked as issues in `vholck/stacks`. The upstream watch reports to the issue labelled `upstream-watch` here: review new comments, update `UPSTREAM-TRACKING.md`, then remove the label `upstream-change`.
