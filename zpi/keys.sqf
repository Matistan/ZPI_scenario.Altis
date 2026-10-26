// =====================================================================
//  ZPI scene pack - controls (DIK key codes) and help text
// =====================================================================

ZPI_helpText = "<t size='1.1' font='RobotoCondensedBold'>ZPI drone scenes</t><br/>"
    + "<t align='left'>"
    + "<t color='#ffd27a'>CAMERA</t>  V free / drone<br/>"
    + "Free: WASD move, E up, Q down, Shift fast<br/>"
    + "Mouse look, wheel zoom, arrows look<br/>"
    + "Drone: G gimbal, O pause, arrows alt/radius<br/>"
    + "PgUp / PgDn zoom presets (75 ... 1.2 deg)<br/>"
    + "R constant pixel size on/off (zoom follows range)<br/><br/>"
    + "<t color='#ffd27a'>DATASET</t><br/>"
    + "P screenshot + labels<br/>"
    + "Shift+P auto-capture on/off<br/>"
    + "K firefight on/off &#160; Shift+K one volley<br/>"
    + "B barrage where you look<br/>"
    + "I auto-shot on explosions on/off<br/>"
    + "Z orthophoto of the scene area<br/>"
    + "Home dataset generator: makes ZPI_cfg_tourTarget images by itself (Home stops)<br/><br/>"
    + "<t color='#ffd27a'>SCENES</t>  1-9, 0<br/>"
    + "1 checkpoint &#160; 2 column &#160; 3 dug-in<br/>"
    + "4 convoy &#160; 5 patrols &#160; 6 tank platoon<br/>"
    + "7 village &#160; 8 size ladder &#160; 9 negatives &#160; 0 mixed<br/>"
    + "- squad enters a building &#160; [ tank column &#160; ] squads split<br/>"
    + "Shift+1 fireteam into a house &#160; Shift+2 dismount + entry<br/>"
    + "Shift+3 two buildings &#160; Shift+4 single file entry<br/>"
    + "Shift+5 tank column across fields &#160; Shift+6 tanks firing (then K)<br/>"
    + "Shift+7 long armour column &#160; Shift+8 patrol across fields<br/>"
    + "Shift+9 patrol on a road &#160; Shift+0 lone building entry<br/>"
    + "Shift+- groups kneeling / prone<br/>"
    + "Shift+[ tank escort<br/>"
    + "N new layout &#160; X clear &#160; L next location<br/>"
    + "C scene to where you look &#160; J camera to scene<br/>"
    + "Alt+click on map: move scene there<br/><br/>"
    + "T time &#160; Y weather &#160; F frame bar<br/>"
    + "U quiet (no text) &#160; H help"
    + "</t>";

ZPI_fnc_showHelp = {
    hintSilent parseText ZPI_helpText;
    [] spawn { sleep 10; hintSilent "" };
};

ZPI_fnc_status = {
    [format ["alt %1 m, radius %2 m, gimbal %3, FOV %4 deg",
        ZPI_cfg_orbitAlt, ZPI_cfg_orbitRadius, ZPI_gimbalModes select ZPI_gimbalIndex,
        ZPI_hfov toFixed 1]] call ZPI_fnc_msg;
};

ZPI_fnc_orbitEvent = {
    ["orbit", format ['{"alt":%1,"radius":%2}', ZPI_cfg_orbitAlt, ZPI_cfg_orbitRadius]] call ZPI_fnc_event;
    call ZPI_fnc_status;
};

// keys used for free-camera movement: tracked as held, swallowed so the game ignores them
ZPI_moveKeys = [17, 30, 31, 32, 16, 18, 42, 54, 200, 203, 205, 208];

ZPI_fnc_onKeyUp = {
    params ["_disp", "_key"];
    ZPI_keysDown set [_key, false];
    _key in ZPI_moveKeys && {ZPI_camActive}
};

ZPI_fnc_onKey = {
    params ["_disp", "_key", "_shift", "_ctrl", "_alt"];
    if (_ctrl || _alt || visibleMap || dialog) exitWith { false };
    if (!ZPI_camActive) exitWith { false };
    if (ZPI_orthoRunning) exitWith { true };   // no input during the orthophoto flight
    if (ZPI_tourRunning && {_key != 199} && {_key != 22} && {_key != 35}) exitWith { true };   // tour: only Home, U, H
    ZPI_keysDown set [_key, true];
    private _free = ZPI_camMode == "free";
    if (_key in ZPI_moveKeys) exitWith {
        // in drone mode the arrows change altitude / radius instead of looking
        if (!_free) then {
            switch (_key) do {
                case 200: { ZPI_cfg_orbitAlt = ZPI_cfg_orbitAlt + 50; call ZPI_fnc_orbitEvent };
                case 208: { ZPI_cfg_orbitAlt = (ZPI_cfg_orbitAlt - 50) max 100; call ZPI_fnc_orbitEvent };
                case 203: { ZPI_cfg_orbitRadius = (ZPI_cfg_orbitRadius - 100) max 100; call ZPI_fnc_orbitEvent };
                case 205: { ZPI_cfg_orbitRadius = ZPI_cfg_orbitRadius + 100; call ZPI_fnc_orbitEvent };
            };
        };
        true
    };
    // Shift+1 ... Shift+0: building fireteam, dismount, two buildings, single file, tank column across fields,
    // tanks firing, long armour column, patrol across fields, patrol on a road, lone building; Shift+- groups down
    if (_shift && {_key in [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]}) exitWith { [_key + 11] call ZPI_fnc_runScene; true };
    if (_shift && {_key == 12}) exitWith { [23] call ZPI_fnc_runScene; true };
    if (_shift && {_key == 26}) exitWith { [24] call ZPI_fnc_runScene; true };
    private _handled = true;
    switch (_key) do {
        case 2:  { [1] call ZPI_fnc_runScene };
        case 3:  { [2] call ZPI_fnc_runScene };
        case 4:  { [3] call ZPI_fnc_runScene };
        case 5:  { [4] call ZPI_fnc_runScene };
        case 6:  { [5] call ZPI_fnc_runScene };
        case 7:  { [6] call ZPI_fnc_runScene };
        case 8:  { [7] call ZPI_fnc_runScene };
        case 9:  { [8] call ZPI_fnc_runScene };
        case 10: { [9] call ZPI_fnc_runScene };
        case 11: { [0] call ZPI_fnc_runScene };
        case 25: { if (_shift) then { call ZPI_fnc_toggleAuto } else { call ZPI_fnc_startCapture } };   // P
        case 37: { if (_shift) then { call ZPI_fnc_shoot } else { call ZPI_fnc_toggleFirefight } };   // K / Shift+K
        case 23: { call ZPI_fnc_toggleEventCapture };                       // I
        case 19: { call ZPI_fnc_toggleScaleLock };                          // R
        case 44: { call ZPI_fnc_orthoCapture };                             // Z
        case 12: { [10] call ZPI_fnc_runScene };                            // - (minus)
        case 26: { [11] call ZPI_fnc_runScene };                            // [ tank column
        case 27: { [12] call ZPI_fnc_runScene };                            // ] squads split
        case 199: {                                                         // Home: automatic flight on/off
            if (ZPI_tourRunning) then { ZPI_tourStop = true; ["Stopping the automatic flight after this shot"] call ZPI_fnc_msg }
            else { [] spawn ZPI_fnc_tourDataset };
        };
        case 48: { call ZPI_fnc_barrage };                                  // B
        case 47: { [["drone", "free"] select (ZPI_camMode == "drone")] call ZPI_fnc_setCamMode };   // V
        case 49: {                                                          // N
            ZPI_cfg_seed = ZPI_cfg_seed + 1;
            if (ZPI_currentScene >= 0) then { [ZPI_currentScene] call ZPI_fnc_runScene } else { [format ["Seed %1", ZPI_cfg_seed]] call ZPI_fnc_msg };
        };
        case 45: {                                                          // X
            call ZPI_fnc_clearScene;
            ["scene_clear"] call ZPI_fnc_event;
            ZPI_currentScene = -1;
            ZPI_sceneName = "none";
            ["Scene cleared"] call ZPI_fnc_msg;
        };
        case 38:  { call ZPI_fnc_nextLocation };                            // L
        case 46: {                                                          // C: scene to the point you look at
            private _lp = call ZPI_fnc_lookPoint;
            if (_lp isEqualTo []) then { ["Look at the ground first (middle of the screen)"] call ZPI_fnc_msg } else { [_lp, -1, false] call ZPI_fnc_setCenter };
        };
        case 36: { [true] call ZPI_fnc_viewScene };                         // J: camera to the scene
        case 201: { [1] call ZPI_fnc_zoomStep };                            // PgUp
        case 209: { [-1] call ZPI_fnc_zoomStep };                           // PgDn
        case 34: {                                                          // G
            ZPI_gimbalIndex = (ZPI_gimbalIndex + 1) mod (count ZPI_gimbalModes);
            ["gimbal", format ['{"mode":"%1"}', ZPI_gimbalModes select ZPI_gimbalIndex]] call ZPI_fnc_event;
            call ZPI_fnc_status;
        };
        case 24: {                                                          // O
            ZPI_orbitPaused = !ZPI_orbitPaused;
            [["Orbit running", "Orbit paused"] select ZPI_orbitPaused] call ZPI_fnc_msg;
        };
        case 20: { call ZPI_fnc_nextTime };                                 // T
        case 21: { call ZPI_fnc_nextWeather };                              // Y
        case 33: {                                                          // F
            ZPI_cfg_frameCode = !ZPI_cfg_frameCode;
            if (ZPI_cfg_frameCode) then { call ZPI_fnc_showFrameCode } else { call ZPI_fnc_hideFrameCode };
        };
        case 22: {                                                          // U
            ZPI_quiet = !ZPI_quiet;
            showChat !ZPI_quiet;
            if (ZPI_quiet) then {
                call ZPI_fnc_hideHud;
                ("ZPI_msgLayer" call BIS_fnc_rscLayer) cutText ["", "PLAIN"];
            } else {
                call ZPI_fnc_showHud;
                ["Quiet mode off"] call ZPI_fnc_msg;
            };
            hintSilent "";
        };
        case 35: { call ZPI_fnc_showHelp };                                 // H
        default { _handled = false };
    };
    _handled
};

ZPI_fnc_initKeys = {
    private _d = findDisplay 46;
    _d displayAddEventHandler ["KeyDown", { _this call ZPI_fnc_onKey }];
    _d displayAddEventHandler ["KeyUp",   { _this call ZPI_fnc_onKeyUp }];
    _d displayAddEventHandler ["MouseMoving", {
        params ["_disp", "_dx", "_dy"];
        if (ZPI_camActive && {ZPI_camMode == "free"} && {!visibleMap} && {!dialog} && {!ZPI_tourRunning}) then {
            ZPI_mouseDX = ZPI_mouseDX + _dx;
            ZPI_mouseDY = ZPI_mouseDY + _dy;
        };
    }];
    _d displayAddEventHandler ["MouseZChanged", {
        params ["_disp", "_z"];
        if (ZPI_camActive && {!visibleMap} && {!dialog} && {!ZPI_tourRunning}) then { [_z] call ZPI_fnc_wheelZoom };
    }];
    addMissionEventHandler ["MapSingleClick", {
        params ["_units", "_pos", "_alt", "_shift"];
        if (_alt) then { [_pos, -1] call ZPI_fnc_setCenter };
    }];
};
