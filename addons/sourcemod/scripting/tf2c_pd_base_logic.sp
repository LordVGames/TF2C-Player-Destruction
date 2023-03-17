#include <entityIO>

int g_DomLogicScore_Red, g_DomLogicScore_Blue;
bool g_Logic_HasRedFirstFlagStolen, g_Logic_HasBlueFirstFlagStolen;
bool g_Logic_IsCaptureZoneOpen; // False is closed, true is open
bool g_Logic_AllowMaxScoreUpdating;
int g_Logic_PlayerDeathPickupValue;
bool g_Logic_OnPointLimitOccurred; // This is needed since the "OnPointLimit" function is spammed for some reason.

/**
 * Gets a bunch of values from worldspawn for use in the plugin.
 */
void GetDomLogicValues()
{
	GetCustomKeyValue(g_DomLogicEnt, "prop_model_name", g_PickupModel, sizeof(g_PickupModel));
	GetCustomKeyValue(g_DomLogicEnt, "prop_drop_sound", g_PickupSound_Drop, sizeof(g_PickupSound_Drop));
	GetCustomKeyValue(g_DomLogicEnt, "prop_pickup_sound", g_PickupSound_Collect, sizeof(g_PickupSound_Collect));

	if (strcmp("", g_PickupModel[0]) == 0)
	{
		PrintToServer("%s ERROR: Pickup model was read as blank! Double check your \"tf_logic_domination\" entity!", TAG);
	}
	else if (!IsModelPrecached(g_PickupModel))
	{
		PrintToServer("%s Precaching Pickup Model: %s", TAG, g_PickupModel);
		PrecacheModel(g_PickupModel);
	}
	if (GetCustomKeyValue(g_DomLogicEnt, "prop_big_model_name", g_PickupModel_Big, sizeof(g_PickupModel_Big)))
	{
		if (strcmp("", g_PickupModel_Big[0]) == 0)
		{
			PrintToServer("%s ERROR: Big pickup model was read as blank! Double check your stripper config file for the current map!\n%sPickups will fall back to the normal model for now.", TAG, TAG);
		}
		else if (!IsModelPrecached(g_PickupModel_Big))
		{
			PrintToServer("%s Precaching Big Pickup Model: %s", TAG, g_PickupModel_Big);
			PrecacheModel(g_PickupModel_Big);
		}
	}

	char tempSplit[1];
	if (strcmp("", g_PickupSound_Collect[0]) == 0)
	{
		PrintToServer("%s ERROR: Pickup collect sound was read as blank! Double check your \"tf_logic_domination\" entity!", TAG);
	}
	else
	{
		// Soundscripts never have a slash in them
		// This helps us figure out whether the sound to precache is a direct path or a soundscript
		if (SplitString(g_PickupSound_Collect, "/", tempSplit, sizeof(tempSplit)) != -1)
		{
			PrintToServer("%s Precaching Normal Pickup Collect Sound: %s", TAG, g_PickupSound_Collect);
			PrecacheSound(g_PickupSound_Collect);
		}
		else
		{
			PrintToServer("%s Precaching Script Pickup Collect Sound: %s", TAG, g_PickupSound_Collect);
			PrecacheScriptSound(g_PickupSound_Collect);
		}
	}

	if (strcmp("", g_PickupSound_Drop[0]) == 0)
	{
		PrintToServer("%s ERROR: Pickup drop sound was read as blank! Double check your \"tf_logic_domination\" entity!", TAG);
	}
	else
	{
		if (SplitString(g_PickupSound_Drop, "/", tempSplit, sizeof(tempSplit)) != -1)
		{
			PrintToServer("%s Precaching Normal Pickup Drop Sound: %s", TAG, g_PickupSound_Drop);
			PrecacheSound(g_PickupSound_Drop);
		}
		else
		{
			PrintToServer("%s Precaching Script Pickup Drop Sound: %s", TAG, g_PickupSound_Drop);
			PrecacheScriptSound(g_PickupSound_Drop);
		}
	}

	GameRules_SetPropFloat("m_flNextRespawnWave", GetCustomKeyValueFloat(g_DomLogicEnt, "red_respawn_time"), 2);
	GameRules_SetPropFloat("m_flNextRespawnWave", GetCustomKeyValueFloat(g_DomLogicEnt, "blue_respawn_time"), 3);
}

/**
 * Makes an entity fire a custom output.
 * @param outputName	The name of the custom output to fire.
 * @param outputFireEnt	The entity index firing the output.
 * @param activatorEnt	The entity index that caused the output.
 * @param hasOutValue	Does the output have a value that is sent out with it?
 * @param outValue		The value used if the output does have an outvalue.
 * 
 * @note Using !self as the targetname may not work with this. Untested.
 * If it does not work, use the targetname of the entity being targeted with !self instead.
 * @note The "refires" part of the output doesn't work with this.
 * This can be worked around with a logic_relay in your map, along with a math_counter if more than 0 allowed refires are desired.
 */
void FireCustomOutput(char[] outputName, int outputFireEnt, int activatorEnt, bool hasOutValue = false, int outValue = 0)
{
	/**
	 * Each custom output of an entity is also stored as a custom keyvalue.
	 * If multiple of the same output exists, only the last one will be read.
	 * Due to this, multiple of the same output need a number added to the end of its name in order to have all of the entries be read correctly.
	 */

	char output[128]; // Size is 128 in case someone uses AddOutput with a custom output.
	char outputParts[5][32];
	char outputFullName[32];
	int logicEnt;
	char logicEntOutput[12], logicEntInput[12];
	if (hasOutValue)
	{
		logicEnt = CreateEntityByName("math_counter");
		DispatchKeyValueInt(logicEnt, "startvalue", outValue);
		Format(logicEntOutput, sizeof(logicEntOutput), "OnGetValue");
		Format(logicEntInput, sizeof(logicEntInput), "GetValue");
	}
	else
	{
		logicEnt = CreateEntityByName("logic_relay");
		Format(logicEntOutput, sizeof(logicEntOutput), "OnTrigger");
		Format(logicEntInput, sizeof(logicEntInput), "Trigger");
	}
	for (int i = 1; i < 11; i++)
	{
		Format(outputFullName, sizeof(outputFullName), "%s%i", outputName, i);
		if (!CustomKeyValueExists(outputFireEnt, outputFullName))
		{
			break;
		}

		GetCustomKeyValue(outputFireEnt, outputFullName, output, sizeof(output));
		ExplodeString(output, ",", outputParts, sizeof(outputParts), sizeof(outputParts[]), true);
		/*
			0 - ent targetname
			1 - input name
			2 - parameter
			3 - delay
			4 - refire limit
		*/
		EntityIO_AddEntityOutputAction(
			logicEnt, logicEntOutput,
			outputParts[0], outputParts[1], outputParts[2],
			StringToFloat(outputParts[3]), StringToInt(outputParts[4])
		);
	}
	// Only fire our outputs if there is any there in the first place.
	if (EntityIO_FindEntityFirstOutputAction(logicEnt, EntityIO_FindEntityOutputOffset(logicEnt, logicEntOutput)))
	{
		AcceptEntityInput(logicEnt, logicEntInput, activatorEnt, outputFireEnt);
	}
	RemoveEntity(logicEnt);
}

public Action EntityIO_OnEntityInput(int entity, char input[256], int& activator, int& caller, EntityIO_VariantInfo variantInfo, int actionId)
{
	if (entity != g_DomLogicEnt)
	{
		return Plugin_Continue;
	}

	int inputValue;
	switch (variantInfo.variantType)
	{
		case EntityIO_VariantType_Integer:
		{
			inputValue = variantInfo.iValue;
		}
		case EntityIO_VariantType_String:
		{
			inputValue = StringToInt(variantInfo.sValue);
		}
	}
	
	/**
	 * Unimplemented:
	 * - SetCountdownImage: AFAIK using an overlay is the only way to do this, and I don't want clients downloading anything for the gamemode.
	 * - ScoreRedPoints & ScoreBluePoints: Already implemented as AddRedPoints and AddBluePoints, plus they can take a parameter.
	 */

	//#region AddRedPoints, SetRedPoints, AddBluePoints, SetBluePoints
	if (
		input[6] == 'P' ||
		input[7] == 'P'
	) {
		if (input[3] == 'R')
		{
			if (input[0] == 'A')
			{
				g_DomLogicScore_Red += inputValue;
			}
			else if (input[0] == 'S')
			{
				g_DomLogicScore_Red = inputValue;
			}
			FireCustomOutput("OnRedScoreChanged", g_DomLogicEnt, activator, true, g_DomLogicScore_Red);
		}
		else if (input[3] == 'B')
		{
			if (input[0] == 'A')
			{
				g_DomLogicScore_Blue += inputValue;
			}
			else if (input[0] == 'S')
			{
				g_DomLogicScore_Blue = inputValue;
			}
			FireCustomOutput("OnBlueScoreChanged", g_DomLogicEnt, activator, true, g_DomLogicScore_Blue);
		}
	}
	//#endregion

	//#region EnableMaxScoreUpdating, DisableMaxScoreUpdating
	if (
		(input[6] == 'M' && input[9] == 'S' && input[14] == 'U') ||
		(input[7] == 'M' && input[10] == 'S' && input[15] == 'U')
	) {
		if (input[0] == 'E')
		{
			g_Logic_AllowMaxScoreUpdating = true;
			CalculatePointLimit(); // Mot sure if it did this as well or not
		}
		else if(input[0] == 'D')
		{
			g_Logic_AllowMaxScoreUpdating = false;
			CalculatePointLimit(); // Same here
		}
	}
	//#endregion

	// Various inputs starting with "Set"
	if (input[0] == 'S')
	{
		//#region SetCountdownTimer
		if (
			input[3] == 'C' &&
			input[8] == 'd' &&
			input[12] == 'T'
		) {
			g_HudTimerNum_CaptureZone = inputValue;
			if (g_HudTimer_CaptureZoneCountdown != null)
			{
				g_Logic_IsCaptureZoneOpen = !g_Logic_IsCaptureZoneOpen;
				delete g_HudTimer_CaptureZoneCountdown;
			}
			// We don't want to start up the countdown timer if the "Team will win" text is active
			// g_Logic_OnPointLimitOccurred being false means it's not active
			if (!g_Logic_OnPointLimitOccurred)
			{
				g_HudTimer_CaptureZoneCountdown = CreateTimer(1.0, Timer_ShowHudText_CaptureZoneCountdown, inputValue, TIMER_REPEAT);
				TriggerTimer(g_HudTimer_CaptureZoneCountdown);
			}
		}
		//#endregion

		//#region SetFlagResetDelay
		if (
			input[3] == 'F' &&
			input[7] == 'R' &&
			input[12] == 'D'
		) {
			char inputValueString[3];
			Format(inputValueString, sizeof(inputValueString), "%i", inputValue);
			SetCustomKeyValue(g_DomLogicEnt, "flag_reset_delay", inputValueString, true);
		}
		//#endregion

		//#region SetPointsOnPlayerDeath 
		if (
			input[3] == 'P' &&
			input[9] == 'O' &&
			input[11] == 'P' &&
			input[17] == 'D'
		) {
			g_Logic_PlayerDeathPickupValue = inputValue;
		}
		//#endregion
	}

	return Plugin_Continue;
}