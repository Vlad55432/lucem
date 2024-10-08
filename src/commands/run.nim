## Run the Roblox client, update FFlags and optionally, provide Discord RPC.
## Copyright (C) 2024 Trayambak Rai
import std/[os, logging, strutils, json, times]
import discord_rpc
import ../api/[games, thumbnails, ipinfo]
import ../[config, flatpak, common, meta, sugar, notifications]

const
  FFlagsFile* = "$1/.var/app/$2/data/sober/exe/ClientSettings/ClientAppSettings.json"

let fflagsFile = FFlagsFile % [getHomeDir(), SOBER_APP_ID]

proc updateFFlags*(config: Config) =
  info "lucem: updating FFlags"
  if not fileExists(fflagsFile):
    error "lucem: could not open pre-existing FFlags file. Run `lucem init` first."
    quit(1)
  
  var fflags = readFile(fflagsFile).parseJson()

  info "lucem: target FPS is set to: " & $config.client.targetFps
  fflags["DFIntTaskSchedulerService"] = newJInt(int(config.client.targetFps))

  if config.client.disableTelemetry:
    info "lucem: disabling telemetry FFlags"
  else:
    warn "lucem: enabling telemetry FFlags. This is not recommended!"

  for flag in [
    "FFlagDebugDisableTelemetryEphemeralCounter",
    "FFlagDebugDisableTelemetryEphemeralStat",
    "FFlagDebugDisableTelemetryEventIngest",
    "FFlagDebugDisableTelemetryPoint",
    "FFlagDebugDisableTelemetryV2Counter",
    "FFlagDebugDisableTelemetryV2Event",
    "FFlagDebugDisableTelemetryV2Stat"
  ]:
    debug "lucem: set flag `" & flag & "` to " & $config.client.disableTelemetry
    fflags[flag] = newJBool(config.client.disableTelemetry)

  if config.client.fflags.len > 0:
    for flag in config.client.fflags.split('\n'):
      let splitted = flag.split('=')

      if splitted.len < 2:
        error "lucem: error whilst parsing FFlag (" & flag & "): only got key, no value to complete the pair was found."
        quit(1)

      if splitted.len > 2:
        error "lucem: error whilst parsing FFlag (" & flag & "): got more than two splits, key and value were already found."
        quit(1)

      let
        key = splitted[0]
        val = splitted[1]

      if val.startsWith('"') and val.endsWith('"'):
        fflags[key] = newJString(val)
      elif val in ["true", "false"]:
        fflags[key] = newJBool(parseBool(val))
      else:
        var allInt = false

        for c in val:
          if c in {'0' .. '9'}:
            allInt = true
          else:
            allInt = false
            break

        if allInt:
          fflags[key] = newJInt(parseInt(val))
        else:
          warn "lucem: cannot handle FFlag (key=$1, val=$2); ignoring." % [key, val]
          continue

  let serialized = pretty(fflags)
  info "Writing FFlags JSON:"
  info serialized

  writeFile(fflagsFile, serialized)

proc onGameJoin*(config: Config, data: string, discord: Option[DiscordRPC], startedAt: float) =
  var
    foundBeginningOfJson = false
    jdata: string

  for c in data:
    if not foundBeginningOfJson:
      if c == '{':
        foundBeginningOfJson = true
        jdata &= c

      continue
    else:
      jdata &= c

  debug "lucem: join metadata: " & jdata
  
  if config.lucem.discordRpc:
    let 
      placeId = $parseJson(jdata)["placeId"].getInt()
      universeId = getUniverseFromPlace(placeId)
      client = &discord
    
      gameData = getGameDetail(universeId)
      thumbnail = getGameIcon(universeId)
  
    if !gameData:
      warn "lucem: failed to fetch game data; RPC will not be set."
      return

    if !thumbnail:
      warn "lucem: failed to fetch game thumbnail; RPC will not be set."
      return

    let 
      data = &gameData
      icon = &thumbnail

    info "lucem: Joined game!"
    info "Name: " & data.name & '"'
    info "Description: " & data.description
    info "Price: " & $data.price & " robux"
    info "Developer: "
    info "  Name: " & data.creator.name
    info "  Verified: " & $data.creator.hasVerifiedBadge

    client.setActivity(Activity(
      details: data.name,
      state: "In-Game",
      assets: some(
        ActivityAssets(
          largeImage: icon.imageUrl,
          largeText: "Sober + Lucem v" & Version
        )
      ),
      timestamps: ActivityTimestamps(
        start: startedAt.int64
      )
    ))

proc onServerIpRevealed*(config: Config, line: string) =
  if not config.lucem.notifyServerRegion:
    return

  var
    buffer: string
    pos = -1
  
  debug "lucem: server IP line buffer: " & line

  while pos < line.len - 1:
    inc pos

    if buffer.endsWith("UDMUX server "):
      break

    buffer &= line[pos]
  
  debug "lucem: server IP line buffer stopped before splitting at: " & $pos
  let serverIp = line[pos ..< line.len].split(',')[0].split(':')[0] # discard port, we don't need it.
  debug "lucem: server IP is: " & serverIp

  if (let ipinfo = getIpInfo(serverIp); *ipinfo):
    let data = &ipinfo
    notify(
      "Server Location",
      "This server is located in $1, $2, $3" % [data.city, data.region, data.country]
    )
  else:
    warn "lucem: failed to get server location data!"
    notify("Server Location", "Failed to fetch server location data.")

proc runRoblox*(config: Config) =
  var startingTime = epochTime()
  info "lucem: running Roblox via Sober"

  writeFile("/tmp/sober.log", newString(0))
  var discord: Option[DiscordRPC]
  
  if config.lucem.discordRpc:
    info "lucem: connecting to Discord RPC"
    var client = newDiscordRPC(DiscordRpcId.int64)
    discard client.connect()

    client.setActivity(Activity(
      details: "Playing Roblox with Lucem (Sober)",
      state: "In the Roblox app",
      timestamps: ActivityTimestamps(
        start: startingTime.int64
      )
    ))

    discord = some(move(client))

  flatpakRun(SOBER_APP_ID, "/tmp/sober.log") # point all logs to /tmp/sober.log

  var 
    line = 0
    startedPlayingAt = 0.0
    hasntStarted = true

  while hasntStarted or flatpakRunning(SOBER_APP_ID):
    let logFile = readFile("/tmp/sober.log").splitLines()

    if logFile.len - 1 < line:
      continue

    let data = logFile[line]
    if data.len < 1:
      inc line
      continue

    debug "$2" % [$line, data]

    if data.contains("[FLog::GameJoinUtil] GameJoinUtil::joinGamePostStandard: URL: https://gamejoin.roblox.com/v1/join-game BODY:"):
      startedPlayingAt = epochTime()
      startingTime = startedPlayingAt

      onGameJoin(config, data, discord, startedPlayingAt)

    if data.contains("[FLog::Output] Connecting to UDMUX server"):
      onServerIpRevealed(config, data)

    hasntStarted = false
    inc line

  info "lucem: Sober seems to have exited - we'll stop here too. Adios!"
