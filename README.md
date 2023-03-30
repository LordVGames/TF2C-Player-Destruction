# TF2C-Player-Destruction

A plugin that recreates the player destruction gamemode from TF2, in TF2C.

No leaked source code was used in the making of this plugin.

## Demo video

https://user-images.githubusercontent.com/51967559/228964518-0ef13fe7-bb6e-4075-bc3e-9b9809eaffdf.mp4

## Dependencies
The following plugins are needed to run and compile the plugin.
 - [TF2Classic Tools](https://github.com/tf2classic/SM-TF2Classic-Tools)
 - [CustomKeyValues](https://forums.alliedmods.net/showthread.php?p=2588562)
 - [Entity IO](https://github.com/Ilusion9/entityIO-sm)

One more step is needed, as CustomKeyValues doesn't work out of the box.
You'll need to copy/paste the `"tf"` section of CustomKeyValues' gamedata file, and rename `tf` to `tf2classic`.

## Usage

**For clients and servers: it may be needed to mount live TF2, especially if you're going to play on live TF2's PD maps.**

If you do not plan to host 4 team player destruction maps, use the base version. Otherwise, use the 4 team version, as it still supports 2 team player destruction maps.

Stripper: Source map configs are provided for the existing TF2 player destruction maps.

When compiling, do not compile the `_logic` file, as that file is included into the main plugin file.

## Porting/making maps
Nearly all original I/O and keyvalues related to the gamemode found in TF2 are usable. However, there are catches to some aspects.

### Main logic entity
Since the player destruction logic entity doesn't exist in TF2C, the replacement is the domination logic entity.

You can put the player destruction related keyvalues on the logic entity by turning off SmartEdit and adding them manually. Only 1 keyvalue is not needed, that being `res_file`.

The keyvalues native to the logic entity that *need* to be changed are `win_on_limit` and `kills_give_points`, which need to be set to `0`. The keyvalue `point_limit` doesn't matter, as it will be changed by the plugin if using the input `EnableMaxScoreUpdating`.

Along with the domination logic entity, Yyu also need to add a `team_control_point_master` entity. The keyvalues don't need to be changed.

### Inputs
The only inputs not supported are `SetCountdownImage`, and inputs named something like `AddRedPoints` and `OnRedHitMaxPoints`.

Instead of `AddRedPoints`, use the domination logic entity equivalent `ScoreRedPoints` with a parameter of `1`. Inputs like `OnRedHitMaxPoints` need to be replaced with `OnPointLimitRed`.

### Outputs
The gamemode-related outputs need an extra step when being setup. Each one *must* be numbered at the end, starting from 1. This is due to how I setup reading the custom outputs.

For example:
 - `OnCapTeam1_PD1`
 - `OnCapTeam2_PD1`
 - `OnCapTeam2_PD2`

All other parts of the output can be setup as normal.

### 4 team specific

All I/O that have red and blue team variations now also have 4 team versions. Just replace `Red` with `Green` or `Yellow`, `Team1` with `Team3`, and so on. They must still be numbered as outlined in [Outputs](#outputs).

To make a player destruction map 4 team, do it the same way you would with any other 4 team map.
## Why 2 plugin versions?
There are 2 versions of the plugin so that if someone wanted to port the gamemode to another source game, they can start with the base version, as it does not have the 4 team related code.
