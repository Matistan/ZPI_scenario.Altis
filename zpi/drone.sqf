// =====================================================================
//  ZPI scene pack - camera (free-fly + drone orbit), FOV, per-frame loop,
//  telemetry and ground-truth logging, frame-number bar
//
//  The camera pose is set directly every frame (setPosASL +
//  setVectorDirAndUp). The earlier version used camSetTarget/camCommit
//  plus a closed-loop FOV controller, which made the view jitter.
// =====================================================================

ZPI_camMode     = "free";  // "free" (fly yourself) | "drone" (scripted orbit)
ZPI_orbitAngle  = 0;       // compass bearing of the drone as seen from the center, deg
ZPI_orbitPaused = false;
ZPI_lastTime    = 0;
ZPI_lastTick    = 0;
ZPI_gimbalModes = ["track", "scan", "nadir"];
ZPI_gimbalIndex = 0;
ZPI_camActive   = false;
ZPI_frozen      = false;   // true while a capture is being taken
ZPI_camLock     = false;   // camera pose held still (explosion reference shots, orthophoto)
ZPI_fovLock     = false;   // zoom held still (explosion reference shots)

// laser rangefinder: first surface in the middle of the screen
ZPI_laserRange  = -1;      // m, -1 = nothing hit (sky)
ZPI_laserPos    = [];      // ASL
ZPI_laserObj    = "";      // what was hit ("" = terrain)

// constant pixel size (R)
ZPI_scaleLock   = ZPI_cfg_startScaleLock;
ZPI_targetGSD   = ZPI_cfg_targetGSD;

ZPI_hfov        = -1;      // horizontal FOV, deg
ZPI_vfov        = -1;      // vertical FOV, deg

// pose
ZPI_dronePos    = [0, 0, 0];
ZPI_droneDir    = [0, 1, 0];
ZPI_camPosASL   = [0, 0, 0];
ZPI_camDir      = [0, 1, 0];
ZPI_camUp       = [0, 0, 1];

// free camera state
ZPI_yaw         = 0;       // deg, compass
ZPI_pitch       = -30;     // deg, negative = looking down
ZPI_camVel      = [0, 0, 0];
ZPI_mouseDX     = 0;
ZPI_mouseDY     = 0;
ZPI_keysDown    = createHashMap;

// ---- helpers ----------------------------------------------------------------
ZPI_fnc_dirFromYawPitch = {
    params ["_y", "_p"];
    [(sin _y) * (cos _p), (cos _y) * (cos _p), sin _p]
};

ZPI_fnc_upFromYawPitch = {      // camera up vector, no roll
    params ["_y", "_p"];
    [-(sin _y) * (sin _p), -(cos _y) * (sin _p), cos _p]
};

ZPI_fnc_upFromDir = {           // no-roll up vector for an arbitrary view direction
    params ["_dir", ["_fallbackFwd", [0, 1, 0]]];
    private _right = _dir vectorCrossProduct [0, 0, 1];
    if ((vectorMagnitude _right) < 0.001) then { _right = _dir vectorCrossProduct _fallbackFwd };
    vectorNormalized (_right vectorCrossProduct _dir)
};

ZPI_fnc_applyCamPose = {
    ZPI_cam setPosASL ZPI_camPosASL;
    ZPI_cam setVectorDirAndUp [ZPI_camDir, ZPI_camUp];
};

// ---- drone -----------------------------------------------------------------
ZPI_fnc_createDrone = {
    private _cls = ([["B_UAV_02_dynamicLoadout_F", "B_UAV_02_F"]] call ZPI_fnc_validClasses) param [0, "B_UAV_02_F"];
    ZPI_drone = createVehicle [_cls, [0, 0, 1000], [], 0, "FLY"];
    ZPI_drone allowDamage false;
    ZPI_drone enableSimulation false;
    // reconnaissance only: strip every pylon
    { ZPI_drone setPylonLoadout [_forEachIndex + 1, ""] } forEach (getPylonMagazines ZPI_drone);
    call ZPI_fnc_updateDrone;
};

ZPI_fnc_updateDrone = {
    private _c  = ZPI_center;
    private _gz = getTerrainHeightASL _c;
    private _a  = ZPI_orbitAngle;
    private _r  = ZPI_cfg_orbitRadius;
    private _v  = ZPI_cfg_orbitSpeed;

    private _pos = [(_c select 0) + _r * (sin _a), (_c select 1) + _r * (cos _a), _gz + ZPI_cfg_orbitAlt];
    _pos set [2, (_pos select 2) max ((getTerrainHeightASL _pos) + 100)];

    private _dir      = [cos _a, -(sin _a), 0];                 // clockwise tangent
    private _toCenter = [-(sin _a), -(cos _a), 0];
    private _bank     = atan ((_v * _v) / (_r * 9.81));
    private _up       = ([0, 0, 1] vectorMultiply (cos _bank)) vectorAdd (_toCenter vectorMultiply (sin _bank));

    ZPI_drone setPosASL _pos;
    ZPI_drone setVectorDirAndUp [_dir, _up];
    ZPI_dronePos = _pos;
    ZPI_droneDir = _dir;
};

ZPI_fnc_gimbalTarget = {          // -> PositionASL the drone camera looks at
    private _c  = ZPI_center;
    switch (ZPI_gimbalModes select ZPI_gimbalIndex) do {
        case "scan": {
            private _s = time * ZPI_cfg_scanRate;
            private _p = [(_c select 0) + ZPI_cfg_scanRadius * (sin _s), (_c select 1) + ZPI_cfg_scanRadius * (cos _s)];
            [_p select 0, _p select 1, getTerrainHeightASL _p]
        };
        case "nadir": { ZPI_camPosASL vectorAdd [0, 0, -100] };
        default { [_c select 0, _c select 1, getTerrainHeightASL _c] };
    }
};

ZPI_fnc_updateDroneCam = {
    ZPI_camPosASL = ZPI_dronePos vectorAdd [0, 0, -ZPI_cfg_camBelowDrone];
    ZPI_camDir = vectorNormalized ((call ZPI_fnc_gimbalTarget) vectorDiff ZPI_camPosASL);
    ZPI_camUp  = [ZPI_camDir, ZPI_droneDir] call ZPI_fnc_upFromDir;
    // keep yaw/pitch in sync so switching to free mode starts from the same view
    ZPI_yaw   = (ZPI_camDir select 0) atan2 (ZPI_camDir select 1);
    ZPI_pitch = asin ((ZPI_camDir select 2) max -1 min 1);
};

// ---- free camera ------------------------------------------------------------------
// WASD move, E/Q up/down, Shift = fast, mouse = look, wheel = zoom, arrows = look.
ZPI_fnc_keyHeld = { params ["_dik"]; ZPI_keysDown getOrDefault [_dik, false] };

ZPI_fnc_updateFreeCam = {
    params ["_dt"];
    private _fovScale = (ZPI_hfov / 60) max 0.03;

    // look: mouse deltas + arrow keys, scaled by FOV so zoomed views stay controllable
    private _sens = ZPI_cfg_mouseSens * _fovScale;
    ZPI_yaw   = ZPI_yaw + ZPI_mouseDX * _sens;
    ZPI_pitch = ZPI_pitch - ZPI_mouseDY * _sens;
    ZPI_mouseDX = 0; ZPI_mouseDY = 0;
    private _rate = ZPI_cfg_keyLookRate * _fovScale * _dt;
    if ([203] call ZPI_fnc_keyHeld) then { ZPI_yaw = ZPI_yaw - _rate };
    if ([205] call ZPI_fnc_keyHeld) then { ZPI_yaw = ZPI_yaw + _rate };
    if ([200] call ZPI_fnc_keyHeld) then { ZPI_pitch = ZPI_pitch + _rate };
    if ([208] call ZPI_fnc_keyHeld) then { ZPI_pitch = ZPI_pitch - _rate };
    ZPI_yaw   = (ZPI_yaw + 360) mod 360;
    ZPI_pitch = (ZPI_pitch max -89.5) min 89.5;

    // move: input in (right, forward, up), speed grows with height above ground
    private _in = [0, 0, 0];
    if ([17] call ZPI_fnc_keyHeld) then { _in set [1, (_in select 1) + 1] };   // W
    if ([31] call ZPI_fnc_keyHeld) then { _in set [1, (_in select 1) - 1] };   // S
    if ([32] call ZPI_fnc_keyHeld) then { _in set [0, (_in select 0) + 1] };   // D
    if ([30] call ZPI_fnc_keyHeld) then { _in set [0, (_in select 0) - 1] };   // A
    if ([18] call ZPI_fnc_keyHeld) then { _in set [2, (_in select 2) + 1] };   // E
    if ([16] call ZPI_fnc_keyHeld) then { _in set [2, (_in select 2) - 1] };   // Q
    private _ground = (getTerrainHeightASL ZPI_camPosASL) max 0;
    private _agl = (ZPI_camPosASL select 2) - _ground;
    private _fast = ([42] call ZPI_fnc_keyHeld) || {[54] call ZPI_fnc_keyHeld};
    private _speed = (((_agl * 0.5) max ZPI_cfg_freeMinSpeed) min ZPI_cfg_freeMaxSpeed) * ([1, ZPI_cfg_freeFastMul] select _fast);
    private _fwd   = [sin ZPI_yaw, cos ZPI_yaw, 0];
    private _right = [cos ZPI_yaw, -(sin ZPI_yaw), 0];
    private _vWant = ((_fwd vectorMultiply (_in select 1)) vectorAdd (_right vectorMultiply (_in select 0))) vectorMultiply _speed;
    _vWant set [2, (_in select 2) * _speed * 0.6];
    // exponential smoothing = no sudden starts/stops
    ZPI_camVel = ZPI_camVel vectorAdd ((_vWant vectorDiff ZPI_camVel) vectorMultiply (1 - exp (-ZPI_cfg_freeSmoothing * _dt)));
    private _p = ZPI_camPosASL vectorAdd (ZPI_camVel vectorMultiply _dt);
    _p set [2, (_p select 2) max (((getTerrainHeightASL _p) max 0) + 2)];

    ZPI_camPosASL = _p;
    ZPI_camDir = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_dirFromYawPitch;
    ZPI_camUp  = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_upFromYawPitch;
};

// First surface (ground, building, tree) in the middle of the screen, ASL; [] when looking at the sky.
ZPI_fnc_lookPoint = {
    private _hits = lineIntersectsSurfaces [ZPI_camPosASL, ZPI_camPosASL vectorAdd (ZPI_camDir vectorMultiply 8000),
        ZPI_drone, objNull, true, 1, "GEOM", "NONE"];
    if (_hits isEqualTo []) exitWith { [] };
    (_hits select 0) select 0
};

ZPI_fnc_centerInView = {
    private _c = ZPI_center;
    (ZPI_camPosASL distance2D _c) < 2500 && {(worldToScreen [_c select 0, _c select 1, 2]) isNotEqualTo []}
};

// Free camera: jump to a viewpoint looking at the scene center.
// _force = false: only when the scene is out of view or far away.
ZPI_fnc_viewScene = {
    params [["_force", false]];
    if (ZPI_camMode != "free" || {!ZPI_camActive}) exitWith {};
    if (!_force && {call ZPI_fnc_centerInView}) exitWith {};
    private _c  = ZPI_center;
    private _gz = getTerrainHeightASL _c;
    private _bear = if ((ZPI_camPosASL distance2D _c) > 1) then { ZPI_camPosASL getDir _c } else { ZPI_yaw };
    private _p = _c getPos [ZPI_cfg_viewDist, _bear + 180];
    ZPI_camPosASL = [_p select 0, _p select 1, (_gz + ZPI_cfg_viewHeight) max ((getTerrainHeightASL _p) + 50)];
    private _dir = vectorNormalized ([_c select 0, _c select 1, _gz] vectorDiff ZPI_camPosASL);
    ZPI_yaw   = (_dir select 0) atan2 (_dir select 1);
    ZPI_pitch = asin (_dir select 2);
    ZPI_camDir = _dir;
    ZPI_camUp  = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_upFromYawPitch;
    ZPI_camVel = [0, 0, 0];
    call ZPI_fnc_applyCamPose;
};

ZPI_fnc_setCamMode = {
    params ["_mode"];
    ZPI_camMode = _mode;
    ZPI_camVel = [0, 0, 0];
    ["cam_mode", format ['{"mode":"%1"}', _mode]] call ZPI_fnc_event;
    [format ["Camera: %1", _mode]] call ZPI_fnc_msg;
};

// ---- camera object ------------------------------------------------------------
ZPI_fnc_createCamera = {
    call ZPI_fnc_updateDroneCam;
    ZPI_cam = "camera" camCreate (ASLToAGL ZPI_camPosASL);
    [ZPI_cfg_startFov] call ZPI_fnc_setFov;
    [true] call ZPI_fnc_setCamActive;
};

ZPI_fnc_setCamActive = {
    params ["_on"];
    if (_on) then {
        showCinemaBorder false;
        ZPI_cam cameraEffect ["internal", "back"];
        cameraEffectEnableHUD false;
        ZPI_camActive = true;
        if (ZPI_cfg_frameCode) then { call ZPI_fnc_showFrameCode };
        if (!ZPI_quiet) then { call ZPI_fnc_showHud };
    } else {
        ZPI_cam cameraEffect ["terminate", "back"];
        call ZPI_fnc_hideFrameCode;
        call ZPI_fnc_hideHud;
    };
    ZPI_camActive = _on;
};

// ---- FOV ---------------------------------------------------------------------------
// camSetFov takes Arma's fovTop: zoom = 4/3 * tan(hfov/2) / AR, and vfov follows from square pixels.
ZPI_fnc_setFov = {
    params ["_deg"];
    ZPI_hfov = (_deg max 0.5) min 100;
    private _res = getResolution;
    private _ar = (_res select 0) / (_res select 1);
    ZPI_vfov = 2 * atan ((tan (ZPI_hfov / 2)) / _ar);
    private _zoom = (4 / 3) * (tan (ZPI_hfov / 2)) / _ar;
    ZPI_cam camSetFov _zoom;
    ZPI_cam camCommit 0;
    call ZPI_fnc_applyCamPose;
};

ZPI_fnc_zoomStep = {              // +1 = zoom in (narrower FOV), presets
    params ["_step"];
    if (ZPI_fovLock) exitWith {};
    if (ZPI_scaleLock) exitWith { [ZPI_targetGSD * ([1.25, 0.8] select (_step > 0))] call ZPI_fnc_setGSD };
    // continue from the nearest preset to the current FOV
    private _i = 0; private _best = 1e9;
    { if (abs (_x - ZPI_hfov) < _best) then { _best = abs (_x - ZPI_hfov); _i = _forEachIndex } } forEach ZPI_cfg_fovPresets;
    private _next = ((_i + _step) max 0) min (count ZPI_cfg_fovPresets - 1);
    [ZPI_cfg_fovPresets select _next] call ZPI_fnc_setFov;
    ["fov", format ['{"hfov_deg":%1}', ZPI_hfov]] call ZPI_fnc_event;
    [format ["FOV %1 deg", ZPI_hfov]] call ZPI_fnc_msg;
};

ZPI_fnc_wheelZoom = {             // smooth zoom with the mouse wheel
    params ["_z"];
    if (ZPI_fovLock) exitWith {};
    if (ZPI_scaleLock) exitWith { [ZPI_targetGSD * (ZPI_cfg_wheelStep ^ _z)] call ZPI_fnc_setGSD };
    [ZPI_hfov * (ZPI_cfg_wheelStep ^ _z)] call ZPI_fnc_setFov;
};

// ---- frame-number bar (image <-> telemetry sync) --------------------------
// 2 sentinel squares (white, black) + 24 data bits, LSB first, 8x8 px each,
// starting 4 px from the top-left corner. Decoder: tools/frame_code.py
// Note: the screenshot command does not capture UI, so the bar is only in
// screen captures (dxcam/OBS), never in screenshots taken with the P key.
ZPI_fnc_showFrameCode = {
    ("ZPI_frameCodeLayer" call BIS_fnc_rscLayer) cutRsc ["ZPI_FrameCode", "PLAIN", 0, false];
};

ZPI_fnc_hideFrameCode = {
    ("ZPI_frameCodeLayer" call BIS_fnc_rscLayer) cutText ["", "PLAIN"];
};

ZPI_fnc_hideHud = {
    ("ZPI_hudLayer" call BIS_fnc_rscLayer) cutText ["", "PLAIN"];
};

ZPI_fnc_showHud = {
    ("ZPI_hudLayer" call BIS_fnc_rscLayer) cutRsc ["ZPI_Hud", "PLAIN", 0, false];
};

ZPI_fnc_updateFrameCode = {
    private _d = uiNamespace getVariable ["ZPI_frameCodeDisplay", displayNull];
    if (isNull _d) exitWith {};
    private _n = diag_frameNo mod 16777216;
    for "_i" from 0 to 23 do {
        private _b = _n mod 2;
        _n = floor (_n / 2);
        (_d displayCtrl (1100 + _i)) ctrlSetBackgroundColor ([[0, 0, 0, 1], [1, 1, 1, 1]] select _b);
    };
};

// ---- camera basis of the frame actually rendered ----------------------------------------
// Axes from points 1 km along each camera axis, then normalized: with 1 m offsets
// (the old method) every component came out as a multiple of 1/1024 (float32 at ~13 km).
ZPI_fnc_camBasis = {            // -> [originASL, right, up, forward] (unit vectors)
    private _o = AGLToASL (positionCameraToWorld [0, 0, 0]);
    private _L = 1000;
    [
        _o,
        vectorNormalized ((AGLToASL (positionCameraToWorld [_L, 0, 0])) vectorDiff _o),
        vectorNormalized ((AGLToASL (positionCameraToWorld [0, _L, 0])) vectorDiff _o),
        vectorNormalized ((AGLToASL (positionCameraToWorld [0, 0, _L])) vectorDiff _o)
    ]
};

// ---- telemetry (JSON contract from the project description, plus extras) ------------
ZPI_fnc_logTelemetry = {
    (call ZPI_fnc_camBasis) params ["_o", "_r", "_u", "_f"];
    private _range = ["null", ZPI_laserRange toFixed 2] select (ZPI_laserRange > 0);
    private _plat = [ZPI_camPosASL, ZPI_dronePos] select (ZPI_camMode == "drone");
    private _res = getResolution;
    ["tel", format [
        '{"frame":%1,"t_game":%2,"t_tick":%3,"camera":{"pos_asl":%4,"x_axis":%5,"y_axis":%6,"z_axis":%7,"hfov_deg":%8,"vfov_deg":%9,"gimbal":"%10","mode":"%19"},"drone":{"pos_asl":%11,"dir":%12},"range_m":%13,"image":{"w":%14,"h":%15},"scene":"%16","seed":%17,"region":%18}',
        diag_frameNo toFixed 0, time toFixed 3, diag_tickTime toFixed 4,
        [_o, 3] call ZPI_fnc_v3, [_r, 7] call ZPI_fnc_v3, [_u, 7] call ZPI_fnc_v3, [_f, 7] call ZPI_fnc_v3,
        ZPI_hfov toFixed 6, ZPI_vfov toFixed 6, ZPI_gimbalModes select ZPI_gimbalIndex,
        [_plat, 2] call ZPI_fnc_v3, [ZPI_droneDir, 4] call ZPI_fnc_v3,
        _range, _res select 0, _res select 1,
        ZPI_sceneName, ZPI_cfg_seed, ZPI_regionId, ZPI_camMode
    ]] call ZPI_fnc_emit;
};

// ---- ground truth ---------------------------------------------------------------
// objs: [id, pos_asl, dir_deg, velocity, stance]; class + bbox are in the "spawn" record.
ZPI_fnc_logGT = {
    if (ZPI_entities isEqualTo []) exitWith {};
    private _items = [];
    {
        _x params ["_id", "_obj"];
        if (!isNull _obj) then {
            private _st = if (_obj isKindOf "Man") then { stance _obj } else { "" };
            _items pushBack format ['[%1,%2,%3,%4,"%5"]',
                _id, [getPosASL _obj, 2] call ZPI_fnc_v3, (getDir _obj) toFixed 1, [velocity _obj, 2] call ZPI_fnc_v3, _st];
        };
    } forEach ZPI_entities;
    private _n = ZPI_cfg_gtMaxPerLine;
    private _parts = ceil ((count _items) / _n);
    for "_k" from 0 to (_parts - 1) do {
        ["gt", format ['{"frame":%1,"t_game":%2,"part":%3,"parts":%4,"objs":[%5]}',
            diag_frameNo toFixed 0, time toFixed 3, _k, _parts, (_items select [_k * _n, _n]) joinString ","]] call ZPI_fnc_emit;
    };
};

// ---- laser rangefinder ---------------------------------------------------------------
ZPI_fnc_updateLaser = {
    private _hits = lineIntersectsSurfaces [ZPI_camPosASL, ZPI_camPosASL vectorAdd (ZPI_camDir vectorMultiply 8000),
        ZPI_drone, objNull, true, 1, "GEOM", "NONE"];
    if (_hits isEqualTo []) exitWith { ZPI_laserRange = -1; ZPI_laserPos = []; ZPI_laserObj = "" };
    private _h = _hits select 0;
    ZPI_laserPos = _h select 0;
    ZPI_laserRange = ZPI_camPosASL vectorDistance ZPI_laserPos;
    private _o = _h select 3;
    if (isNull _o) then { _o = _h select 2 };
    ZPI_laserObj = if (isNull _o) then { "" } else { typeOf _o };
};

// heading (0 = north, clockwise) and pitch (negative = looking down) of the view, deg
ZPI_fnc_attitude = {
    [((ZPI_camDir select 0) atan2 (ZPI_camDir select 1) + 360) mod 360, asin (((ZPI_camDir select 2) max -1) min 1)]
};

// ground sample distance at the laser point, m per screen pixel
ZPI_fnc_gsdNow = {
    if (ZPI_laserRange <= 0) exitWith { -1 };
    2 * ZPI_laserRange * (tan (ZPI_hfov / 2)) / ((getResolution) select 0)
};

// ---- constant pixel size: zoom follows the laser range --------------------------------
ZPI_fnc_setGSD = {
    params ["_g"];
    ZPI_targetGSD = (_g max (ZPI_cfg_gsdLimits select 0)) min (ZPI_cfg_gsdLimits select 1);
    [format ["Scale %1 m/px: soldier ~%2 px tall, tank ~%3 px long", ZPI_targetGSD toFixed 3, round (1.8 / ZPI_targetGSD), round (7 / ZPI_targetGSD)]] call ZPI_fnc_msg;
};

ZPI_fnc_toggleScaleLock = {
    ZPI_scaleLock = !ZPI_scaleLock;
    if (ZPI_scaleLock) then {
        // always the same scale (ZPI_cfg_targetGSD unless changed with the wheel), so all shots match
        [ZPI_targetGSD] call ZPI_fnc_setGSD;
        ["Constant pixel size ON (wheel / PgUp / PgDn change the scale)"] call ZPI_fnc_msg;
    } else {
        ["Constant pixel size OFF"] call ZPI_fnc_msg;
    };
    ["scale_lock", format ['{"on":%1,"gsd":%2}', ZPI_scaleLock, ZPI_targetGSD toFixed 4]] call ZPI_fnc_event;
};

ZPI_fnc_updateScaleLock = {
    params ["_dt"];
    if (!ZPI_scaleLock || {ZPI_fovLock} || {ZPI_laserRange <= 0}) exitWith {};
    private _want = 2 * atan ((ZPI_targetGSD * ((getResolution) select 0)) / (2 * ZPI_laserRange));
    if (abs (_want - ZPI_hfov) / ZPI_hfov < 0.005) exitWith {};
    [ZPI_hfov + (_want - ZPI_hfov) * ((ZPI_cfg_scaleLockRate * _dt) min 1)] call ZPI_fnc_setFov;
};

ZPI_hudExtra = "";                // extra line, e.g. building occupancy
ZPI_hudBld = 0;
ZPI_hudGround = "---";

ZPI_fnc_updateHud = {
    private _d = uiNamespace getVariable ["ZPI_hudDisplay", displayNull];
    if (isNull _d) exitWith {};
    if (ZPI_quiet) exitWith {
        (_d displayCtrl 1200) ctrlSetText "";
        {
            (_d displayCtrl _x) ctrlShow false
        } forEach [1201, 1202, 1203, 1204] };
    {
        (_d displayCtrl _x) ctrlShow true
    } forEach [1201, 1202, 1203, 1204];
    (call ZPI_fnc_attitude) params ["_hdg", "_pitch"];
    private _gz  = (getTerrainHeightASL ZPI_camPosASL) max 0;
    private _alt = ZPI_camPosASL select 2;
    private _nl = toString [10];
    private _range = if (ZPI_laserRange > 0) then {
        format ["LASER %1 m   TGT %2  (%3, %4)  elev %5 m%6", ZPI_laserRange toFixed 1, mapGridPosition [ZPI_laserPos select 0, ZPI_laserPos select 1],
            (ZPI_laserPos select 0) toFixed 0, (ZPI_laserPos select 1) toFixed 0, (ZPI_laserPos select 2) toFixed 1,
            ["", "  [" + ZPI_laserObj + "]"] select (ZPI_laserObj != "")]
    } else { "LASER  --- no return ---" };
    private _gsd = call ZPI_fnc_gsdNow;
    private _scale = if (_gsd > 0) then { format ["GSD %1 m/px  soldier ~%2 px", _gsd toFixed 3, round (1.8 / _gsd)] } else { "GSD ---" };
    private _lock = if (ZPI_scaleLock) then { format ["  SCALE LOCK %1", ZPI_targetGSD toFixed 3] } else { "" };
    private _hold = if (ZPI_camLock) then { "  [CAMERA HELD]" } else { "" };
    // ground type under the crosshair + buildings that would be labelled (every 30 frames)
    if (diag_frameNo % 30 < ZPI_cfg_hudEvery) then {
        ZPI_hudBld = call ZPI_fnc_buildingsInView;
        ZPI_hudGround = if (ZPI_laserRange > 0) then {
            format ["%1 (green %2)", surfaceType ZPI_laserPos, ([ZPI_laserPos] call ZPI_fnc_surfaceGreen) toFixed 1]
        } else { "---" };
    };
    private _txt = _range + _nl
        + format ["ALT %1 m ASL / %2 m AGL   HDG %3   PITCH %4   CAM %5", _alt toFixed 0, (_alt - _gz) toFixed 0, _hdg toFixed 1, _pitch toFixed 1, mapGridPosition [ZPI_camPosASL select 0, ZPI_camPosASL select 1]] + _nl
        + format ["FOV %1 deg   %2%3%4", ZPI_hfov toFixed 2, _scale, _lock, _hold] + _nl
        + format ["GROUND %1   BUILDINGS IN VIEW %2%3", ZPI_hudGround, ZPI_hudBld, ["", " (too many for the generator)"] select (ZPI_hudBld > ZPI_cfg_maxBuildings)]
        + (["", _nl + ZPI_hudExtra] select (ZPI_hudExtra != ""));
    (_d displayCtrl 1200) ctrlSetText _txt;
};

// ---- per-frame loop -------------------------------------------------------------
ZPI_fnc_onFrame = {
    if (isGamePaused) exitWith { ZPI_lastTick = diag_tickTime };
    private _dt = time - ZPI_lastTime;
    ZPI_lastTime = time;
    private _rdt = ((diag_tickTime - ZPI_lastTick) max 0) min 0.1;   // real time, for the free camera
    ZPI_lastTick = diag_tickTime;

    if (!ZPI_frozen && {!ZPI_camLock}) then {
        if (!ZPI_orbitPaused) then {
            ZPI_orbitAngle = (ZPI_orbitAngle + (ZPI_cfg_orbitSpeed / ZPI_cfg_orbitRadius) * _dt * (180 / pi)) mod 360;
        };
        call ZPI_fnc_updateDrone;
        if (ZPI_camActive) then {
            if (ZPI_camMode == "drone") then {
                call ZPI_fnc_updateDroneCam
            } else {
                [_rdt] call ZPI_fnc_updateFreeCam;
            };
            call ZPI_fnc_applyCamPose;
        };
    };
    if (!ZPI_camActive) exitWith {
        if (ZPI_cfg_gtEvery > 0 && {diag_frameNo % ZPI_cfg_gtEvery == 0}) then {
            call ZPI_fnc_logGT;
        };
    };
    call ZPI_fnc_updateLaser;
    [_rdt] call ZPI_fnc_updateScaleLock;
    call ZPI_fnc_captureTick;
    call ZPI_fnc_buildingTick;
    if (ZPI_cfg_hud && {diag_frameNo % ZPI_cfg_hudEvery == 0}) then {
        call ZPI_fnc_updateHud;
    };
    ZPI_drone hideObject (ZPI_camMode == "free");        // the airframe only belongs in drone mode
    if (ZPI_cfg_frameCode) then {
        call ZPI_fnc_updateFrameCode;
    };
    if (ZPI_cfg_telemetryEvery > 0 && {diag_frameNo % ZPI_cfg_telemetryEvery == 0}) then {
        call ZPI_fnc_logTelemetry;
    };
    if (ZPI_cfg_gtEvery > 0 && {diag_frameNo % ZPI_cfg_gtEvery == 0}) then {
        call ZPI_fnc_logGT;
    };
};
