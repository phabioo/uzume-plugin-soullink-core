# Uzume Plugin: SoulLink Core

Shared Pokémon foundation: game detection, memory adapters and asset extraction for other Uzume plugins.

Status: **in progress: game detection for Gen 3-7, `pokemon.core` interface, Omega Ruby/Alpha Sapphire adapter (team with live stats, boxes, trainer, badges, location, encounter areas, battle, wild encounters, names from game text, write helpers for the Creature Editor).**

Build and test (needs `lua5.4`): `lua5.4 tools/bundle.lua` (writes `plugin/main.lua`), `lua5.4 tests/run.lua`.

## Releasing

1. Bump `version` in `plugin/manifest.json` and merge.
2. Release `vX.Y.Z` (must equal the manifest version), either by pushing the tag or by running "Release" in Actions on `main` with the tag as input; the latter creates the tag at that commit. The `Release` workflow runs the checks, builds the unsigned `uzume.soullink-core-X.Y.Z.fbplugin` (`python3 tools/package.py`) and attaches it to the GitHub release. Re-running with an existing tag replaces the asset. The release notes are collected from the `## Changelog` sections of the merged PRs since the previous tag (`tools/changelog.py`).
3. Run "Publish plugin" in phabioo/uzume with this repository and the tag; it downloads, signs and indexes the package.

Requires Uzume 0.11 or later (plugin API v1). Part of [Uzume](https://github.com/phabioo/uzume); plugin interface: `docs/architecture/12-plugins.md` there. Plan: [docs/roadmap.md](docs/roadmap.md).

License: GPL-3.0-or-later, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Contributions under the [CLA](CLA.md).

Pokémon and Nintendo are trademarks of their owners. This project is not affiliated with them and contains no game content.
