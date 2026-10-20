// =====================================================================
//  ZPI scene pack - environment: locations, time of day, weather, barrage
// =====================================================================

// ---- locations (train/val/test split by region) ---------------------------
// Place empty markers named ZPI_center_0, ZPI_center_1, ... in Eden.
// Without markers the player's start position is the only location.
ZPI_fnc_initLocations = {
    private _m = allMapMarkers select { (_x find "ZPI_center") == 0 };
    _m sort true;
    ZPI_locations = _m apply { private _p = markerPos _x; [_p select 0, _p select 1, 0] };
    if (ZPI_locations isEqualTo []) then {
        private _p = getPosATL player;
        ZPI_locations = [[_p select 0, _p select 1, 0]];
    };
    ZPI_regionId = 0;
    ZPI_center = ZPI_locations select 0;
};

ZPI_fnc_setCenter = {
    params ["_pos", "_region", ["_moveCam", true]];
    ZPI_center = [_pos select 0, _pos select 1, 0];
    ZPI_regionId = _region;
    ["center", format ['{"center":%1}', [ZPI_center, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
    if (_moveCam) then { [true] call ZPI_fnc_viewScene };
    [format ["Location %1 (grid %2)", _region, mapGridPosition ZPI_center]] call ZPI_fnc_msg;
    if (ZPI_currentScene >= 0) then { [ZPI_currentScene] call ZPI_fnc_runScene };
};

ZPI_fnc_nextLocation = {
    private _i = (ZPI_regionId max -1) + 1;
    if (_i >= count ZPI_locations) then { _i = 0 };
    [ZPI_locations select _i, _i] call ZPI_fnc_setCenter;
};

// ---- exposure: fixed aperture at the generator's light (noon, clear), automatic otherwise ----
ZPI_fnc_applyAperture = {
    private _a = missionNamespace getVariable ["ZPI_cfg_aperture", -1];
    if (_a > 0 && {ZPI_timeIndex == ZPI_cfg_tourTime} && {ZPI_weatherIndex == ZPI_cfg_tourWeather}) then {
        setAperture _a;
    } else {
        setAperture -1;
    };
};
ZPI_fnc_loadExposure = {         // re-read zpi\exposure.sqf (written by tools/pick_exposure.py)
    call compile preprocessFileLineNumbers "zpi\exposure.sqf";
    call ZPI_fnc_applyAperture;
    ["exposure", format ['{"aperture":%1}', ZPI_cfg_aperture]] call ZPI_fnc_event;
};

// End key: the same view at every aperture in ZPI_cfg_apertureTest (noon, clear), so
// tools/pick_exposure.py can pick the best one from the pictures.
ZPI_expTestRunning = false;
ZPI_fnc_exposureTest = {
    if (ZPI_tourRunning || {ZPI_expTestRunning}) exitWith {};
    ZPI_expTestRunning = true;
    ZPI_timeIndex = ZPI_cfg_tourTime;       call ZPI_fnc_applyTime;
    ZPI_weatherIndex = ZPI_cfg_tourWeather; call ZPI_fnc_applyWeather;
    // same camera as the generator: a soldier (or anything in the scene) from ~200 m, 50 deg down,
    // soldier close-up zoom. Without a scene: the current view.
    private _men = (ZPI_entities select { !isNull (_x select 1) && {(_x select 1) isKindOf "Man"} }) apply { _x select 1 };
    private _all = (ZPI_entities select { !isNull (_x select 1) }) apply { _x select 1 };
    private _t = if (_men isNotEqualTo []) then { _men select 0 } else { _all param [0, objNull] };
    if (!isNull _t) then {
        ZPI_scaleLock = true;
        ZPI_targetGSD = (ZPI_cfg_tourSoldierGSD select 0) max 0.009;
        [(getPosASL _t) vectorAdd [0, 0, 1], random 360, 50, 200] call ZPI_fnc_tourAim;
    } else {
        ["Exposure test: no scene, using the current view (start a scene first for a generator-like view)"] call ZPI_fnc_msg;
    };
    [format ["Exposure test: %1 pictures, do not move (~%2 s)", (count ZPI_cfg_apertureTest) + 1, round (1.6 * (count ZPI_cfg_apertureTest) + 9)]] call ZPI_fnc_msg;
    sleep ZPI_cfg_tourSettle;                // zoom settles, textures load
    ZPI_camLock = true;
    ZPI_fovLock = true;
    sleep 0.5;
    {
        setAperture _x;
        sleep 1.2;
        private _file = format ["exposure_A%1_%2.png", _x, [diag_frameNo, 8] call ZPI_fnc_pad];
        screenshot format ["zpi\%1\%2", ZPI_sessionTag, _file];
        ["exposure_test", format ['{"image":"zpi/%1/%2","aperture":%3}', ZPI_sessionTag, _file, _x]] call ZPI_fnc_event;
        sleep 0.4;
    } forEach ZPI_cfg_apertureTest;
    setAperture -1;                          // automatic, for comparison
    sleep 3;
    screenshot format ["zpi\%1\exposure_Aauto_%2.png", ZPI_sessionTag, [diag_frameNo, 8] call ZPI_fnc_pad];
    sleep 0.4;
    call ZPI_fnc_applyAperture;
    ZPI_camLock = false;
    ZPI_fovLock = false;
    ZPI_mouseDX = 0; ZPI_mouseDY = 0;
    ZPI_lastTick = diag_tickTime;
    ZPI_expTestRunning = false;
    ["Exposure test done. Now run:  python tools/pick_exposure.py   (then Home uses the new exposure)"] call ZPI_fnc_msg;
};

// ---- time of day -------------------------------------------------------------
ZPI_timePresets = [[6, 0, "dawn"], [12, 0, "noon"], [17, 30, "afternoon"], [20, 30, "dusk"], [23, 0, "night"]];
ZPI_timeIndex = 1;
ZPI_fnc_applyTime = {
    (ZPI_timePresets select ZPI_timeIndex) params ["_hh", "_mm", "_label"];
    setDate [2035, 6, 15, _hh, _mm];
    ["time", format ['{"label":"%1","hour":%2,"minute":%3}', _label, _hh, _mm]] call ZPI_fnc_event;
    call ZPI_fnc_applyAperture;
    [format ["Time: %1 (%2:%3%4)", _label, _hh, ["", "0"] select (_mm < 10), _mm]] call ZPI_fnc_msg;
};
ZPI_fnc_nextTime = {
    ZPI_timeIndex = (ZPI_timeIndex + 1) mod (count ZPI_timePresets);
    call ZPI_fnc_applyTime;
};

// ---- weather -------------------------------------------------------------------
// [label, overcast, fog, rain]
ZPI_weatherPresets = [["clear", 0, 0, 0], ["overcast", 0.8, 0, 0], ["fog", 0.4, 0.35, 0], ["rain", 1, 0.08, 1]];
ZPI_weatherIndex = 0;
ZPI_fnc_applyWeather = {
    (ZPI_weatherPresets select ZPI_weatherIndex) params ["_label", "_oc", "_fog", "_rain"];
    0 setOvercast _oc;
    0 setFog _fog;
    0 setRain _rain;
    0 setLightnings 0;
    forceWeatherChange;
    999999 setOvercast _oc;     // hold it there
    999999 setFog _fog;
    999999 setRain _rain;
    ["weather", format ['{"label":"%1","overcast":%2,"fog":%3,"rain":%4}', _label, _oc, _fog, _rain]] call ZPI_fnc_event;
    call ZPI_fnc_applyAperture;
    [format ["Weather: %1", _label]] call ZPI_fnc_msg;
};
ZPI_fnc_nextWeather = {
    ZPI_weatherIndex = (ZPI_weatherIndex + 1) mod (count ZPI_weatherPresets);
    call ZPI_fnc_applyWeather;
};

// ---- artillery barrage: explosions for the "wybuch" class -------------------------
// Impacts land at least ZPI_cfg_barrageMinClear m from every scene object.
// Each detonation is logged with its exact position (projectile "Explode" handler).
ZPI_barrageRunning = false;
ZPI_expId = 100000;            // explosion ids live in their own range

ZPI_fnc_safeImpactPos = {
    params ["_around"];
    private _best = _around;
    for "_t" from 1 to 30 do {
        private _p = [_around, [360] call ZPI_fnc_rand, 0, [60, 300] call ZPI_fnc_randRange] call ZPI_fnc_rel;
        private _clear = ZPI_entities findIf { !isNull (_x select 1) && {((_x select 1) distance2D _p) < ZPI_cfg_barrageMinClear} } == -1;
        if (_clear && {!surfaceIsWater _p}) exitWith { _best = _p };
    };
    _best
};

ZPI_fnc_barrage = {
    if (ZPI_barrageRunning) exitWith { ["Barrage already running"] call ZPI_fnc_msg };
    ZPI_barrageRunning = true;
    private _ammo = ([ZPI_cfg_barrageAmmo, "CfgAmmo"] call ZPI_fnc_validClasses) param [0, "Sh_82mm_AMOS"];
    private _impacts = [];
    // free camera: around the point you are looking at; drone: around the scene center
    private _around = ZPI_center;
    if (ZPI_camMode == "free") then {
        private _lp = call ZPI_fnc_lookPoint;
        if (_lp isNotEqualTo [] && {(ZPI_camPosASL distance _lp) < 4000}) then { _around = [_lp select 0, _lp select 1, 0] };
    };
    for "_i" from 1 to ZPI_cfg_barrageCount do { _impacts pushBack ([_around] call ZPI_fnc_safeImpactPos) };
    ["barrage", format ['{"ammo":"%1","count":%2}', _ammo, count _impacts]] call ZPI_fnc_event;
    ["Barrage incoming"] call ZPI_fnc_msg;
    [_ammo, _impacts] spawn {
        params ["_ammo", "_impacts"];
        {
            private _z = getTerrainHeightASL _x;
            // wait for the previous explosion picture, then hold the camera and take the reference
            private _t0 = time;
            waitUntil { (ZPI_capState == 0 && {!ZPI_camLock} && {ZPI_pendingCapture < 0}) || {time > _t0 + 6} };
            if ([[_x select 0, _x select 1, _z]] call ZPI_fnc_takeRef) then { sleep 0.15 };
            ZPI_expId = ZPI_expId + 1;
            private _sh = createVehicle [_ammo, [_x select 0, _x select 1, 60], [], 0, "CAN_COLLIDE"];
            _sh setVariable ["ZPI_id", ZPI_expId];
            _sh setPosASL [_x select 0, _x select 1, _z + 60];
            _sh setVectorDirAndUp [[0, 0, -1], [0, 1, 0]];
            _sh setVariable ["ZPI_expSize", [_ammo] call ZPI_fnc_explosionSize];
            _sh addEventHandler ["Explode", {
                params ["_projectile", "_pos"];
                [_pos, _projectile getVariable ["ZPI_expSize", ZPI_cfg_expMedium], _projectile getVariable ["ZPI_id", -1]] call ZPI_fnc_addExplosion;
            }];
            _sh setVelocity [0, 0, -150];
            sleep (0.8 + random 0.6);
        } forEach _impacts;
        ZPI_barrageRunning = false;
    };
};
