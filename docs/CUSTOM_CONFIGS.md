# Custom configs — deviations from the stock GTNH pack

This server's `mods/`, `libraries/` and `journeymap/` are wholesale-replaced
on every modpack update, and the pack's `config/` is copied over the live one
(see the "Update GTNH server to X" commits). Anything listed here is a
deliberate deviation from the pack's shipped defaults and must be manually
re-applied (or verified) after each such update, because a plain file
overwrite silently reverts it.

Since the 2.9.0-RC-2 update (2026-10-04) the pack's `config/` is **overlaid**
(`cp -a pack/config/. config/`), not wholesale-replaced: config files that
exist only on this server (mod-generated at runtime, `config/worldedit/`, …)
are kept. The beta-3 update had deleted 153 such files instead.

Last verified: 2026-10-04, during the 2.9.0-beta-3 → 2.9.0-RC-2 update.

## config/hodgepodge.cfg

- `speedupChunkCompression=false` (pack default: `true`). **Critical** —
  re-enabling this reintroduces the torn-chunk bug documented in
  [OPERATIONS.md](../OPERATIONS.md) ("Torn chunks" post-mortem, 2026-09-02):
  Hodgepodge's `FastChunkWrite` mixin shares one NBT buffer across concurrent
  writers with no synchronization. Hodgepodge 2.7.209 (shipped since
  2.9.0-RC-1) lists "Fix chunk NBT corruption during concurrent saves"
  (GTNewHorizons/Hodgepodge#1002), which may be the upstream fix for this
  bug. Not verified against our repro; the value stays `false` until someone
  reads that PR and decides to re-enable it.
- `autoSaveInterval=6000` (pack default: `900`). A 2026-02-18 tuning commit
  (`064f792579`) raised this from 900 (45s) to 6000 (5min) to cut the I/O
  stall every autosave causes. It was silently reverted back to 900 by the
  2.9.0-beta-2 update (`fdaff6fa43`) and stayed there, unnoticed, until the
  2.9.0-beta-3 update (2026-09-06) caught and reapplied it. Trade-off: a
  longer interval means more unsaved world state sits only in RAM between
  autosaves, so a hard crash (not a graceful `gtnh stop`) loses more progress
  since the last write — not a torn-chunk risk, that's fixed at the root by
  `speedupChunkCompression=false` above.

## config/GregTech/Pollution.cfg

- `B:"Activate Pollution"=false` (pack default: `true`). Set 2026-08-29
  (`768b502f82`).

## config/forgeChunkLoading.cfg

- `witchery { maximumChunksPerTicket=0, maximumTicketCount=0 }` and
  `ThaumicExploration { maximumChunksPerTicket=0, maximumTicketCount=0 }`.
  Set 2026-09-04 (`6dcf71d328`) to stop three leftover chunkloaders (a
  witchery poppet shelf + two ThaumicExploration warp blocks) belonging to an
  abandoned base from anchoring ~250 chunks and causing a 20s stall on every
  autosave. Mod-wide zero is safe only because every chunkloading ticket for
  those two mods in this world belongs to those specific blocks — revert if
  either mod is used for chunkloading elsewhere later.

## config/ae2fc.cfg

- `I:maxTick=600` (pack default: `120`), in the `levelmaintainer` block. Set
  2026-09-09: the 61 ME Level Maintainers were 17% of server CPU per tick;
  600 cut tick cost from 40.55 to 33.68 ms (A/B/A measured). Game cost: a
  Level Maintainer checks stock every 30 s instead of 6 s. Missing from this
  list until the RC-2 update caught it.

## config/gendustry/overrides/tuning.cfg — NOT in effect

Set 2025-03-28 (`0465ed5707`) and 2025-03-23 (`9f1beba220`), then lost
silently in some update before 2.9.0-beta-2: at `fdaff6fa43~1` and every
commit since, the file has the pack values. This list claimed them as live
until 2026-10-04. Not re-applied during the RC-2 update, because the server
has been played with the pack values for months; re-enabling is an owner
decision. The original deviations were:

- `cfg Machines` (both breeding tiers): `DegradeChanceNatural=0` and
  `DeathChanceArtificial=0` (pack defaults: 30/10 and 80/50 respectively) —
  removes the RNG punishment on bee mutation.
- `cfg Imprinter { Enabled=No }` (pack default: `Yes`).

RC-2 also changes the pack's own value for the GregTech bee species
`Cosmicneutronium`, `Infinitycatalyst` and `Infinity` from `DISABLED` to
`REQUIREMENTS`; the RC-2 value was taken.

## config/galacticgreg/GalacticGreg.cfg — gone

Was gitignored and listed here as a deliberate deviation (all four
`buildinmods` registers `false`). As of 2026-10-04 neither the live server
nor the RC-2 pack has a `config/galacticgreg/` directory, so there is
nothing left to preserve.

## mods/worldedit-v0.0.10.jar and config/worldedit/

WorldEdit for GTNH (GTNewHorizons/worldedit-gtnh, release `v0.0.10`),
installed 2026-09-12; not part of the stock pack. Tracked in git. Restore the
jar after a `mods/` replace with `git checkout HEAD -- mods/worldedit-v0.0.10.jar`;
`config/worldedit/` survives the config overlay.

## mods/OpenSecurity/sounds/

Two `.ogg` alarm sounds the OpenSecurity mod writes at runtime; not in the
pack zip. Restored from git after the `mods/` replace so the tree does not
churn; the mod would recreate them anyway.

## mods/ic2/EJML-core-0.26.jar

Not part of the stock pack (absent from the 2.9.0-beta-3 and RC-2 zips). Tracked in
git. A wholesale `rm -rf mods/` + pack copy will drop it unless restored with
`git checkout HEAD -- mods/ic2`.

## serverutilities/serverutilities.cfg

Never touched by the update process (the whole `serverutilities/` folder is
excluded — it also holds live player data: `server/players.txt`,
`server/ranks.txt`, `server/stat_leaderboards.json`). Heavily customized
relative to the pack default, notably:

- Convenience commands `back/fly/god/heal/home/kickme/mute/nick/rec/rtp/spawn/tpa/warp`
  all `true` (pack default: all `false`).
- `chunk_claiming=true`, `safe_spawn=true` (pack defaults: `false`).
- `rtp_max_distance=10000.0` (pack default: `100000.0`).
- Custom MOTD text and a custom starting item (Epic Stone Sword).
- Built-in backup subsystem tuned down/disabled (`enable_backups=false`,
  `silent_backup=true`, different timer/retention/compression) — redundant
  with `gtnh`'s own git-based hourly backup.

As of the 2.9.0-beta-3 pack (ServerUtilities 2.4.1 → 2.4.9), the fresh
default file also defines whole new blocks (`mixins`, `motd`, `tab`,
`transfer`, `pregen`) that don't exist yet in this server's live file — Forge
will auto-populate them with the mod's new defaults on the next boot, which
is normal and not something to "fix".
