#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2c>
#include <customkeyvalues>



/*
	------------------
	TEXT CHANNEL USAGE
	------------------

	1 - BLU Uncapped Pickups
	2 - RED Uncapped Pickups
	3 - Pickups currently held by player
	4 - Player's team leader status
	5 - Capture zone opening/closing countdown
	5 - Team victory countdown (replaces the capture zone countdown)
*/

#define VERSION "1.0.2"
#define TAG "[PD]"

#define MAX_CAPTURE_DELAY 5.0
#define DEFAULT_CAPTURE_DELAY 1.1
#define MIN_CAPTURE_DELAY 0.33
#define DEFAULT_CAPTURE_DELAY_OFFSET 0.025

#define SMALL_INT_CHAR 3
#define SMALL_FLOAT_CHAR 6
#define TRIGGER_MODEL "models/custom_models/hatstand/hatstand.mdl"



//#define DEBUG_PICKUPS
//#define DEBUG_LEADER
//#define DEBUG_DISPENSER
//#define DEBUG_GLOW
//#define DEBUG_HUD
//#define DEBUG_CAPTUREZONE

enum DebugType
{
	Debug_Pickups,
	Debug_Leader,
	Debug_Dispenser,
	Debug_Glow,
	Debug_HUD,
	Debug_CaptureZone,
}

enum // HUD text channels
{
	Channel_BluePickups = 1,
	Channel_RedPickups,
	Channel_PlayerPickups,
	Channel_TeamLeader,
	Channel_Countdown,
}



// Player
int g_PickupCount[MAXPLAYERS + 1];
int g_PrevPickupCount[MAXPLAYERS + 1];
int g_CarriedFlagEnt[MAXPLAYERS + 1] = {-1, ...};
int g_WasCarryingFlag[MAXPLAYERS + 1] = {-1, ...};
int g_PlayerInCaptureZones[MAXPLAYERS + 1][2];
bool g_IsInRespawnRoom[MAXPLAYERS + 1];

// Gamemode
int g_DomLogicEnt;
int g_TopPickupCount_Red, g_TopPickupCount_Blue;
char g_PickupModel[64], g_PickupModel_Big[64];
char g_PickupSound_Drop[64], g_PickupSound_Collect[64];
bool g_IsInWaitingForPlayersTime;
int g_PlayerCountForCaptureDelay;

// Team leader
int g_TeamLeader_Red = -1;
int g_TeamLeader_Blue = -1;
int g_TeamLeader_DispenserEnt_Red = -1;
int g_TeamLeader_DispenserEnt_Blue = -1;
int g_TeamLeader_GlowEnt_Red = -1;
int g_TeamLeader_GlowEnt_Blue = -1;
// For the dispenser trigger outlining
int g_iLaserMaterial;
int g_iHaloMaterial;

// HUD
bool g_HudTimer_FirstFinaleCountdown;
int g_HudTimerNum_Finale;
int g_HudTimerNum_CaptureZone;
int g_HudTextColor_Red[3] = {250, 80, 80};
int g_HudTextColor_Blue[3] = {80, 160, 250};

// Arrays
Handle g_CaptureZonesBlocking;
Handle g_PickupExpireTimers;

// Timers
Handle g_CaptureTimer[MAXPLAYERS + 1];
Handle g_HudTimer_CaptureZoneCountdown;
Handle g_HudTimer_WinCountdown;

// ConVars
Handle g_FlagCapturesConvar;
ConVar g_UseBigPickupModels_ConVar, g_AllowSpyTeamLeader_ConVar;
bool g_UseBigPickupModels, g_AllowSpyTeamLeader;

#include "tf2c_pd_base_logic.sp"



public Plugin myinfo =
{
	name = "Player Destruction Gamemode for TF2C",
	author = "LordVGames",
	description = "Recreates player destruction gamemode functionality.",
	version = VERSION,
	url = "https://github.com/LordVGames/TF2C-Player-Destruction"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	char gameFolderName[24];
	GetGameFolderName(gameFolderName, sizeof(gameFolderName));
	int gameFolderName_CheckValue = strcmp(gameFolderName, "tf2classic", false);

	if (gameFolderName_CheckValue == 0)
	{
		if (late)
		{
			PrintToServer("%s Player destruction doesn't fully work when late loaded! Please change or restart the map for the plugin to take effect!");
		}
		return APLRes_Success;
	}
	else
	{
		SetFailState("This plugin was made for use with TF2Classic only. (Folder name: %s)", gameFolderName);
	}

	return APLRes_SilentFailure;
}



//        ----------------
//#region SOURCEMOD NATIVE
//        ----------------

public void OnMapStart()
{
	HookEntityOutput("item_teamflag", "OnPickUp", OnFlagPickup);
	HookEntityOutput("item_teamflag", "OnDrop", OnFlagDrop);
	HookEntityOutput("item_teamflag", "OnReturn", OnFlagReturn);
	HookEntityOutput("tf_logic_domination", "OnPointLimitAny", OnPointLimit);
	HookEntityOutput("tf_logic_domination", "OnPointLimitRed", OnPointLimit);
	HookEntityOutput("tf_logic_domination", "OnPointLimitBlue", OnPointLimit);
	PrecacheSound("ui/chime_rd_2base_pos.wav"); // Capture sound
	PrecacheSound("ui/chime_rd_2base_neg.wav"); // Victory countdown sound
	PrecacheModel(TRIGGER_MODEL);
	#if defined DEBUG_DISPENSER
		g_iLaserMaterial = PrecacheModel("materials/sprites/laserbeam.vmt");
		g_iHaloMaterial = PrecacheModel("materials/sprites/halo01.vmt");
	#endif
	ResetVars();
}

public void OnMapInit(const char[] mapName)
{
	char mapPrefix[4];
	SplitString(mapName, "_", mapPrefix, sizeof(mapPrefix));
	if (strcmp(mapPrefix, "pd", false) != 0)
	{
		SetFailState("This plugin only runs on Player Destruction maps.");
	}
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

	// Team filters don't exist in the tf2c plugin AFAIK, so we make them ourselves here.
	AddMultiTargetFilter("@red", FilterTeam_Red, "Red Team", false);
	AddMultiTargetFilter("@blue", FilterTeam_Blue, "Blue Team", false);

	CreateConVar("sm_pd_version", VERSION, "Version of the plugin.", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_AllowSpyTeamLeader_ConVar = CreateConVar("sm_pd_allow_spy_leader", "0", "Allows spy to become a team leader.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_UseBigPickupModels_ConVar = CreateConVar("sm_pd_use_big_pickups", "1", "Enables using a map-defined model for when a pickup has a higher value than 1.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	HookConVarChange(g_UseBigPickupModels_ConVar, OnConvarChanged);
	HookConVarChange(g_AllowSpyTeamLeader_ConVar, OnConvarChanged);
	AutoExecConfig(true, "tf2c_pd");
	UpdateConVars();
	g_FlagCapturesConvar = FindConVar("tf_flag_caps_per_round");

	HookEvent("player_death", OnEvent_PlayerDeath);
	HookEvent("player_spawn", OnEvent_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_team", OnEvent_PlayerJoinTeam, EventHookMode_Pre);
	HookEvent("teamplay_round_start", OnEvent_RoundStart, EventHookMode_Post);
	HookEvent("teamplay_flag_event", OnEvent_Flag, EventHookMode_Pre);

	AddNormalSoundHook(OnSoundPlayed);

	// I have the command name in the command description because when using a command like "sm cmds", the command names can get cut off if the command name is too long.
	RegConsoleCmd("sm_pd_status", Command_PDStatus, "\"sm_pd_status\". Shows data about yourself.");
	RegConsoleCmd("sm_pd_hud", Command_ReloadClientHud, "\"sm_pd_hud\". If any custom HUD elements are missing/broken for you, use this command.");
	RegConsoleCmd("sm_pd_reload_hud", Command_ReloadClientHud, "\"sm_pd_reload_hud\". If any custom HUD elements are missing/broken for you, use this command.");
	RegConsoleCmd("sm_pd_refresh_hud", Command_ReloadClientHud, "\"sm_pd_refresh_hud\". If any custom HUD elements are missing/broken for you, use this command.");
	RegAdminCmd("sm_pd_calculate_point_limit", Command_CalculatePointLimit, ADMFLAG_CHANGEMAP, "\"sm_pd_calculate_point_limit\". Manually re-calculates the point limit based on the playercount, and sets it accordingly.");
	RegAdminCmd("sm_pd_set_point_limit", Command_SetPointLimit, ADMFLAG_CHANGEMAP, "\"sm_pd_set_point_limit\". Manually set the point limit.");
	RegAdminCmd("sm_pd_give_points", Command_GivePDPoints, ADMFLAG_CHEATS, "\"sm_pd_give_points\". Gives you an amount of PD score/points.");
	RegAdminCmd("sm_pd_spawn_pickup", Command_SpawnPickup, ADMFLAG_CHEATS, "\"sm_pd_spawn_pickup\". Spawns a pickup where you are looking. Can specify a number to set the value of the pickup. If not specified, defaults to 1.");
	RegAdminCmd("sm_pd_create_pickup", Command_SpawnPickup, ADMFLAG_CHEATS, "\"sm_pd_create_pickup\". Spawns a pickup where you are looking. Can specify a number to set the value of the pickup. If not specified, defaults to 1.");
	RegAdminCmd("sm_pd_set_playercount", Command_SetPlayerCount, ADMFLAG_CHEATS, "\"sm_pd_set_playercount\" For debugging purposes.");

	g_CaptureZonesBlocking = CreateArray();
	g_PickupExpireTimers = CreateArray(2);

	PrintToServer("%s Player destruction for TF2Classic has started!", TAG);
}

public void OnPluginEnd()
{
	RemoveMultiTargetFilter("@red", FilterTeam_Red);
	RemoveMultiTargetFilter("@blue", FilterTeam_Blue);
}

/**
 * Borrowed from "left4dhooks.sp".
 */
public bool FilterTeam_Red(const char[] pattern, ArrayList clients)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == 2)
		{
			clients.Push(i);
		}
	}
	return true;
}

/**
 * Borrowed from "left4dhooks.sp".
 */
public bool FilterTeam_Blue(const char[] pattern, ArrayList clients)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == 3)
		{
			clients.Push(i);
		}
	}
	return true;
}

void OnConvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	UpdateConVars(convar);
}

void UpdateConVars(ConVar convar = null)
{
	if (convar == null)
	{
		switch (g_AllowSpyTeamLeader_ConVar.BoolValue)
		{
			case true:
			{
				g_AllowSpyTeamLeader = true;
			}
			case false:
			{
				g_AllowSpyTeamLeader = false;
			}
		}
		switch (g_UseBigPickupModels_ConVar.BoolValue)
		{
			case true:
			{
				g_UseBigPickupModels = true;
			}
			case false:
			{
				g_UseBigPickupModels = false;
			}
		}
	}
	else
	{
		if (convar == g_AllowSpyTeamLeader_ConVar)
		{
			g_AllowSpyTeamLeader = convar.BoolValue;
			FixSpyLeaders();
		}
		if (convar == g_UseBigPickupModels_ConVar)
		{
			g_UseBigPickupModels = convar.BoolValue;
		}
	}
}

public void OnEntityCreated(int spawnedEnt, const char[] classname)
{
	if (strcmp(classname, "func_capturezone") == 0)
	{
		SDKHook(spawnedEnt, SDKHook_StartTouch, OnStartTouchCaptureZone);
		SDKHook(spawnedEnt, SDKHook_EndTouch, OnEndTouchCaptureZone);
	}
	if (strcmp(classname, "func_respawnroom") == 0)
	{
		SDKHook(spawnedEnt, SDKHook_StartTouch, OnStartTouchRespawnRoom);
		SDKHook(spawnedEnt, SDKHook_EndTouch, OnEndTouchRespawnRoom);
	}
	if (strcmp(classname, "tf_logic_domination") == 0)
	{
		g_DomLogicEnt = spawnedEnt;
		RequestFrame(GetDomLogicValues);
	}
	if (strcmp(classname, "dispenser_touch_trigger") == 0)
	{
		RequestFrame(FixLeaderDispenserTrigger, spawnedEnt);
	}
}

public void OnClientDisconnect(int client)
{
	if (g_Logic_AllowMaxScoreUpdating)
	{
		CalculatePointLimit();
	}
	if (!g_IsInWaitingForPlayersTime && !g_IsInRespawnRoom[client])
	{
		if (g_CarriedFlagEnt[client] == -1)
		{
			CreatePickup(g_PickupCount[client] + 1, client);
			g_PickupCount[client] = 0;
		}
		else
		{
			// OnFlagDrop occurs after OnClientDisconnect
			// So we need to add the point now for when it does occur
			g_PickupCount[client] += 1;
		}
	}
	OnPickupCountUpdated(client, TF2_GetClientTeam(client));
}

public void OnClientDisconnect_Post()
{
	g_PlayerCountForCaptureDelay = GetAllTeamsClientCount();
}

//#endregion


//        --------
//#region COMMANDS
//        --------

Action Command_SetPlayerCount(int client, int argc)
{
	if (argc != 1)
	{
		ReplyToCommand(client, "%s Command usage: `sm_pd_set_playercount <number>`\n%s Set to 0 to use the current playercount.", TAG, TAG);
		return Plugin_Handled;
	}

	int cmdArg = GetCmdArgInt(1);
	if (cmdArg <= 0)
	{
		g_PlayerCountForCaptureDelay = GetAllTeamsClientCount();
	}
	else
	{
		g_PlayerCountForCaptureDelay = cmdArg;
	}
	return Plugin_Handled;
}

Action Command_CalculatePointLimit(int client, int argc)
{
	PrintToChatAll("%s Score limit has been automatically set to %i.", TAG, CalculatePointLimit());
	return Plugin_Handled;
}

Action Command_SetPointLimit(int client, int argc)
{
	if (argc != 1)
	{
		ReplyToCommand(client, "Command usage: sm_pd_set_score_limit <score>");
		return Plugin_Handled;
	}
	PrintToChatAll("%s Score limit has been set to %i.", TAG, SetPointLimit(GetCmdArgInt(1), true));
	return Plugin_Handled;
}

Action Command_GivePDPoints(int client, int argc)
{
	if (argc < 2)
	{
		ReplyToCommand(client, "%s Command usage: sm_give_pd_points <player name> <number>", TAG);
		return Plugin_Handled;
	}

	char target[65];
	GetCmdArg(1, target, sizeof(target));

	char targetName[MAX_TARGET_LENGTH];
	int targetList[MAXPLAYERS], targetCount;
	bool tn_is_ml;
	if ((targetCount = ProcessTargetString(
			target,
			client,
			targetList,
			MAXPLAYERS,
			COMMAND_FILTER_ALIVE,
			targetName,
			MAX_TARGET_LENGTH,
			tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, targetCount);
		return Plugin_Handled;
	}

	int pointsToGive = GetCmdArgInt(2);
	if (pointsToGive == 0)
	{
		pointsToGive = 1;
	}

	// By default it will give leader status to the client that has the lowest index
	// So we're picking a random client ourselves instead
	int randomFirstTarget = GetRandomInt(0, targetCount - 1);
	for (int i = -1; i < targetCount; i++)
	{
		if (i == randomFirstTarget)
		{
			continue;
		}
		if (i == -1)
		{
			i = randomFirstTarget;
		}
		int targetClient = targetList[i];
		bool isTargetInRespawnRoom;

		if (g_IsInRespawnRoom[targetClient])
		{
			isTargetInRespawnRoom = true;
			PrintToChat(targetClient, "%s You were not given points because you are in the respawn room.", TAG);
		}
		if (g_CarriedFlagEnt[targetClient] == -1 && !isTargetInRespawnRoom)
		{
			CreatePickup(1, targetClient);
			if (pointsToGive - 1 > 0)
			{
				g_PickupCount[targetClient] += pointsToGive - 1;
			}
		}
		else
		{
			if (pointsToGive > 0 && !isTargetInRespawnRoom)
			{
				g_PickupCount[targetClient] += pointsToGive;
			}
		}
		if (!isTargetInRespawnRoom)
		{
			OnPickupCountUpdated(targetClient, TF2_GetClientTeam(targetClient));
			PrintToChat(client, "%s Gave %i points to %N.", TAG, pointsToGive, targetClient);
		}
		else
		{
			PrintToChat(client, "%s Could not give %i points to %N because they are in the respawn room.", TAG, pointsToGive, targetClient);
		}

		// Set i back to -1 to not mess up the counting
		if (i == randomFirstTarget)
		{
			i = -1;
		}
	}


	return Plugin_Handled;
}

Action Command_PDStatus(int client, int argc)
{
	PrintToChat(client, "%s You have %i pickups collected.\n", TAG, g_PickupCount[client]);
	PrintToChat(client, "%s You are %s", TAG, IsClientLeadingAnyTeam(client) ? "a team leader.\n" : "NOT a team leader.\n");
	PrintToChat(client, "%s You %s", TAG, g_CarriedFlagEnt[client] == -1 ? "are carrying a flag.\n" : "are NOT carrying a flag.\n");
	DebugPrint(Debug_CaptureZone, "%s The player count for capture delay offsets is %i", TAG, g_PlayerCountForCaptureDelay);
	return Plugin_Handled;
}

Action Command_ReloadClientHud(int client, int argc)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	ClearHudText(client, Channel_RedPickups);
	ClearHudText(client, Channel_BluePickups);
	if (!g_Logic_OnPointLimitOccurred)
	{
		CreateTimer(0.25, Timer_ShowHudText_TeamPickupCounts, client);
	}
	if (g_PickupCount[client] > 0)
	{
		ClearHudText(client, Channel_PlayerPickups);
		CreateTimer(0.25, Timer_ShowHudText_ClientPickupCount, client);
	}
	if (IsClientLeadingAnyTeam(client))
	{
		ClearHudText(client, Channel_TeamLeader);
		CreateTimer(0.25, Timer_ShowHudText_TeamLeaderStatus, client);
	}
	ClearHudText(client, Channel_Countdown);
	PrintToChat(client, "%s HUD elements should be fixed.", TAG);
	return Plugin_Handled;
}

Action Command_SpawnPickup(int client, int argc)
{
	if (g_IsInWaitingForPlayersTime)
	{
		ReplyToCommand(client, "%s Command cannot be used during \"Waiting for players\"!", TAG);
	}
	int pickupValue = GetCmdArgInt(1);
	if (pickupValue <= 0) pickupValue = 1;

	float viewPos[3];
	GetClientViewLocation(client, viewPos);
	viewPos[2] += 25.0; // Make it float
	EmitSoundToClient(client, g_PickupSound_Drop, CreatePickup(pickupValue, .spawnPos=viewPos), SNDCHAN_ITEM);
	return Plugin_Handled;
}

//#endregion


//        ------
//#region EVENTS
//  	  ------

void OnEvent_PlayerJoinTeam(Event event, const char[] eventName, bool silent)
{
	RequestFrame(OnEvent_PlayerJoinTeam_RF);
}

void OnEvent_PlayerJoinTeam_RF()
{
	if (g_Logic_AllowMaxScoreUpdating)
	{
		CalculatePointLimit();
	}
	g_PlayerCountForCaptureDelay = GetAllTeamsClientCount();
}

void OnEvent_PlayerDeath(Event event, const char[] eventName, bool silent)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	int killer = GetClientOfUserId(GetEventInt(event, "attacker"));

	if (IsValidEntity(g_WasCarryingFlag[client]))
	{
		int newPickupValue = g_PrevPickupCount[client] + g_Logic_PlayerDeathPickupValue;
		DispatchKeyValueInt(g_WasCarryingFlag[client], "PointValue", newPickupValue);
		if (CanUseBigPickups() && newPickupValue > 1)
		{
			SetEntityModel(g_WasCarryingFlag[client], g_PickupModel_Big);
		}
		DebugPrint(Debug_Pickups, "Client \"%N\" was carrying a flag upon death, not manually dropping a pickup...", client);
		return;
	}
	else if (!g_IsInWaitingForPlayersTime && !g_IsInRespawnRoom[client])
	{
		// g_PickupCount should be 0, but if it's somehow not, it still works fine
		CreatePickup(g_PickupCount[client] + g_Logic_PlayerDeathPickupValue, client, killer);
		g_PickupCount[client] = 0;
		ClearHudText(client, Channel_PlayerPickups);
	}
}

void OnEvent_PlayerSpawn(Event event, const char[] eventName, bool silent)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (GetEventInt(event, "class") > 0)
	{
		CreateTimer(0.1, Timer_ShowHudText_TeamPickupCounts, client);
	}
}

void OnEvent_RoundStart(Event event, const char[] eventName, bool silent)
{
	ResetVars();
}

//#endregion


//        --------------
//#region ENTITY OUTPUTS
//  	  --------------


void OnFlagPickup(const char[] outputName, int flagEnt, int client, float delay)
{
	DebugPrint(Debug_Pickups, "OnFlagPickup");
	SetEdictFlags(flagEnt, GetEdictFlags(flagEnt) | FL_EDICT_DONTSEND);
	AcceptEntityInput(flagEnt, "Disable", client);
	g_CarriedFlagEnt[client] = flagEnt;
	GivePlayerPickupValue(client, flagEnt);
	OnPickupCountUpdated(client);

	TFTeam clientTeam = TF2_GetClientTeam(client);
	TFTeam droppedPickupTeam = view_as<TFTeam>(GetCustomKeyValueInt(flagEnt, "DroppedTeam"));
	if (clientTeam != droppedPickupTeam)
	{
		switch (droppedPickupTeam)
		{
			case TFTeam_Red:
			{
				if (!g_Logic_HasRedFirstFlagStolen)
				{
					FireCustomOutput("OnRedFirstFlagStolen", g_DomLogicEnt, client);
					g_Logic_HasRedFirstFlagStolen = true;
				}
				FireCustomOutput("OnRedFlagStolen", g_DomLogicEnt, client);
			}
			case TFTeam_Blue:
			{
				if (!g_Logic_HasBlueFirstFlagStolen)
				{
					FireCustomOutput("OnBlueFirstFlagStolen", g_DomLogicEnt, client);
					g_Logic_HasBlueFirstFlagStolen = true;
				}
				FireCustomOutput("OnBlueFlagStolen", g_DomLogicEnt, client);
			}
		}
	}

	int pickupExpireTimerIndex = FindValueInArray(g_PickupExpireTimers, flagEnt);
	if (pickupExpireTimerIndex == -1)
	{
		// Either the flag was dropped naturally or something messed up
		// Can't really check for either one specifically
		return;
	}
	Handle pickupExpireTimer = GetArrayCell(g_PickupExpireTimers, pickupExpireTimerIndex, 1);
	delete pickupExpireTimer;
	RemoveFromArray(g_PickupExpireTimers, pickupExpireTimerIndex);
}

void OnFlagDrop(const char[] outputName, int flagEnt, int client, float delay)
{
	DebugPrint(Debug_Pickups, "OnFlagDrop");
	SetEdictFlags(flagEnt, GetEdictFlags(flagEnt) | FL_EDICT_ALWAYS);
	DispatchKeyValueInt(flagEnt, "PointValue", g_PickupCount[client]);
	DispatchKeyValueInt(flagEnt, "DroppedTeam", view_as<int>(TF2_GetClientTeam(client)));
	TFTeam activatorTeam;
	if (IsValidClientInGame(client))
	{
		activatorTeam = TF2_GetClientTeam(client);
	}

	// OnFlagDrop just so happens to occur before "OnEvent_PlayerDeath" is called
	// So we need these values for that function later
	g_WasCarryingFlag[client] = flagEnt;
	g_PrevPickupCount[client] = g_PickupCount[client];
	CreateTimer(0.25, Timer_ClearOldPlayerData, client);

	g_CarriedFlagEnt[client] = -1;
	g_PickupCount[client] = 0;
	OnPickupCountUpdated(client, activatorTeam);
	DebugPrint(Debug_Pickups, "Pickup Ent Index: %i", flagEnt);
}

void OnFlagReturn(const char[] outputName, int flagEnt, int client, float delay)
{
	// The flag return event in "OnEvent_Flag" doesn't work
	// So we must cover it here
	BlockAnnouncerVO();
}

public Action OnPointLimit(const char[] outputName, int caller, int activator, float delay)
{
	// TF2C has a bug where the "OnPointLimit" output is spammed until a team wins.
	// So we stop it from sending the output(s) past the first time.
	if (g_Logic_OnPointLimitOccurred)
	{
		return Plugin_Stop;
	}

	delete g_HudTimer_CaptureZoneCountdown;
	TFTeam winningTeam;
	switch (outputName[12])
	{
		case 'R':
		{
			winningTeam = TFTeam_Red;
		}
		case 'B':
		{
			winningTeam = TFTeam_Blue;
		}
	}
	if (winningTeam == TFTeam_Unassigned)
	{
		return Plugin_Continue;
	}
	else
	{
		g_Logic_OnPointLimitOccurred = true;
	}
	g_HudTimerNum_Finale = GetCustomKeyValueInt(g_DomLogicEnt, "finale_length");
	g_HudTimer_WinCountdown = CreateTimer(1.0, Timer_ShowHudText_TeamWinCountdown, winningTeam, TIMER_REPEAT);
	TriggerTimer(g_HudTimer_WinCountdown);
	g_Logic_OnPointLimitOccurred = true;
	return Plugin_Continue;
}

//#endregion


//        -----------
//#region CAPTUREZONE
//        -----------

bool ShouldBlockCapture(int captureZone)
{
	if (CustomKeyValueExists(captureZone, "shouldblock"))
	{
		if (!GetCustomKeyValueBool(captureZone, "shouldblock"))
		{
			return false;
		}
	}

	bool hasRedPlayer, hasBluePlayer;
	for (int c = 1; c <= MaxClients; c++)
	{
		for (int z = 0; z < 2; z++)
		{
			if (g_PlayerInCaptureZones[c][z] == captureZone)
			{
				switch (TF2_GetClientTeam(c))
				{
					case TFTeam_Red:
					{
						hasRedPlayer = true;
					}
					case TFTeam_Blue:
					{
						hasBluePlayer = true;
					}
				}
				break;
			}
		}
	}

	if (hasBluePlayer &&  hasRedPlayer)
	{
		return true;
	}
	return false;
}

public void OnStartTouchCaptureZone(int captureZone, int client)
{
	if (!IsValidClientInGame(client))
	{
		return;
	}
	DebugPrint(Debug_CaptureZone, "OnStartTouchCaptureZone %i in %i", client, captureZone);

	if (g_PlayerInCaptureZones[client][1] != 0)
	{
		LogError("%s Couldn't add 3rd capture zone index to player \"%N\"'s list of capturezones occupied by them!", TAG, client);
	}
	else
	{
		for (int z = 0; z < 2; z++)
		{
			if (g_PlayerInCaptureZones[client][z] == 0)
			{
				g_PlayerInCaptureZones[client][z] = captureZone;
				DebugPrint(Debug_CaptureZone, "Capturezone index %i is at pos %i in client %i (%N)'s array.", captureZone, z, client, client);
				break;
			}
		}
	}

	if (ShouldBlockCapture(captureZone))
	{
		DebugPrint(Debug_CaptureZone, "Red and Blue players in capture zone!\nKilling capture timers if they exist!");
		for (int c = 1; c <= MaxClients; c++)
		{
			for (int z = 0; z < 2; z++)
			{
				if (g_PlayerInCaptureZones[c][z] == captureZone)
				{
					delete g_CaptureTimer[c];
					break;
				}
			}
		}

		if (FindValueInArray(g_CaptureZonesBlocking, captureZone) == -1)
		{
			PushArrayCell(g_CaptureZonesBlocking, captureZone);
		}
		return;
	}
	else
	{	
		int captureZoneTeam = GetEntProp(captureZone, Prop_Data, "m_iTeamNum");
		if (captureZoneTeam != GetClientTeam(client) && captureZoneTeam != 0)
		{
			DebugPrint(Debug_CaptureZone, "Client is not on the correct team for this capture zone (%i), not creating capture timer...", captureZoneTeam);
			return;
		}


		if (g_CaptureTimer[client] == null)
		{
			DebugPrint(Debug_CaptureZone, "Capture timer is NULL, creating timer...");
			DataPack data;
			g_CaptureTimer[client] = CreateDataTimer(GetCaptureZoneDelay(captureZone), Timer_PDCapture, data, TIMER_REPEAT);
			data.WriteCell(captureZone);
			data.WriteCell(client, true);
			DebugPrint(Debug_CaptureZone, "Doing initial capture...");
			TriggerTimer(g_CaptureTimer[client], true);
		}
	}
}

public void OnEndTouchCaptureZone(int captureZone, int client)
{
	if (!IsValidClientInGame(client))
	{
		return;
	}
	DebugPrint(Debug_CaptureZone, "OnEndTouchCaptureZone %i in %i", client, captureZone);

	for (int z = 1; z > -1; z--)
	{
		if (g_PlayerInCaptureZones[client][z] != 0)
		{
			g_PlayerInCaptureZones[client][z] = 0;
			DebugPrint(Debug_CaptureZone, "Capturezone index %i has been removed from pos %i in client %i (%N)'s array.", captureZone, z, client, client);
			break;
		}
	}
	if(!ShouldBlockCapture(captureZone))
	{
		int captureZonesArrayIndex = FindValueInArray(g_CaptureZonesBlocking, captureZone);
		if (captureZonesArrayIndex != -1)
		{
			RemoveFromArray(g_CaptureZonesBlocking, captureZonesArrayIndex);
		}

		int captureZoneTeam = GetEntProp(captureZone, Prop_Data, "m_iTeamNum");
		for (int c = 1; c <= MaxClients; c++)
		{
			if (!IsValidClientInGame(c)) continue;
			for (int z = 0; z < 2; z++)
			{
				if (g_PlayerInCaptureZones[c][z] == captureZone && captureZoneTeam == GetClientTeam(c) || captureZoneTeam == 0)
				{
					DebugPrint(Debug_CaptureZone, "Capture blockage is over, re-creating capture timer for %N...", c);
					DataPack data;
					g_CaptureTimer[c] = CreateDataTimer(GetCaptureZoneDelay(captureZone), Timer_PDCapture, data, TIMER_REPEAT);
					data.WriteCell(captureZone);
					data.WriteCell(c, true);
					break;
				}
			}
		}
	}
}

//#endregion


//        ----------
//#region PD PICKUPS
//        ----------

public Action OnEvent_Flag(Event event, const char[] eventName, bool silent)
{
	char eventType[SMALL_INT_CHAR];
	GetEventString(event, "eventtype", eventType, sizeof(eventType));
	int eventInt = StringToInt(eventType);
	int client = GetEventInt(event, "player");
	
	switch (eventInt)
	{
		case TF_FLAGEVENT_PICKEDUP, TF_FLAGEVENT_RETURNED:
		{
			RequestFrame(BlockAnnouncerVO);
		}
		case TF_FLAGEVENT_CAPTURED:
		{
			// But for some reason it doesn't always cancel the lines for this event
			// So we delay it a little bit more
			CreateTimer(0.1, Timer_BlockAnnouncerVO);
		}
		case TF_FLAGEVENT_DROPPED:
		{
			RequestFrame(BlockAnnouncerVO);
			if (g_CarriedFlagEnt[client] != -1)
			{
				AcceptEntityInput(g_CarriedFlagEnt[client], "Enable", client);
				// The flag doesn't drop from the initial drop command since we enabled it just now
				// So we do it ourselves
				AcceptEntityInput(g_CarriedFlagEnt[client], "ForceDrop", client);
			}
		}
	}
	return Plugin_Handled; // We don't want CTF notifs anywhere
}

/**
 * Creates a PD pickup.
 *
 * @param pickupValue		The amount of points given to whoever picks it up.
 * @param client			The client's index. Optional
 * @param killer           	The killer's index. Optional.
 * @param spawnPos			The spawn position to use if the client is invalid or not specified. Optional.
 * @return 					The created pickup's index.
 */
int CreatePickup(int pickupValue, int client = -1, int killer = -1, float[] spawnPos = {0.0,0.0,0.0})
{
	DebugPrint(Debug_Pickups, "CreatePickup");
	TFTeam clientTeam;
	int pickupExpireTime = GetCustomKeyValueInt(g_DomLogicEnt, "flag_reset_delay");

	// We want to spawn the pickup a little above the ground if dropped by a client
	// Otherwise we spawn it at the provided coords
	float clientPos[3];
	if (IsValidClientInGame(client))
	{
		clientTeam = TF2_GetClientTeam(client);
		GetClientAbsOrigin(client, clientPos);
		float distToGround = GetEntityDistanceToGround(client);
		DebugPrint(Debug_Pickups, "%N's pos: %f %f %f", client, clientPos[0], clientPos[1], clientPos[2]);
		DebugPrint(Debug_Pickups, "Distance to ground from %N: %f", client, distToGround);
		if (distToGround != 10.0)
		{
			// Make it float just above the ground
			clientPos[2] = ((clientPos[2] - distToGround) + 10.0);
		}
		DebugPrint(Debug_Pickups, "Recalculated spawn height pos: %f", clientPos[2]);
	}
	else
	{
		clientPos[0] = spawnPos[0];
		clientPos[1] = spawnPos[1];
		clientPos[2] = spawnPos[2];
	}
	
	int pickupEnt = CreateEntityByName("item_teamflag");
	DispatchKeyValue(pickupEnt, "classname", "item_teamflag");
	DispatchKeyValueInt(pickupEnt, "ReturnTime", pickupExpireTime);
	DispatchKeyValueInt(pickupEnt, "NeutralType", 0);
	DispatchKeyValueInt(pickupEnt, "ScoringType", 0);
	if (CanUseBigPickups() && pickupValue > 1)
	{
		DispatchKeyValue(pickupEnt, "flag_model", g_PickupModel_Big);
		DebugPrint(Debug_Pickups, "Pickup Model: %s", g_PickupModel_Big);
	}
	else
	{
		DispatchKeyValue(pickupEnt, "flag_model", g_PickupModel);
		DebugPrint(Debug_Pickups, "Pickup Model: %s", g_PickupModel);
	}
	DispatchKeyValue(pickupEnt, "flag_icon", "");
	DispatchKeyValue(pickupEnt, "flag_paper", "");
	DispatchKeyValue(pickupEnt, "flag_trail", "");
	DispatchKeyValueInt(pickupEnt, "trail_effect", 0);
	DispatchKeyValueInt(pickupEnt, "sequence", 1);
	DispatchKeyValueInt(pickupEnt, "PointValue", pickupValue);
	DispatchKeyValueInt(pickupEnt, "DroppedTeam", view_as<int>(clientTeam));
	DispatchSpawn(pickupEnt);
	ActivateEntity(pickupEnt);
	TeleportEntity(pickupEnt, clientPos, NULL_VECTOR, NULL_VECTOR);
	SetVariantString("1");
	AcceptEntityInput(pickupEnt, "ForceGlowDisabled");
	SDKHook(pickupEnt, SDKHook_StartTouch, OnStartTouchPDPickup);

	int pickupExpireTimerIndex = PushArrayCell(g_PickupExpireTimers, pickupEnt);
	SetArrayCell(g_PickupExpireTimers, pickupExpireTimerIndex, CreateTimer(float(pickupExpireTime), Timer_KillOldPickup, pickupEnt), 1);

	if (IsValidClientInGame(client))
	{
		EmitSoundToClient(client, g_PickupSound_Drop, pickupEnt);
	}
	if (IsValidClientInGame(killer))
	{
		EmitSoundToClient(killer, g_PickupSound_Drop, pickupEnt);
	}

	DebugPrint(Debug_Pickups, "Pickup Ent Index: %i", pickupEnt);
	DebugPrint(Debug_Pickups, "Pickup Ent Value: %i", pickupValue);
	return pickupEnt;
}

Action Timer_KillOldPickup(Handle timer, int pickupEnt)
{
	if (!IsValidEntity(pickupEnt)) return Plugin_Stop;

	// We don't want to delete a flag that someone has picked up already
	bool isPickedUp;
	for (int c = 1; c <= MaxClients; c++)
	{
		if (pickupEnt == g_CarriedFlagEnt[c])
		{
			isPickedUp = true;
			break;
		}
	}
	if (!isPickedUp)
	{
		RemoveEntity(pickupEnt);
	}
	return Plugin_Stop;
}

Action Timer_ClearOldPlayerData (Handle timer, int client)
{
	g_WasCarryingFlag[client] = -1;
	g_PrevPickupCount[client] = 0;
	return Plugin_Stop;
}

public void OnStartTouchPDPickup(int pickupEnt, int client)
{
	if (!IsValidClientInGame(client) || g_CarriedFlagEnt[client] == -1)
	{
		return;
	}
	// Make sure the flag being touched isn't being carried by someone else
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!IsValidClientInGame(c)) continue;

		if (g_CarriedFlagEnt[c] == pickupEnt)
		{
			return;
		}
	}
	DebugPrint(Debug_Pickups, "OnStartTouchPDPickup %i by %i", pickupEnt, client);
	
	GivePlayerPickupValue(client, pickupEnt);
	RemoveEntity(pickupEnt);
	OnPickupCountUpdated(client);

	int pickupExpireTimerIndex = FindValueInArray(g_PickupExpireTimers, pickupEnt);
	if (pickupExpireTimerIndex == -1)
	{
		// Either the flag was dropped naturally or something messed up
		return;
	}
	Handle pickupExpireTimer = GetArrayCell(g_PickupExpireTimers, pickupExpireTimerIndex, 1);
	delete pickupExpireTimer;
	RemoveFromArray(g_PickupExpireTimers, pickupExpireTimerIndex);
}

/**
 * Calls a bunch of functions that need to occur every time someone's pickup count updates.
 *
 * @param client        The client whose pickup count has updated.
 * @param clientTeam    The team of the client. Optional.
 */
void OnPickupCountUpdated(int client, TFTeam clientTeam = TFTeam_Unassigned)
{
	if (!IsValidClient(client))
	{
		return;
	}
	DebugPrint(Debug_Pickups, "OnPickupCountUpdated %i", client);
	
	TryUpdateTeamLeader(client, clientTeam);
	ShowHudText_TeamPickupCounts(.team=clientTeam);

	if (!IsClientInGame(client)) return;
	if (g_PickupCount[client] > 0)
	{
		CreateTimer(0.1, Timer_ShowHudText_ClientPickupCount, client);
	}
	else
	{
		ClearHudText(client, Channel_PlayerPickups);
	}
}

/**
 * Gives a player the score from a pickup.
 *
 * @param client         Client index.
 * @param pickupEnt     The entity index of the pickup.
 */
void GivePlayerPickupValue(int client, int pickupEnt)
{
	if (!IsValidClientInGame(client))
	{
		return;
	}

	DebugPrint(Debug_Pickups, "Pickup Index: %i", pickupEnt);
	int pickupValue = GetCustomKeyValueInt(pickupEnt, "PointValue");
	DebugPrint(Debug_Pickups, "Pickup Value: %i", pickupValue);
	g_PickupCount[client] += pickupValue;
}

Action Timer_PDCapture(Handle timer, DataPack data)
{
	DebugPrint(Debug_CaptureZone, "Timer_PDCapture");
	int client, captureZone;
	data.Reset();
	captureZone = data.ReadCell();
	client = data.ReadCell();

	bool shouldBlockCapture, isPlayerInCaptureZone;
	if (FindValueInArray(g_CaptureZonesBlocking, captureZone) != -1)
	{
		shouldBlockCapture = true;
	}
	for (int z = 0; z < 2; z++)
	{
		if (g_PlayerInCaptureZones[client][z] == captureZone)
		{
			isPlayerInCaptureZone = true;
			break;
		}
	}

	if (shouldBlockCapture || !isPlayerInCaptureZone)
	{
		if (shouldBlockCapture)
		{
			DebugPrint(Debug_CaptureZone, "Capture in zone %i is blocked for %N.", captureZone, client);
		}
		if (!isPlayerInCaptureZone && IsValidClientInGame(client))
		{
			DebugPrint(Debug_CaptureZone, "%N is not in capture zone %i anymore.", client, captureZone);
		}
		g_CaptureTimer[client] = null;
		return Plugin_Stop;
	}
	else
	{
		DebugPrint(Debug_CaptureZone, "%N is still in capture zone %i.", client, captureZone);
		if (g_PickupCount[client] > 0)
		{
			DoPDPickupCapture(client, captureZone);
		}
	}
	return Plugin_Continue;
}

/**
 * "Captures" a pickup, a.k.a removes 1 from a client's pickup count and fires the correct output.
 *
 * @param client     	Client who will capture a pickup.
 * @param captureZone   The capture zone the client is currently in.
 */
void DoPDPickupCapture(int client, int captureZone)
{
	if (g_PickupCount[client] <= 0)
	{
		return;
	}
	DebugPrint(Debug_CaptureZone, "DoPDPickupCapture %N in cz %i", client, captureZone);

	g_PickupCount[client] -= 1;
	if (g_PickupCount[client] == 0)
	{
		AcceptEntityInput(g_CarriedFlagEnt[client], "Enable", client); // This makes the flag entity itself get captured in the captureZone
		g_CarriedFlagEnt[client] = -1;
	}

	EmitSoundToAll("ui/chime_rd_2base_pos.wav", client, SNDCHAN_ITEM);
	OnPickupCountUpdated(client);
	switch (TF2_GetClientTeam(client))
	{
		case TFTeam_Red:
		{
			FireCustomOutput("OnCapTeam1_PD", captureZone, client);
		}
		case TFTeam_Blue:
		{
			FireCustomOutput("OnCapTeam2_PD", captureZone, client);
		}
	}
}
//#endregion


//        -----------
//#region TEAM LEADER
//        -----------

/**
 * Tries to update who the team leader is, based on if a client has gone above or below a team's top pickup count.
 *
 * @param client     	Client who triggered the update.
 * @param clientTeam    The team of the client. If not specified, the team will be gotten from the provided client index.
 */
void TryUpdateTeamLeader(int client, TFTeam clientTeam = TFTeam_Unassigned)
{
	if (!IsValidClient(client))
	{
		return;
	}
	DebugPrint(Debug_Leader, "TryUpdateTeamLeader %N", client);
	DebugPrint(Debug_Leader, "%N's pickup count: %i", client, g_PickupCount[client]);	
	
	if (clientTeam == TFTeam_Unassigned)
	{
		clientTeam = TF2_GetClientTeam(client);
	}
	switch (clientTeam)
	{
		case TFTeam_Red:
		{
			if (g_PickupCount[client] > g_TopPickupCount_Red)
			{
				DebugPrint(Debug_Leader, "%N has surpassed red's top pickup count of %i!", client, g_TopPickupCount_Red);
				if (!g_AllowSpyTeamLeader && TF2_GetPlayerClass(client) == TFClass_Spy)
				{
					DebugPrint(Debug_Leader, "But they are a spy, so they will be ignored.");
					return;
				}
				
				if (g_TopPickupCount_Red == 0)
				{
					FireCustomOutput("OnRedHasPoints", g_DomLogicEnt, client);
				}
				g_TopPickupCount_Red = g_PickupCount[client];
				if (client == g_TeamLeader_Red)
				{
					// No need to re-setup the client if they're already the leader
					return;
				}
				else if (IsValidClientInGame(g_TeamLeader_Red))
				{
					UnsetupLeader(g_TeamLeader_Red);
				}
				SetupLeader(client);
			}
			else if (g_PickupCount[client] < g_TopPickupCount_Red)
			{
				DebugPrint(Debug_Leader, "%N is below red's top pickup count of %i!", client, g_TopPickupCount_Red);
				g_TopPickupCount_Red = GetTeamPickupCount_Top(clientTeam);

				if (g_TopPickupCount_Red <= 0)
				{
					if (client == g_TeamLeader_Red)
					{
						UnsetupLeader(client);
					}
					FireCustomOutput("OnRedHitZeroPoints", g_DomLogicEnt, client);
					return;
				}
				if (client != g_TeamLeader_Red)
				{
					return;
				}

				int newLeader = GetTeamLeader(clientTeam);
				if (newLeader == client)
				{
					// No need to re-setup the client if they're already the leader
					return;
				}
				UnsetupLeader(client);
				SetupLeader(newLeader);
			}
		}
		case TFTeam_Blue:
		{
			if (g_PickupCount[client] > g_TopPickupCount_Blue)
			{
				DebugPrint(Debug_Leader, "%N has surpassed blue's top pickup count of %i!", client, g_TopPickupCount_Blue);
				if (!g_AllowSpyTeamLeader && TF2_GetPlayerClass(client) == TFClass_Spy)
				{
					DebugPrint(Debug_Leader, "But they are a spy, so they will be ignored.");
					return;
				}
				
				if (g_TopPickupCount_Blue == 0)
				{
					FireCustomOutput("OnBlueHasPoints", g_DomLogicEnt, client);
				}
				g_TopPickupCount_Blue = g_PickupCount[client];
				if (client == g_TeamLeader_Blue)
				{
					return;
				}
				else if (IsValidClientInGame(g_TeamLeader_Blue))
				{
					UnsetupLeader(g_TeamLeader_Blue);
				}
				SetupLeader(client);
			}
			else if (g_PickupCount[client] < g_TopPickupCount_Blue)
			{
				DebugPrint(Debug_Leader, "%N is below blue's top pickup count of %i!", client, g_TopPickupCount_Blue);
				g_TopPickupCount_Blue = GetTeamPickupCount_Top(clientTeam);

				if (g_TopPickupCount_Blue <= 0)
				{
					if (client == g_TeamLeader_Blue)
					{
						UnsetupLeader(client);
					}
					FireCustomOutput("OnBlueHitZeroPoints", g_DomLogicEnt, client);
					return;
				}
				if (client != g_TeamLeader_Blue)
				{
					return;
				}

				int newLeader = GetTeamLeader(clientTeam);
				if (newLeader == client)
				{
					return;
				}
				UnsetupLeader(client);
				SetupLeader(newLeader);
			}
		}
	}
}

/**
 * Gets a single team leader client index, or a random client index if there are multiple possible leader clients.
 *
 * @param team     Team to get a team leader index from.
 * @return         Leader client index.
 */
int GetTeamLeader(TFTeam team)
{
	DebugPrint(Debug_Leader, "GetTeamLeader (Team %i)", view_as<int>(team));
	int teamLeader = -1;
	int topPickupCount = GetTeamPickupCount_Top(team);
	int topPickupCarrierCount = GetTeamPickupCarriers_Count(team, topPickupCount);

	if (topPickupCarrierCount > 1)
	{
		int pickupCountCarrierArray[MAXPLAYERS + 1];
		int chosenOne = (GetRandomInt(0, topPickupCarrierCount - 1));

		GetTeamPickupCarriers_Array(team, topPickupCount, pickupCountCarrierArray);
		teamLeader = pickupCountCarrierArray[chosenOne];
		DebugPrint(Debug_Leader, "Random leader from list index %i is %i (%N)", chosenOne, teamLeader, teamLeader);
	}
	else
	{
		teamLeader = GetTeamPickupCarrier_Client(team, topPickupCount);
		DebugPrint(Debug_Leader, "Only 1 leader was found! (%N)", teamLeader);
	}
	return teamLeader;
}

/**
 * Gets the amount of clients who have collected the provided pickup count.
 *
 * @param team     			Team to filter by.
 * @param pickupCount		The pickup count to filter by.
 * @return          		Number of clients carrying the provided pickup count.
 */
int GetTeamPickupCarriers_Count(TFTeam team, int pickupCount)
{
	int pickupCarrierCount;
	for (int c = 1; c <= MaxClients; c++)
	{
		if (
			IsValidClientInGame(c) &&
			IsPlayerAlive(c) &&
			TF2_GetClientTeam(c) == team &&
			g_PickupCount[c] == pickupCount
		)
		{
			if (!g_AllowSpyTeamLeader && TF2_GetPlayerClass(c) == TFClass_Spy)
			{
				DebugPrint(Debug_Leader, "Client %N is a spy, ignoring...");
				continue;
			}
			DebugPrint(Debug_Leader, "Client %N has the pickup count of %i!", c, pickupCount);
			pickupCarrierCount += 1;
		}
	}
	return pickupCarrierCount;
}

/**
 * Gets the first alive client carrying the provided pickup count.
 *
 * @param team     			Team to filter by.
 * @param pickupCount		The number of score to filter by.
 * @return          		The first client index carrying the specified pickup count, or -1 if no client was found.
 */
int GetTeamPickupCarrier_Client(TFTeam team, int pickupCount)
{
	for (int c = 1; c <= MaxClients; c++)
	{
		if (
			IsValidClientInGame(c) &&
			IsPlayerAlive(c) &&
			TF2_GetClientTeam(c) == team &&
			g_PickupCount[c] == pickupCount
		)
		{
			if (!g_AllowSpyTeamLeader && TF2_GetPlayerClass(c) == TFClass_Spy)
			{
				continue;
			}
			else
			{
				return c;
			}
		}
	}
	return -1;
}

/**
 * Gets a list of clients with the provided pickup count, and fills in 0's in a provided array with client indexes.
 * Only fills in slots up to MaxClients.
 *
 * @param tTeam     						Team to filter by.
 * @param pickupCount						The number of pickups to filter by.
 * @param pickupCarrierArray         		An int array of all clients carrying the provided pickup count.
 */
void GetTeamPickupCarriers_Array(TFTeam tTeam, int pickupCount, int[] pickupCarrierArray)
{
	DebugPrint(Debug_Leader, "GetTeamPickupCarriers_Array");
	for (int c = 1; c <= MaxClients; c++)
	{
		if (
			IsValidClientInGame(c) &&
			IsPlayerAlive(c) &&
			TF2_GetClientTeam(c) == tTeam &&
			g_PickupCount[c] == pickupCount
		)
		{
			if (!g_AllowSpyTeamLeader && TF2_GetPlayerClass(c) == TFClass_Spy)
			{
				DebugPrint(Debug_Leader, "Client %N is a spy, not adding to the list...");
				continue;
			}
			DebugPrint(Debug_Leader, "Client %i has the pickup count of %i!", c, pickupCount);
			for (int a = 1; a <= MaxClients; a++)
			{
				if (pickupCarrierArray[a] == 0)
				{
					pickupCarrierArray[a] = c;
					break;
				}
			}
		}
	}
}

/**
 * Gets the pickup counts of everyone on a team and adds it up.
 *
 * @param team		The TFTeam to get the point count from.
 * @return			The number of points the team has in total.
 */
int GetTeamPickupCount_Total(TFTeam team)
{
	int totalPickups;
	for (int c = 1; c <= MaxClients; c++)
	{
		if (IsValidClientInGame(c) && TF2_GetClientTeam(c) == team)
		{
			totalPickups += g_PickupCount[c];
		}
	}
	return totalPickups;
}

/**
 * Gets the highest amount of pickups held by someone on a team.
 *
 * @param team		Team to search in.
 * @return    		The highest amount of pickups someone has on team.
 */
int GetTeamPickupCount_Top(TFTeam team)
{
	int topPickupCount;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (
			IsValidClientInGame(i) &&
			IsPlayerAlive(i) &&
			TF2_GetClientTeam(i) == team &&
			g_PickupCount[i] > topPickupCount
		)
		{
			if (!g_AllowSpyTeamLeader && TF2_GetPlayerClass(i) == TFClass_Spy)
			{
				continue;
			}
			topPickupCount = g_PickupCount[i];
		}
	}
	return topPickupCount;
}

/**
 * Creates the team leader dispenser, glow, and hud text for a specified client.
 * ALso sets the client as a leader.
 *
 * @param client     Client to make team leader.
 */
void SetupLeader(int leader)
{
	DebugPrint(Debug_Leader, "SetupLeader %N", leader);
	switch (TF2_GetClientTeam(leader))
	{
		case TFTeam_Red:
		{
			g_TeamLeader_Red = leader;
			g_TeamLeader_DispenserEnt_Red = CreateTeamLeaderDispenser(leader);
			g_TeamLeader_GlowEnt_Red = CreateTeamLeaderGlow(leader);
		}
		case TFTeam_Blue:
		{
			g_TeamLeader_Blue = leader;
			g_TeamLeader_GlowEnt_Blue = CreateTeamLeaderGlow(leader);
			g_TeamLeader_DispenserEnt_Blue = CreateTeamLeaderDispenser(leader);
		}
	}
	CreateTimer(0.1, Timer_ShowHudText_TeamLeaderStatus, leader);
}

/**
 * Removes the team leader status, dispenser, glow, and hud text from a specified client.
 *
 * @param client     Client to remove team leader attributes from.
 */
void UnsetupLeader(int prevLeader)
{
	DebugPrint(Debug_Leader, "UnsetupLeader %N", prevLeader);
	switch (TF2_GetClientTeam(prevLeader))
	{
		case TFTeam_Red:
		{
			g_TeamLeader_Red = -1;
		}
		case TFTeam_Blue:
		{
			g_TeamLeader_Blue = -1;
		}
	}
	KillTeamLeaderDispenser(prevLeader);
	KillTeamLeaderGlow(prevLeader);
	if (IsValidClientInGame(prevLeader))
	{
		ClearHudText(prevLeader, Channel_TeamLeader);
	}
}

int CreateTeamLeaderDispenser(int client)
{
	if (!IsValidClientInGame(client))
	{
		LogError("%s Client index %i wasn't valid and/or ingame during \"CreateTeamLeaderDispenser\"!", TAG, client);
		return -1;
	}

	DebugPrint(Debug_Dispenser, "CreateTeamLeaderDispenser %i", client);
	TFTeam clientTeam = TF2_GetClientTeam(client);
	float clientPos[3];
	GetClientAbsOrigin(client, clientPos);
	int dispenserEnt = CreateEntityByName("mapobj_cart_dispenser");
	if (dispenserEnt == -1)
	{
		LogError("%s Failed to create team leader %N's dispenser!", TAG, client);
		return dispenserEnt;
	}

	DispatchKeyValue(dispenserEnt, "classname", "mapobj_cart_dispenser");
	DispatchKeyValue(dispenserEnt, "spawnflags", "12");
	switch (clientTeam)
	{
		case TFTeam_Red:
		{
			DebugPrint(Debug_Dispenser, "Creating dispenser for team RED");
			DispatchKeyValue(dispenserEnt, "targetname", "pddispenser_red");
		}
		case TFTeam_Blue:
		{
			DebugPrint(Debug_Dispenser, "Creating dispenser for team BLUE");
			DispatchKeyValue(dispenserEnt, "targetname", "pddispenser_blue");
		}
	}
	DispatchKeyValueInt(dispenserEnt, "TeamNum", view_as<int>(clientTeam));
	DispatchSpawn(dispenserEnt);
	ActivateEntity(dispenserEnt);
	TeleportEntity(dispenserEnt, clientPos);
	SetVariantString("!activator");
	AcceptEntityInput(dispenserEnt, "SetParent", client);
	// I would use "SetParentAttachmentMaintainOffset" here
	// But it caused the dispenser to occasionally stop working when jumping/crouching a lot
	// Especially as soldier

	DebugPrint(Debug_Dispenser, "Dispenser: %i", dispenserEnt);
	return dispenserEnt;
}

/**
 * Fixes the dimensions of the dispenser trigger to be the map-defined size instead.
 * 
 * @param dispenserTrigger		The index of the mapobj_cart_dispenser's trigger.
 */
void FixLeaderDispenserTrigger(int dispenserTrigger)
{
	if (!IsValidEntity(dispenserTrigger))
	{
		return;
	}
	DebugPrint(Debug_Dispenser, "FixLeaderDispenserTrigger %i", dispenserTrigger);
	
	int dispenser = GetEntPropEnt(dispenserTrigger, Prop_Data, "m_hOwnerEntity");
	if (
		dispenser != -1 &&
		dispenser != g_TeamLeader_DispenserEnt_Red &&
		dispenser != g_TeamLeader_DispenserEnt_Blue
	)
	{
		return;
	}
	int leader = GetEntPropEnt(dispenser, Prop_Data, "m_hParent");
	if (!IsValidClientInGame(leader))
	{
		return;
	}

	float healDistance = GetCustomKeyValueFloat(g_DomLogicEnt, "heal_distance") / 2;
	float healDistanceNegative = healDistance * -1;
	float minBounds[3], maxBounds[3];
	minBounds[0] = healDistanceNegative;
	minBounds[1] = healDistanceNegative;
	// We leave out minBounds[2] on purpose
	maxBounds[0] = healDistance;
	maxBounds[1] = healDistance;
	maxBounds[2] = healDistance * 2; // 450 tall by default seems really tall, but whatever
	SetEntityModel(dispenserTrigger, TRIGGER_MODEL); // Makes changing the trigger bounds actually work
	SetEntPropVector(dispenserTrigger, Prop_Send, "m_vecMins", minBounds);
	SetEntPropVector(dispenserTrigger, Prop_Send, "m_vecMaxs", maxBounds);
	DebugPrint(Debug_Dispenser, "Minbounds: %f %f %f\nMaxbounds: %f %f %f",
	minBounds[0], minBounds[1], minBounds[2], maxBounds[0], maxBounds[1], maxBounds[2]);
	DebugPrint(Debug_Dispenser, "Dispenser Trigger: %i", dispenserTrigger);

	float leaderPos[3];
	GetClientAbsOrigin(leader, leaderPos);
	TeleportEntity(dispenserTrigger, leaderPos);

	// Visualizer for the dispenser trigger
	#if defined DEBUG_DISPENSER
		DataPack data;
		CreateDataTimer(0.3, Timer_TriggerVisualizer, data, TIMER_REPEAT);
		data.WriteCell(dispenserTrigger);
		data.WriteCell(TF2_GetClientTeam(leader), true);
	#endif
	// Parenting would mess up the visualizer, so it's only parented when it's not being visualized/debugged
	#if !defined DEBUG_DISPENSER
		SetVariantString("!activator");
		AcceptEntityInput(dispenserTrigger, "SetParent", dispenser);
	#endif
}

void KillTeamLeaderDispenser(int client)
{
	DebugPrint(Debug_Dispenser, "KillTeamLeaderDispenser %i", client);
	switch (TF2_GetClientTeam(client))
	{
		case TFTeam_Red:
		{
			if (!IsValidEntity(g_TeamLeader_DispenserEnt_Red))
			{
				return;
			}
			DebugPrint(Debug_Dispenser, "Killing red leader dispenser index %i...", g_TeamLeader_DispenserEnt_Red);
			RemoveEntity(g_TeamLeader_DispenserEnt_Red);
			g_TeamLeader_DispenserEnt_Red = -1;
		}
		case TFTeam_Blue:
		{
			if (!IsValidEntity(g_TeamLeader_DispenserEnt_Blue))
			{
				return;
			}
			DebugPrint(Debug_Dispenser, "Killing blue leader dispenser index %i...", g_TeamLeader_DispenserEnt_Blue);
			RemoveEntity(g_TeamLeader_DispenserEnt_Blue);
			g_TeamLeader_DispenserEnt_Blue = -1;
		}
	}
}

/**
 * From "teamoutline.sp" by "Oshizu" on the AlliedModders forum in 2013. The function was originally named "TeamOutlines". The function has been slightly modified.
 * 
 * Gives a glow/outline to a player via an item_teamflag. This does not conflict with the gamemode's own item_teamflag.
 * 
 * @param client	The client who will receive an outline effect.
 * @return			Index for the created outline effect entity.
 */
int CreateTeamLeaderGlow(int client)
{
	int glowEnt = CreateEntityByName("item_teamflag");
	float clientPos[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", clientPos);
	clientPos[2] -= 2500.0;
	TeleportEntity(glowEnt, clientPos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(glowEnt);

	switch (TF2_GetPlayerClass(client))
	{
		case TFClass_Scout: SetEntityModel(glowEnt, "models/player/scout.mdl");
		case TFClass_Soldier: SetEntityModel(glowEnt, "models/player/soldier.mdl");
		case TFClass_Pyro: SetEntityModel(glowEnt, "models/player/pyro.mdl");
		case TFClass_DemoMan: SetEntityModel(glowEnt, "models/player/demo.mdl");
		case TFClass_Heavy: SetEntityModel(glowEnt, "models/player/heavy.mdl");
		case TFClass_Engineer: SetEntityModel(glowEnt, "models/player/engineer.mdl");
		case TFClass_Medic: SetEntityModel(glowEnt, "models/player/medic.mdl");
		case TFClass_Sniper: SetEntityModel(glowEnt, "models/player/sniper.mdl");
		case TFClass_Spy: SetEntityModel(glowEnt, "models/player/spy.mdl");
		case TFClass_Civilian: SetEntityModel(glowEnt, "models/player/civilian.mdl");
	}

	float hands_away_from_my_intel[3] = {9909999.0, 99990099.0, 99900999.0}; // Removes possiblity to take the intel away by touching the player.
	SetEntPropVector(glowEnt, Prop_Send, "m_vecMins", hands_away_from_my_intel);
	SetEntPropVector(glowEnt, Prop_Send, "m_vecMaxs", hands_away_from_my_intel);

	SetVariantInt(GetClientTeam(client));
	AcceptEntityInput(glowEnt, "SetTeam");
	SetVariantString("!activator");
	AcceptEntityInput(glowEnt, "SetParent", client);
	SetEntProp(glowEnt, Prop_Send, "m_fEffects", 129);
	SetVariantString("partyhat");
	AcceptEntityInput(glowEnt, "SetParentAttachment", client);
	// This fades the model but not the glow
	// Doing this fixes broken eyes/facial flexes
	// It takes a second to take effect but at least this means I don't need custom models to fix it
	SetEntityRenderFx(glowEnt, RENDERFX_FADE_FAST);
	return glowEnt;
}

void KillTeamLeaderGlow(int client)
{
	DebugPrint(Debug_Glow, "KillTeamLeaderGlow %i", client);
	switch (TF2_GetClientTeam(client))
	{
		case TFTeam_Red:
		{
			if (!IsValidEntity(g_TeamLeader_GlowEnt_Red))
			{
				return;
			}
			DebugPrint(Debug_Dispenser, "Killing red leader glow index %i...", g_TeamLeader_GlowEnt_Red);
			RemoveEntity(g_TeamLeader_GlowEnt_Red);
			g_TeamLeader_GlowEnt_Red = -1;
		}
		case TFTeam_Blue:
		{
			if (!IsValidEntity(g_TeamLeader_GlowEnt_Blue))
			{
				return;
			}
			DebugPrint(Debug_Dispenser, "Killing blue leader glow index %i...", g_TeamLeader_GlowEnt_Blue);
			RemoveEntity(g_TeamLeader_GlowEnt_Blue);
			g_TeamLeader_GlowEnt_Blue = -1;
		}
	}
}

/**
 * For when "sm_pd_allow_spy_leader" is changed
 * This forces picking of new team leaders, in case a spy happens to be a team leader.
 * If none are found, it removes leader status from the current team leader.
 */
void FixSpyLeaders()
{
	for (int t = 2; t < 4; t++)
	{
		TFTeam team = view_as<TFTeam>(t);
		int teamTopPickupCount = GetTeamPickupCount_Top(team); // 0
		int topPickupCountCarrier = GetTeamPickupCarrier_Client(team, teamTopPickupCount); // -1

		// If there's no topPickupCountCarrier, it must mean that teamTopPickupCount is 0 and there's not a potential leader
		// If that's the case, then just do what TryUpdateTeamLeader does when there's no potential leader
		if (!IsValidClient(topPickupCountCarrier))
		{
			switch (team)
			{
				case TFTeam_Red:
				{
					if (IsValidClient(g_TeamLeader_Red))
					{
						UnsetupLeader(g_TeamLeader_Red);
					}
					g_TopPickupCount_Red = 0;
					FireCustomOutput("OnRedHitZeroPoints", g_DomLogicEnt, g_TeamLeader_Red);
				}
				case TFTeam_Blue:
				{
					if (IsValidClient(g_TeamLeader_Blue))
					{
						UnsetupLeader(g_TeamLeader_Blue);
					}
					g_TopPickupCount_Blue = 0;
					FireCustomOutput("OnBlueHitZeroPoints", g_DomLogicEnt, g_TeamLeader_Blue);
				}
			}
			ShowHudText_TeamPickupCounts(.team=team);
			return;
		}
		
		// We need to force the picking of a new leader
		// Setting the top pickup counts to zero makes TryUpdateTeamLeader actually pick a new leader
		g_TopPickupCount_Red = 0;
		g_TopPickupCount_Blue = 0;
		TryUpdateTeamLeader(topPickupCountCarrier, team);
		ShowHudText_TeamPickupCounts(.team=team);
	}
}

//#endregion


//        --------
//#region HUD TEXT
//        --------

/**
 * Shows the number of collected pickups a client has on the hud.
 *
 * @param client     Client to display the info to.
 */
void ShowHudText_ClientPickupCount(int client)
{
	if (!IsValidClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	DebugPrint(Debug_HUD, "ShowHudText_ClientPickupCount %i to %N", g_PickupCount[client], client);
	SetHudTextParams(-1.0, 0.9, 6969.0, 250, 250, 250, 255, 1, 0.1, 0.1, 0.1);
	if (g_PickupCount[client] == 1)
	{
		ShowHudText(client, Channel_PlayerPickups, "You have %i pickup!", g_PickupCount[client]);
	}
	else if (g_PickupCount[client] > 1)
	{
		ShowHudText(client, Channel_PlayerPickups, "You have %i pickups!", g_PickupCount[client]);
	}
}

Action Timer_ShowHudText_ClientPickupCount(Handle timer, int client)
{
	ShowHudText_ClientPickupCount(client);
	return Plugin_Stop;
}

/**
 * Shows the pickup counts of either both teams + their leaders, or just one team + their leader.
 *
 * @param client    The client to display this to. Displays to everyone if not specified.
 * @param team     	The TFTeam to display the point count of. Displays both teams counts if not specified..
 */
void ShowHudText_TeamPickupCounts(int client = -1, TFTeam team = TFTeam_Unassigned)
{
	DebugPrint(Debug_HUD, "ShowHudText_TeamPickupCounts (Team %i, client %i)", view_as<int>(team), client);
	char hudMsg_Red[6], hudMsg_Blue[6];
	int totalPickupCount_Red = GetTeamPickupCount_Total(TFTeam_Red);
	int totalPickupCount_Blue = GetTeamPickupCount_Total(TFTeam_Blue);

	if (g_TopPickupCount_Red > 0)
	{
		// The HUD displays the first number higher up, so we put the total pickup count last
		Format(hudMsg_Red, sizeof(hudMsg_Red), "%i\n%i", g_TopPickupCount_Red, totalPickupCount_Red);
	}
	else
	{
		Format(hudMsg_Red, sizeof(hudMsg_Red), "%i", totalPickupCount_Red);
	}

	if (g_TopPickupCount_Blue > 0)
	{
		Format(hudMsg_Blue, sizeof(hudMsg_Blue), "%i\n%i", g_TopPickupCount_Blue, totalPickupCount_Blue);
	}
	else
	{
		Format(hudMsg_Blue, sizeof(hudMsg_Blue), "%i", totalPickupCount_Blue);
	}

	switch (team)
	{
		case TFTeam_Unassigned:
		{
			// Setting c to client in order to do checks for if it was specified or not
			for (int c = client; c <= MaxClients; c++)
			{
				if (c == -1)
				{
					// If the client wasn't specified, start counting from the first real client
					c = 1;
				}
				if (!IsValidClientInGame(c) || IsFakeClient(c))
				{
					if (c == client)
					{
						// If the client that was specified isn't valid, stop now
						break;
					}
					continue;
				}

				SetHudTextParams(0.41, -0.85, 6969.0, g_HudTextColor_Blue[0], g_HudTextColor_Blue[1], g_HudTextColor_Blue[2], 255, 0, 0.1, 0.1, 0.1);
				ShowHudText(c, Channel_BluePickups, hudMsg_Blue);

				SetHudTextParams(0.58, -0.85, 6969.0, g_HudTextColor_Red[0], g_HudTextColor_Red[1], g_HudTextColor_Red[2], 255, 0, 0.1, 0.1, 0.1);
				ShowHudText(c, Channel_RedPickups, hudMsg_Red);

				if (c == client && IsValidClientInGame(c))
				{
					// If the client was specified, stop now
					break;
				}
			}
		}
		case TFTeam_Red:
		{
			for (int c = client; c <= MaxClients; c++)
			{
				if (c == -1)
				{
					c = 1;
				}
				if (!IsValidClientInGame(c) || IsFakeClient(c))
				{
					if (c == client)
					{
						break;
					}
					continue;
				}

				SetHudTextParams(0.58, -0.85, 6969.0, g_HudTextColor_Red[0], g_HudTextColor_Red[1], g_HudTextColor_Red[2], 255, 0, 0.1, 0.1, 0.1);
				ShowHudText(c, Channel_RedPickups, hudMsg_Red);

				if (c == client && IsValidClientInGame(c))
				{
					break;
				}
			}
		}
		case TFTeam_Blue:
		{
			for (int c = client; c <= MaxClients; c++)
			{
				if (c == -1)
				{
					c = 1;
				}
				if (!IsValidClientInGame(c) || IsFakeClient(c))
				{
					if (c == client)
					{
						break;
					}
					continue;
				}

				SetHudTextParams(0.41, -0.85, 6969.0, g_HudTextColor_Blue[0], g_HudTextColor_Blue[1], g_HudTextColor_Blue[2], 255, 0, 0.1, 0.1, 0.1);
				ShowHudText(c, Channel_BluePickups, hudMsg_Blue);

				if (c == client && IsValidClientInGame(c))
				{
					break;
				}
			}
		}
	}
}

Action Timer_ShowHudText_TeamPickupCounts(Handle timer, int client)
{
	ShowHudText_TeamPickupCounts(client);
	return Plugin_Stop;
}

/**
 * Shows text below the normal pickup count hud text, saying "You're team leader!", colored based on the leader's team.
 *
 * @param client     The team leader to display to.
 */
void ShowHudText_TeamLeaderStatus(int client)
{
	if (!IsValidClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	DebugPrint(Debug_HUD, "ShowHudText_TeamLeaderStatus %N", client);
	switch (TF2_GetClientTeam(client))
	{
		case TFTeam_Red:
		{
			SetHudTextParams(-1.0, 0.9, 6969.0, g_HudTextColor_Red[0], g_HudTextColor_Red[1], g_HudTextColor_Red[2], 255, 2, 0.1, 0.1, 0.0);
		}
		case TFTeam_Blue:
		{
			SetHudTextParams(-1.0, 0.9, 6969.0, g_HudTextColor_Blue[0], g_HudTextColor_Blue[1], g_HudTextColor_Blue[2], 255, 2, 0.1, 0.1, 0.0);
		}
	}
	ShowHudText(client, Channel_TeamLeader, "\nYou're team leader!");
}

Action Timer_ShowHudText_TeamLeaderStatus(Handle timer, int client)
{
	ShowHudText_TeamLeaderStatus(client);
	return Plugin_Stop;
}

/**
 * Shows text at the top for when the capture zone will open/close.
 */
void ShowHudText_CaptureZoneCountdown()
{
	char hudMsg[48];
	Format(hudMsg, sizeof(hudMsg), "Capture zone will %s in: %i second", g_Logic_IsCaptureZoneOpen ? "close" : "open", g_HudTimerNum_CaptureZone);
	if (g_HudTimerNum_CaptureZone == 1)
	{
		StrCat(hudMsg, sizeof(hudMsg), "!");
	}
	else
	{
		StrCat(hudMsg, sizeof(hudMsg), "s!");
	}
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!IsValidClientInGame(c) || IsFakeClient(c))
		{
			continue;
		}
		SetHudTextParams(-1.0, -0.8, 2.0, 250, 250, 250, 255, 1, 0.1, 0.1, 0.1);
		ShowHudText(c, Channel_Countdown, hudMsg);
	}
}

Action Timer_ShowHudText_CaptureZoneCountdown(Handle timer)
{
	if (g_HudTimerNum_CaptureZone > 0)
	{
		ShowHudText_CaptureZoneCountdown();	
	}
	else
	{
		g_Logic_IsCaptureZoneOpen = !g_Logic_IsCaptureZoneOpen;
		FireCustomOutput("OnCountdownTimerExpired", g_DomLogicEnt, g_DomLogicEnt);
		g_HudTimer_CaptureZoneCountdown = null;
		return Plugin_Stop;
	}
	g_HudTimerNum_CaptureZone--;
	return Plugin_Continue;
}

/**
 * Shows text at the top for when a team is about to win.
 */
void ShowHudText_TeamWinCountdown(TFTeam winningTeam)
{
	int hudTextEffect;
	if (!g_HudTimer_FirstFinaleCountdown)
	{
		hudTextEffect = 1;
		g_HudTimer_FirstFinaleCountdown = true;
	}
	char hudMsg[32];
	char hudMsg2[26];

	switch (winningTeam)
	{
		case TFTeam_Red:
		{
			Format(hudMsg, sizeof(hudMsg), "Red");
		}
		case TFTeam_Blue:
		{
			Format(hudMsg, sizeof(hudMsg), "Blue");
		}
	}
	Format(hudMsg2, sizeof(hudMsg2), " team wins in %i second", g_HudTimerNum_Finale);
	StrCat(hudMsg, sizeof(hudMsg), hudMsg2);
	if (g_HudTimerNum_Finale == 1)
	{
		StrCat(hudMsg, sizeof(hudMsg), "!");
	}
	else
	{
		StrCat(hudMsg, sizeof(hudMsg), "s!");
	}

	for (int c = 1; c <= MaxClients; c++)
	{
		if (!IsValidClientInGame(c) || IsFakeClient(c))
		{
			continue;
		}

		switch (winningTeam)
		{
			case TFTeam_Red:
			{
				SetHudTextParams(-1.0, -0.8, 2.0, g_HudTextColor_Red[0], g_HudTextColor_Red[1], g_HudTextColor_Red[2], 255, hudTextEffect, 0.1, 0.1, 0.1);
			}
			case TFTeam_Blue:
			{
				SetHudTextParams(-1.0, -0.8, 2.0, g_HudTextColor_Blue[0], g_HudTextColor_Blue[1], g_HudTextColor_Blue[2], 255, hudTextEffect, 0.1, 0.1, 0.1);
			}
		}
		ShowHudText(c, Channel_Countdown, hudMsg);
	}
}

Action Timer_ShowHudText_TeamWinCountdown(Handle timer, TFTeam winningTeam)
{
	if (g_HudTimerNum_Finale > 0)
	{
		int pitch;
		switch (g_HudTimerNum_Finale)
		{
			case 5:
			{
				pitch = 100;
			}
			case 4:
			{
				pitch = 105;
			}
			case 3:
			{
				pitch = 110;
			}
			case 2:
			{
				pitch = 115;
			}
			case 1:
			{
				pitch = 120;
			}
			default:
			{
				pitch = 100;
			}
		}
		EmitSoundToAll("ui/chime_rd_2base_neg.wav", .pitch=pitch);
		ShowHudText_TeamWinCountdown(winningTeam);
	}
	else
	{
		ClearHudText_All(Channel_Countdown);
		Game_EndRound(winningTeam);
		g_HudTimer_WinCountdown = null;
		return Plugin_Stop;
	}
	g_HudTimerNum_Finale--;
	return Plugin_Continue;
}

/**
 * Clears a hud text channel by showing a single character off-screen for as little time as possible..
 *
 * @param client		The client having their hud text cleared.
 * @param channel		The channel to clear the hud text from.
 */
void ClearHudText(int client, int channel)
{
	if (!IsValidClientInGame(client) || IsFakeClient(client))
	{
		return;
	}
	SetHudTextParams(-2.0, -2.0, 0.0, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
	ShowHudText(client, channel, "h");
}

/**
 * Clears a hud text channel, but for everyone on the server.
 * Works the same as "ClearHudText" otherwise.
 *
 * @param channel		The channel to clear the hud text from.
 */
void ClearHudText_All(int channel)
{
	for (int c = 1; c <= MaxClients; c++)
	{
		if (!IsValidClientInGame(c) || IsFakeClient(c))
		{
			continue;
		}
		SetHudTextParams(-2.0, -2.0, 0.0, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
		ShowHudText(c, channel, "h");
	}
}

//#endregion


//        ---------------
//#region EXTRA FUNCTIONS
//        ---------------

/**
 * Just in case.
 */
void ResetVars()
{
	for (int c = 1; c <= MaxClients; c++)
	{
		if (IsClientLeadingAnyTeam(c) && IsValidClientInGame(c))
		{
			UnsetupLeader(c);
		}
		delete g_CaptureTimer[c];
		g_PickupCount[c] = 0;
		g_CarriedFlagEnt[c] = -1;
	}
	g_TopPickupCount_Red = 0;
	g_TopPickupCount_Blue = 0;
	g_Logic_PlayerDeathPickupValue = 1;
	g_Logic_IsCaptureZoneOpen = false;
	delete g_HudTimer_CaptureZoneCountdown;
	ClearArray(g_CaptureZonesBlocking);
	ClearArray(g_PickupExpireTimers);
	g_Logic_HasRedFirstFlagStolen = false;
	g_Logic_HasBlueFirstFlagStolen = false;
	g_Logic_OnPointLimitOccurred = false;
	g_HudTimer_FirstFinaleCountdown = false;
}

public void TF2_OnWaitingForPlayersStart()
{
	g_IsInWaitingForPlayersTime = true;
}

public void TF2_OnWaitingForPlayersEnd()
{
	g_IsInWaitingForPlayersTime = false;
	// Flag captures still count towards "tf_flag_caps_per_round"
	// So we need to set it to 0 to prevent a team winning out of nowhere
	SetConVarInt(g_FlagCapturesConvar, 0);
}

/**
 * Some voice lines when capping the flag aren't fitting for player destruction IMO.
 * This function blocks a some lines across a few classes when a player captues the intel.
 */
Action OnSoundPlayed(int clients[64], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags)
{
	if (
		sample[0] == 'v' &&
		sample[1] == 'o' &&
		sample[2] == '/'
	)
	{
		// Scout
		if (
			sample[3] == 's' &&
			sample[4] == 'c' &&
			sample[7] == 't'
		)
		{
			// AutoCappedIntelligence01
			if (
				sample[9] == 'A' &&
				sample[13] == 'C' &&
				sample[19] == 'I' &&
				sample[32] == '1'
			)
			{
				return Plugin_Handled;
			}
			// SpecialCompleted05
			if (
				sample[9] == 'S' &&
				sample[16] == 'C' &&
				sample[24] == 'd' &&
				sample[26] == '5'
			)
			{
				return Plugin_Handled;
			}
		}

		// Heavy
		if (
			sample[3] == 'h' &&
			sample[6] == 'v' &&
			sample[7] == 'y'
		)
		{
			// AutoCappedIntelligence03
			if (
				sample[9] == 'A' &&
				sample[13] == 'C' &&
				sample[19] == 'I' &&
				sample[32] == '3'
			)
			{
				return Plugin_Handled;
			}
		}

		// Medic
		if (
			sample[3] == 'm' &&
			sample[6] == 'i' &&
			sample[7] == 'c'
		)
		{
			// AutoCappedIntelligence
			if (
				sample[9] == 'A' &&
				sample[13] == 'C' &&
				sample[19] == 'I'
			)
			{
				// 01 02 or 03
				if (
					sample[32] == '1' ||
					sample[32] == '2' ||
					sample[32] == '3'
				)
				{
					return Plugin_Handled;
				}
			}
		}

		// Soldier
		if (
			sample[3] == 's' &&
			sample[6] == 'd' &&
			sample[9] == 'r'
		)
		{
			// AutoCappedIntelligence
			if (
				sample[11] == 'A' &&
				sample[15] == 'C' &&
				sample[21] == 'I'
			)
			{
				// 01 or 03
				if (
					sample[34] == '1' ||
					sample[34] == '3'
				)
				{
					return Plugin_Handled;
				}
			}
		}	
	}
	return Plugin_Continue;
}

void OnStartTouchRespawnRoom(int respawnRoom, int client)
{
	if (IsValidClient(client))
	{
		g_IsInRespawnRoom[client] = true;
	}
}

void OnEndTouchRespawnRoom(int respawnRoom, int client)
{
	if (IsValidClient(client))
	{
		g_IsInRespawnRoom[client] = false;
	}
}

/**
 * Blocks annoucner voice lines by playing a null sound in the same channel as the announcer lines.
 * This means it will also block other announcer voice lines if they happen to play/be playing when this is called.
 */
void BlockAnnouncerVO()
{
	EmitSoundToAll("misc/null.wav", .channel=SNDCHAN_VOICE_BASE);
}

Action Timer_BlockAnnouncerVO(Handle timer)
{
	BlockAnnouncerVO();
	return Plugin_Stop;
}

//#endregion


//        ------
//#region STOCKS
//  	  ------

/**
 * Calculates sets the point/score limit based on the players on each team.
 * 
 * @return	The calculated score limit.
 */
stock int CalculatePointLimit()
{
	int scoreLimit = GetAllTeamsClientCount() * GetCustomKeyValueInt(g_DomLogicEnt, "points_per_player");
	int actualScoreLimit = SetPointLimit(scoreLimit);
	return actualScoreLimit;
}

/**
 * Sets the point/score limit on the domination logic entity.
 * If the calculated limit is too low, it's rounded up to the map-defined minimum value, unless specified otherwise.
 *
 * @param scorelimit     	The number to set the limit to.
 * @param ignoreMinimum     Should the map-defined minumum score be ignored? Defaults to false.
 * @return					The score limit that has been set.
 */
stock int SetPointLimit(int scoreLimit, bool ignoreMinimum = false)
{
	int minimumScore;
	if (!ignoreMinimum)
	{
		minimumScore = GetCustomKeyValueInt(g_DomLogicEnt, "min_points");
	}
	if (scoreLimit < minimumScore)
	{
		scoreLimit = minimumScore;
	}
	SetEntProp(g_DomLogicEnt, Prop_Data, "m_iPointLimitMap", scoreLimit);
	return scoreLimit;
}

stock bool CanUseBigPickups()
{
	return (g_UseBigPickupModels && strcmp(g_PickupModel_Big[0], "") != 0);
}

stock int GetAllTeamsClientCount()
{
	return GetTeamClientCount(2) + GetTeamClientCount(3);
}

/**
 * From "game.inc" in SMLib. Modified.
 * End's the current round for the specified team.
 * 
 * @param team			The winning Team.
 */
stock void Game_EndRound(TFTeam team)
{
	int roundWinEnt = FindEntityByClassname(-1, "game_round_win");

	if (roundWinEnt == -1)
	{
		roundWinEnt = CreateEntityByName("game_round_win");

		if (roundWinEnt == -1)
		{
			ThrowError("%s Unable to find or create entity \"game_round_win\"!", TAG);
		}
	}
	SetVariantInt(view_as<int>(team));
	AcceptEntityInput(roundWinEnt, "SetTeam");
	DispatchKeyValue(roundWinEnt, "win_reason", "WINREASON_ROUNDSCORELIMIT");
	DispatchKeyValueInt(roundWinEnt, "force_map_reset", 1);
	AcceptEntityInput(roundWinEnt, "RoundWin");

	ClearHudText_All(Channel_BluePickups);
	ClearHudText_All(Channel_RedPickups);
}

stock float GetCaptureZoneDelay(int captureZone)
{
	float delay, delayOffset;
	if (CustomKeyValueExists(captureZone, "capture_delay"))
	{
		delay = GetCustomKeyValueFloat(captureZone, "capture_delay");
	}
	if (CustomKeyValueExists(captureZone, "capture_delay_offset"))
	{
		delayOffset = GetCustomKeyValueFloat(captureZone, "capture_delay_offset");
	}
	if (!delay)
	{
		delay = DEFAULT_CAPTURE_DELAY;
	}
	if (!delayOffset)
	{
		delayOffset = DEFAULT_CAPTURE_DELAY_OFFSET;
	}

	delay = delay - (delayOffset * float(g_PlayerCountForCaptureDelay));
	if (delay < MIN_CAPTURE_DELAY)
	{
		delay = MIN_CAPTURE_DELAY;
	}
	else if (delay > MAX_CAPTURE_DELAY)
	{
		delay = MAX_CAPTURE_DELAY;
	}
	return delay;
}

stock bool CustomKeyValueExists(int entity, char[] key)
{
	char h[1];
	return GetCustomKeyValue(entity, key, h, 1);
}

stock float GetCustomKeyValueFloat(int entity, char[] key)
{
	char value[SMALL_FLOAT_CHAR];
	if (!GetCustomKeyValue(entity, key, value, sizeof(value)))
	{
		char classname[24];
		GetEntityClassname(entity, classname, sizeof(classname));
		ThrowError("Could not get custom keyvalue \"%s\" from entity \"%s\" (%i)!", key, classname, entity);
	}
	return StringToFloat(value);
}

stock int GetCustomKeyValueInt(int entity, char[] key)
{
	char value[SMALL_INT_CHAR];
	if (!GetCustomKeyValue(entity, key, value, sizeof(value)))
	{
		char classname[24];
		GetEntityClassname(entity, classname, sizeof(classname));
		ThrowError("Could not get custom keyvalue \"%s\" from entity \"%s\" (%i)!", key, classname, entity);
	}
	return StringToInt(value);
}

stock bool GetCustomKeyValueBool(int entity, char[] key)
{
	char value[SMALL_INT_CHAR];
	if (!GetCustomKeyValue(entity, key, value, sizeof(value)))
	{
		char classname[24];
		GetEntityClassname(entity, classname, sizeof(classname));
		ThrowError("Could not get custom keyvalue \"%s\" from entity \"%s\" (%i)!", key, classname, entity);
	}
	return view_as<bool>(StringToInt(value));
}

/**
 * From a post by "Dragokas" on the AlliedModders forums.
 *
 * @param entity		Entity to get distance to ground from.
 */
stock float GetEntityDistanceToGround(int entity)
{
    // Player is already standing on the ground?
    if (GetEntPropEnt(entity, Prop_Send, "m_hGroundEntity") <= 0) return 0.0;

    float fStart[3], fDistance = 0.0;
    GetClientAbsOrigin(entity, fStart);

    fStart[2] += 10.0;

    Handle hTrace = TR_TraceRayFilterEx(fStart, view_as<float>({90.0, 0.0, 0.0}), MASK_PLAYERSOLID, RayType_Infinite, TraceRayNoPlayers, entity);
    if(TR_DidHit())
    {
        float fEndPos[3];
        TR_GetEndPosition(fEndPos, hTrace);
        fStart[2] -= 10.0;
        fDistance = GetVectorDistance(fStart, fEndPos);
    }
    else LogError("Distance trace did not hit anything!");
    CloseHandle(hTrace);
    return fDistance;
}

/**
 * Part of GetEntityDistanceToGround.
 */
stock bool TraceRayNoPlayers(int entity, int mask)
{
    return entity > MaxClients || !entity;
}

/**
 * From "sm_dev_cmds" by Silvers.
 * Gets the position that the client is looking at.
 *
 * @param client     Client to get the view angle from.
 * @param vPos       A provided float array to store the gotten position.
 * @return           True if successful, else otherwise.
 */
stock bool GetClientViewLocation(int client, float vPos[3])
{
	float vBuffer[3], vAng[3];
	GetClientEyePosition(client, vPos);
	GetClientEyeAngles(client, vAng);

	Handle hTrace = TR_TraceRayFilterEx(vPos, vAng, MASK_SHOT, RayType_Infinite, TraceRayNoPlayers);

	if( TR_DidHit(hTrace) )
	{
		TR_GetEndPosition(vPos, hTrace);
		GetAngleVectors(vAng, vBuffer, NULL_VECTOR, NULL_VECTOR);
		vPos[0] += vBuffer[0] * -10;
		vPos[1] += vBuffer[1] * -10;
		vPos[2] += vBuffer[2] * -10;
	}
	else
	{
		delete hTrace;
		return false;
	}
	delete hTrace;
	return true;
}

stock bool IsClientLeadingAnyTeam(int client)
{
	if (
		client == g_TeamLeader_Red ||
		client == g_TeamLeader_Blue
	)
	{
		return true;
	}
	return false;
}

stock bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients;
}

stock bool IsValidClientInGame(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

/**
 * Prints a message to chat, but only when debugging for a certain part of the gamemode is allowed.
 * 
 * @param debugType			What part of the gamemode is this message debugging for?
 * @param format     		The nessage to print.
 * @param any        		Extra parameters to plug into the message (%s, %i, etc.)
 */
stock void DebugPrint(DebugType debugType, char[] format, any ...)
{
	char message[250];
	VFormat(message, sizeof(message), format, 3);

	switch (debugType)
	{
		case Debug_Pickups:
		{
			#if defined DEBUG_PICKUPS
			PrintToChatAll("%s", message);
			#endif
		}
		case Debug_Leader:
		{
			#if defined DEBUG_LEADER
			PrintToChatAll("%s", message);
			#endif
		}
		case Debug_Dispenser:
		{
			#if defined DEBUG_DISPENSER
			PrintToChatAll("%s", message);
			#endif
		}
		case Debug_Glow:
		{
			#if defined DEBUG_GLOW
			PrintToChatAll("%s", message);
			#endif
		}
		case Debug_HUD:
		{
			#if defined DEBUG_HUD
			PrintToChatAll("%s", message);
			#endif
		}
		case Debug_CaptureZone:
		{
			#if defined DEBUG_CAPTUREZONE
			PrintToChatAll("%s", message);
			#endif
		}
	}

	if(format[0]) return;
	else return;
}

/**
 * The following 3 functions were copied and modified from "sm_trigger_multiple_commands" by Silvers.
 * The function was originally named "TimerBeam"
 */
int g_Colors[4];
stock Action Timer_TriggerVisualizer(Handle timer, DataPack data)
{
	data.Reset();
	int dispenserTrigger = data.ReadCell();
	if(!IsValidEntity(dispenserTrigger))
	{
		return Plugin_Stop;
	}
	switch (data.ReadCell()) // leaderTeam
	{
		case TFTeam_Red:
		{
			g_Colors[0] = g_HudTextColor_Red[0];
			g_Colors[1] = g_HudTextColor_Red[1];
			g_Colors[2] = g_HudTextColor_Red[2];
		}
		case TFTeam_Blue:
		{
			g_Colors[0] = g_HudTextColor_Blue[0];
			g_Colors[1] = g_HudTextColor_Blue[1];
			g_Colors[2] = g_HudTextColor_Blue[2];
		}
	}
	g_Colors[3] = 255;

	float vMaxs[3], vMins[3], vPos[3];
	GetEntPropVector(dispenserTrigger, Prop_Send, "m_vecOrigin", vPos);
	GetEntPropVector(dispenserTrigger, Prop_Send, "m_vecMaxs", vMaxs);
	GetEntPropVector(dispenserTrigger, Prop_Send, "m_vecMins", vMins);
	AddVectors(vPos, vMaxs, vMaxs);
	AddVectors(vPos, vMins, vMins);
	TE_SendBox(vMins, vMaxs);
	return Plugin_Continue;
}

/**
 * Part of Timer_TriggerVisualizer.
 */
void TE_SendBox(float vMins[3], float vMaxs[3])
{
	float vPos1[3], vPos2[3], vPos3[3], vPos4[3], vPos5[3], vPos6[3];
	vPos1 = vMaxs;
	vPos1[0] = vMins[0];
	vPos2 = vMaxs;
	vPos2[1] = vMins[1];
	vPos3 = vMaxs;
	vPos3[2] = vMins[2];
	vPos4 = vMins;
	vPos4[0] = vMaxs[0];
	vPos5 = vMins;
	vPos5[1] = vMaxs[1];
	vPos6 = vMins;
	vPos6[2] = vMaxs[2];
	TE_SendBeam(vMaxs, vPos1);
	TE_SendBeam(vMaxs, vPos2);
	TE_SendBeam(vMaxs, vPos3);
	TE_SendBeam(vPos6, vPos1);
	TE_SendBeam(vPos6, vPos2);
	TE_SendBeam(vPos6, vMins);
	TE_SendBeam(vPos4, vMins);
	TE_SendBeam(vPos5, vMins);
	TE_SendBeam(vPos5, vPos1);
	TE_SendBeam(vPos5, vPos3);
	TE_SendBeam(vPos4, vPos3);
	TE_SendBeam(vPos4, vPos2);
}

/**
 * Part of Timer_TriggerVisualizer.
 */
void TE_SendBeam(const float vMins[3], const float vMaxs[3])
{
	TE_SetupBeamPoints(vMins, vMaxs, g_iLaserMaterial, g_iHaloMaterial, 0, 0, 0.3 + 0.1, 1.0, 1.0, 1, 0.0, g_Colors, 0);
	TE_SendToAll();
}

//#endregion