/**
 * Copyright - xWhitey, 2024.
 * Ropes.as - hangin' on ropes with bruddas while completing teh pro op4 boot camp yea
 *
 * HLC's a.k.a. 'Half-Life C's' (the C stands for Cancer) (Sven Co-op server) source file
 * Authors: xWhitey, Gearbox, FWGS. Refer to further comment blocks for some explanation and OG code authors (if any).
 * Do not delete this comment block. Respect others' work!
 */

//Uses https://github.com/FWGS/hlsdk-portable/blob/opforfixed/dlls/gearbox/ropes.h as base for classes. Author: Gearbox, FWGS.
//Uses https://github.com/FWGS/hlsdk-portable/blob/opforfixed/dlls/gearbox/ropes.cpp as base for the code of methods of the classes. Author: Gearbox, FWGS.
//Refers some stuff from https://github.com/twhl-community/halflife-op4-updated/blob/master/dlls/rope/CRope.cpp. Author: Gearbox, TWHL.
//Refers some code from https://github.com/autisoid/SC-ZombiePlague/blob/master/scripts/plugins/ZombieMod.as. Author: xWhitey (me, the creator of port), Half-Life Community.

/**
*   @brief The framerate that the rope aims to run at.
*   Clamping simulation to this also fixes ropes being invisible in multiplayer.
*/
float RopeFrameRate = 60.f;

CCVar@ g_pConVarPlayerForce;

const size_t MAX_SEGMENTS = 63;
const size_t MAX_SAMPLES = 64;

const float SPRING_DAMPING = 0.04f;
const size_t ROPE_IGNORE_SAMPLES = 2;   // integrator may be hanging if less than

void TruncateEpsilon(Vector& in _In, Vector& out _Out) {
    Vector vec1 =  _In * 10.0;
    vec1.x += 0.5;
    _Out = vec1 / 10;
}

const Vector DOWN(0, 0, -1);

const Vector RIGHT(0, 1, 0);

float g_M_PI = 3.14159265358979323846f;

void GetAlignmentAngles(const Vector& in _Top, const Vector& in _Bottom, Vector& out _Out) {
    Vector vecDist = _Bottom - _Top;

    Vector vecResult = vecDist.Normalize();

    const float flRoll = acos(DotProduct(vecResult, RIGHT)) * (180.0 / g_M_PI);

    _Out.z = -flRoll;

    vecDist.y = 0;

    vecResult = vecDist.Normalize();

    const float flPitch = acos(DotProduct(vecResult, DOWN)) * (180.0 / g_M_PI);

    _Out.x = (vecResult.x >= 0.0) ? flPitch : -flPitch;
    _Out.y = 0;
}

/**
*   Data for a single rope joint.
*/
class CRopeSampleData{
    Vector m_vecPosition; //Size: 0x000C, offset: 0x0000
    Vector m_vecVelocity; //Size: 0x000C, offset: 0x0018
    Vector m_vecForce; //Size: 0x000C, offset: 0x0024
    Vector m_vecExternalForce; //Size: 0x000C, offset: 0x0030

    bool m_bApplyExternalForce; //Size: 0x0001, offset: 0x003C
    float m_flMassReciprocal; //Size: 0x0004, offset: 0x003D
    float m_flRestLength; //Size: 0x0004, offset: 0x0041
    
    //gpt4o1-preview addition
    Vector m_vecOldPosition; //Size: 0x000C, offset: 0x0045
}; //Size: 0x0057
//static_assert(sizeof(CRopeSampleData) == 0x0057)

const size_t MAX_LIST_SEGMENTS = 5;
array<array<CRopeSampleData@>> g_pTempList;//[MAX_LIST_SEGMENTS][MAX_SEGMENTS];

void InitialiseTempList() {
    g_pTempList.resize(MAX_LIST_SEGMENTS);
    
    for (int idx = 0; idx < MAX_LIST_SEGMENTS; idx++) {
        array<CRopeSampleData@>@ pList = @g_pTempList[idx];
        g_pTempList[idx].resize(MAX_SEGMENTS);
        for (int j = 0; j < MAX_SEGMENTS; j++) {
            @pList[j] = CRopeSampleData();
        }
    }
}

array<bool> g_rgbIsOnRope;
array<CRope@> g_rglpMasterRopes;
array<bool> g_rgbIsClimbing;
array<float> g_rgflLastClimbTime;

void PluginInit() {
    g_Module.ScriptInfo.SetAuthor("xWhitey");
    g_Module.ScriptInfo.SetContactInfo("tyabus @ Discord");
    
    @g_pConVarPlayerForce = CCVar("sv_ropes_player_force", "750", "Player force amount", ConCommandFlag::AdminOnly);
    
    g_rgbIsOnRope.resize(0);
    g_rgbIsOnRope.resize(33);
    g_rglpMasterRopes.resize(0);
    g_rglpMasterRopes.resize(33);
    g_rgbIsClimbing.resize(0);
    g_rgbIsClimbing.resize(33);
    g_rgflLastClimbTime.resize(0);
    g_rgflLastClimbTime.resize(33);
    
    if (RopeFrameRate <= 0.f) {
        RopeFrameRate = 60.f;
        g_Log.PrintF("[Ropes] RopeFrameRate is invalid! We've set it to 60.\n");
    }
    
    g_Hooks.RegisterHook(Hooks::Player::PlayerPreThink, @HOOKED_PlayerPreThink);
}

HookReturnCode HOOKED_PlayerPreThink(CBasePlayer@ _Player, uint& out _Flags) {
    int nPlayerIdx = _Player.entindex();
    if (!g_rgbIsOnRope[nPlayerIdx]) return HOOK_CONTINUE;
    if (g_rglpMasterRopes[nPlayerIdx] is null) {
        g_rgbIsOnRope[nPlayerIdx] = false;
        g_rgbIsClimbing[nPlayerIdx] = false;
        return HOOK_CONTINUE;
    }
    CRope@ pRope = g_rglpMasterRopes[nPlayerIdx];
    if (!_Player.IsAlive() || !_Player.IsConnected()) {
        if (pRope !is null) {
            pRope.DetachObject();
            _Player.UnblockWeapons(pRope.GetSelf());
            @g_rglpMasterRopes[nPlayerIdx] = null;
        }
        g_rgbIsOnRope[nPlayerIdx] = false;
        g_rgbIsClimbing[nPlayerIdx] = false;
        
        return HOOK_CONTINUE;
    }
            
    Observer@ pObserver = _Player.GetObserver();
    if (pObserver !is null) {
        if (pObserver.IsObserver()) {
            if (pRope !is null) {
                pRope.DetachObject();
                _Player.UnblockWeapons(pRope.GetSelf());
                @g_rglpMasterRopes[nPlayerIdx] = null;
            }
            g_rgbIsOnRope[nPlayerIdx] = false;
            g_rgbIsClimbing[nPlayerIdx] = false;
        
            return HOOK_CONTINUE;
        }
    }
    
    Math.MakeVectors(_Player.pev.v_angle);
    
    _Player.BlockWeapons(pRope.GetSelf());
    
    _Player.pev.velocity = g_vecZero;

    const Vector vecAttachPos = pRope.GetAttachedObjectsPosition();

    _Player.pev.origin = vecAttachPos;

    Vector vecForce;

    if ((_Player.pev.button & IN_MOVERIGHT) != 0) {
        vecForce.x = g_Engine.v_right.x;
        vecForce.y = g_Engine.v_right.y;
        vecForce.z = 0;

        pRope.ApplyForceFromPlayer(vecForce);
    }

    if ((_Player.pev.button & IN_MOVELEFT) != 0) {
        vecForce.x = -g_Engine.v_right.x;
        vecForce.y = -g_Engine.v_right.y;
        vecForce.z = 0;
        pRope.ApplyForceFromPlayer(vecForce);
    }

    //Determine if any force should be applied to the rope, or if we should move around. - Solokiller
    if ((_Player.pev.button & (IN_BACK | IN_FORWARD)) != 0) {
        if ((g_Engine.v_forward.x * g_Engine.v_forward.x +
            g_Engine.v_forward.y * g_Engine.v_forward.y -
            g_Engine.v_forward.z * g_Engine.v_forward.z) <= 0) {
            if (g_rgbIsClimbing[nPlayerIdx]) {
                const float flDelta = g_Engine.time - g_rgflLastClimbTime[nPlayerIdx];
                g_rgflLastClimbTime[nPlayerIdx] = g_Engine.time;

                if ((_Player.pev.button & IN_FORWARD) != 0) {
                    if (g_Engine.v_forward.z < 0.0) {
                        if (!pRope.MoveDown(flDelta)) {
                            //Let go of the rope, detach. - Solokiller
                            _Player.UnblockWeapons(pRope.GetSelf());
                            _Player.pev.movetype = MOVETYPE_WALK;
                            _Player.pev.solid = SOLID_SLIDEBOX;

                            pRope.DetachObject();
                            @g_rglpMasterRopes[nPlayerIdx] = null;
                            g_rgbIsClimbing[nPlayerIdx] = false;
                            g_rgbIsOnRope[nPlayerIdx] = false;
                        }
                    } else {
                        pRope.MoveUp(flDelta);
                    }
                }
                if ((_Player.pev.button & IN_BACK) != 0) {
                    if (g_Engine.v_forward.z < 0.0) {
                        pRope.MoveUp(flDelta);
                    } else if (!pRope.MoveDown(flDelta)) {
                        //Let go of the rope, detach. - Solokiller
                        _Player.UnblockWeapons(pRope.GetSelf());
                        _Player.pev.movetype = MOVETYPE_WALK;
                        _Player.pev.solid = SOLID_SLIDEBOX;
                        pRope.DetachObject();
                        @g_rglpMasterRopes[nPlayerIdx] = null;
                        g_rgbIsClimbing[nPlayerIdx] = false;
                        g_rgbIsOnRope[nPlayerIdx] = false;
                    }
                }
            } else {
                g_rgbIsClimbing[nPlayerIdx] = true;
                g_rgflLastClimbTime[nPlayerIdx] = g_Engine.time;
            }
        } else {
            vecForce.x = g_Engine.v_forward.x;
            vecForce.y = g_Engine.v_forward.y;
            vecForce.z = 0.0;
            if ((_Player.pev.button & IN_BACK) != 0) {
                vecForce.x = -g_Engine.v_forward.x;
                vecForce.y = -g_Engine.v_forward.y;
                vecForce.z = 0;
            }
            pRope.ApplyForceFromPlayer(vecForce);
            g_rgbIsClimbing[nPlayerIdx] = false;
        }
    } else {
        g_rgbIsClimbing[nPlayerIdx] = false;
    }

    if ((_Player.m_afButtonPressed & IN_JUMP) != 0) {
        //We've jumped off the rope, give us some momentum - Solokiller
        _Player.UnblockWeapons(pRope.GetSelf());
        _Player.pev.movetype = MOVETYPE_WALK;
        _Player.pev.solid = SOLID_SLIDEBOX;
        g_rgbIsOnRope[nPlayerIdx] = false;

        Vector vecDir = g_Engine.v_up * 165.0 + g_Engine.v_forward * 150.0;

        Vector vecVelocity = pRope.GetAttachedObjectsVelocity() * 2;

        vecVelocity = vecVelocity.Normalize();

        vecVelocity = vecVelocity * 200;

        _Player.pev.velocity = vecVelocity + vecDir;

        pRope.DetachObject();
        @g_rglpMasterRopes[nPlayerIdx] = null;
        g_rgbIsClimbing[nPlayerIdx] = false;
    }
    
    return HOOK_CONTINUE;
}

bool RegisterStuff() {
    if (g_CustomEntityFuncs.IsCustomEntity("env_rope")) {
        g_CustomEntityFuncs.UnRegisterCustomEntity("env_rope");
    }
    if (g_CustomEntityFuncs.IsCustomEntity("rope_sample")) {
        g_CustomEntityFuncs.UnRegisterCustomEntity("rope_sample");
    }
    if (g_CustomEntityFuncs.IsCustomEntity("rope_segment")) {
        g_CustomEntityFuncs.UnRegisterCustomEntity("rope_segment");
    }
    if (g_CustomEntityFuncs.IsCustomEntity("env_electrified_wire")) {
        g_CustomEntityFuncs.UnRegisterCustomEntity("env_electrified_wire");
    }

    g_CustomEntityFuncs.RegisterCustomEntity("CRope", "env_rope");
    g_CustomEntityFuncs.RegisterCustomEntity("CRopeSample", "rope_sample");
    g_CustomEntityFuncs.RegisterCustomEntity("CRopeSegment", "rope_segment");
    g_CustomEntityFuncs.RegisterCustomEntity("CElectrifiedWire", "env_electrified_wire");
    
    return g_CustomEntityFuncs.IsCustomEntity("env_rope") && g_CustomEntityFuncs.IsCustomEntity("rope_sample") && g_CustomEntityFuncs.IsCustomEntity("rope_segment") && g_CustomEntityFuncs.IsCustomEntity("env_electrified_wire");
}

void MapInit() {
    g_rgbIsOnRope.resize(0);
    g_rgbIsOnRope.resize(33);
    g_rglpMasterRopes.resize(0);
    g_rglpMasterRopes.resize(33);
    g_rgbIsClimbing.resize(0);
    g_rgbIsClimbing.resize(33);
    g_rgflLastClimbTime.resize(0);
    g_rgflLastClimbTime.resize(33);
    InitialiseTempList();
    
    if (!RegisterStuff()) {
        g_Log.PrintF("[Ropes] RegisterStuff failed!\n");
    }
}

array<string> g_pszCreakSounds =
{
    "hlcancer/op4/rope/rope1.wav",
    "hlcancer/op4/rope/rope2.wav",
    "hlcancer/op4/rope/rope3.wav"
};

/**
*   Represents a single joint in a rope. There are numSegments + 1 samples in a rope.
*/
class CRopeSample : ScriptBaseEntity {
    CRopeSample() {
        @m_pData = CRopeSampleData();
    }

    CBaseEntity@ GetSelf() {
        return self;
    }
    
    void Spawn() {
        self.pev.effects |= EF_NODRAW;
    }
    
    //static CRopeSample* CreateSample(); //Moved to UTIL_CreateSample

    CRopeSampleData@ GetData() {
        return @m_pData;
    }

    CRopeSampleData@ m_pData; //Size: 0x0004, offset: 0x0000
}; //Size: 0x0004
//static_assert(sizeof(CRopeSample) == 0x0004)

class CRopeSegment : ScriptBaseAnimating {
    CBaseEntity@ GetSelf() {
        return self;
    }

    void Precache() {
        BaseClass.Precache();
        if (m_lpszModelName.IsEmpty())
            m_lpszModelName = "models/rope16.mdl";

        g_Game.PrecacheModel(m_lpszModelName);
        g_Game.PrecacheOther("sound/hlcancer/op4/rope/grab_rope.wav");
        g_SoundSystem.PrecacheSound("hlcancer/op4/rope/grab_rope.wav");
    }

    void Spawn() {
        Precache();

        g_EntityFuncs.SetModel(self, m_lpszModelName);

        self.pev.movetype = MOVETYPE_NOCLIP;
        self.pev.solid = SOLID_TRIGGER;
        self.pev.effects = EF_NODRAW;
        SetAbsOrigin(self.pev.origin);

        g_EntityFuncs.SetSize(self.pev, Vector(-30.f, -30.f, -30.f), Vector(30.f, 30.f, 30.f));

        self.pev.nextthink = g_Engine.time + 0.5f;
    }

    void Touch(CBaseEntity@ _Toucher) {
        if (_Toucher.IsPlayer() && _Toucher.IsAlive()) {
            CBasePlayer@ pPlayer = cast<CBasePlayer@>(_Toucher);
            
            Observer@ pObserver = pPlayer.GetObserver();
            if (pObserver !is null) {
                if (pObserver.IsObserver())
                    return;
            }

            //Electrified wires deal damage. - Solokiller
            if (m_bCauseDamage) {
                // Like trigger_hurt we need to deal half a second's worth of damage per touch to make this frametime-independent.
                if (m_flLastDamageTime < g_Engine.time) {
                    // 1 damage per tick is 30 damage per second at 30 FPS.
                    float flDamagePerHalfSecond = 30.f / 2.f;
                    _Toucher.TakeDamage(self.pev, self.pev, flDamagePerHalfSecond, DMG_SHOCK);
                    m_flLastDamageTime = g_Engine.time + 0.5f;
                }
            }

            if (GetMasterRope().IsAcceptingAttachment() && !g_rgbIsOnRope[pPlayer.entindex()]) {
                if (m_bCanBeGrabbed) {
                    CRopeSampleData@ data = m_pSample.GetData();

                    g_EntityFuncs.SetOrigin(_Toucher, data.m_vecPosition);

                    int nPlayerIdx = pPlayer.entindex();
                    @g_rglpMasterRopes[nPlayerIdx] = GetMasterRope();
                    g_rgbIsOnRope[nPlayerIdx] = true;
                    pPlayer.pev.movetype = MOVETYPE_FLY;
                    GetMasterRope().AttachObjectToSegment(@this);

                    if (_Toucher.pev.velocity.Length() >= 320.f) {
                        //Apply some external force to move the rope. - Solokiller
                        data.m_bApplyExternalForce = true;

                        data.m_vecExternalForce = data.m_vecExternalForce + _Toucher.pev.velocity * 550.f;
                    }

                    if (GetMasterRope().IsSoundAllowed()) {
                        g_SoundSystem.EmitSound(self.edict(), CHAN_BODY, "hlcancer/op4/rope/grab_rope.wav", 1.0, ATTN_NORM);
                    }
                } else {
                    //This segment cannot be grabbed, so grab the highest one if possible. - Solokiller
                    CRope@ pRope = GetMasterRope();

                    CRopeSegment@ pSegment;

                    if (pRope.GetNumSegments() <= ROPE_IGNORE_SAMPLES) {
                        //Fewer than ROPE_IGNORE_SAMPLES segments exist, so allow grabbing the last one. - Solokiller
                        @pSegment = pRope.GetSegments()[pRope.GetNumSegments() - 1];
                        pSegment.SetCanBeGrabbed(true);
                    } else {
                        @pSegment = pRope.GetSegments()[ROPE_IGNORE_SAMPLES];
                    }

                    pSegment.Touch(@_Toucher);
                }
            }
        }
    }

    void SetAbsOrigin(const Vector& in _Position) {
        self.pev.origin = _Position;
    }

    //static CRopeSegment* CreateSegment(CRopeSample* pSample, string_t iszModelName , CRope *rope); //Moved to UTIL_CreateSegment

    CRopeSample@ GetSample() { return m_pSample; }

    void ApplyExternalForce(const Vector& in _Force) {
        m_pSample.GetData().m_bApplyExternalForce = true;

        m_pSample.GetData().m_vecExternalForce = m_pSample.GetData().m_vecExternalForce + _Force;
    }

    void SetCauseDamageOnTouch(const bool _CauseDamage) { m_bCauseDamage = _CauseDamage; }
    void SetCanBeGrabbed(const bool _CanBeGrabbed) { m_bCanBeGrabbed = _CanBeGrabbed; }
    CRope@ GetMasterRope() { return m_pMasterRope; }
    void SetMasterRope(CRope@ _Rope) {
        @m_pMasterRope = _Rope;
    }

    CRopeSample@ m_pSample; //Size: 0x0004, offset: 0x0000
    string m_lpszModelName; //Original type: string_t, mapped to string. //Size: 0x0008, offset: 0x0004
    float m_flDefaultMass; //Size: 0x0004, offset: 0x000C
    bool m_bCauseDamage; //Size: 0x0001, offset: 0x0010
    bool m_bCanBeGrabbed; //Size: 0x0001, offset: 0x0011
    CRope@ m_pMasterRope; //Size: 0x0004, offset: 0x0012
    float m_flLastDamageTime;
}; //Size: 0x0016
//static_assert(sizeof(CRopeSegment) == 0x0016)

CRopeSegment@ UTIL_CreateSegment(CRopeSample@ _Sample, string _ModelName, CRope@ _Rope) {
    CBaseEntity@ pEntity = g_EntityFuncs.Create("rope_segment", g_vecZero, g_vecZero, true, null);
    g_EntityFuncs.DispatchSpawn(pEntity.edict());
    CRopeSegment@ pSegment = cast<CRopeSegment@>(CastToScriptClass(pEntity));

    pSegment.m_lpszModelName = _ModelName;

    pSegment.Spawn();

    @pSegment.m_pSample = _Sample;

    pSegment.m_bCauseDamage = false;
    pSegment.m_bCanBeGrabbed = true;
    pSegment.m_flDefaultMass = _Sample.GetData().m_flMassReciprocal;
    pSegment.SetMasterRope(_Rope);

    return pSegment;
}

CRopeSample@ UTIL_CreateSample() {
    CBaseEntity@ pEntity = g_EntityFuncs.Create("rope_sample", g_vecZero, g_vecZero, true, null);
    g_EntityFuncs.DispatchSpawn(pEntity.edict());
    CRopeSample@ pSample = cast<CRopeSample@>(CastToScriptClass(pEntity));

    pSample.Spawn();

    return pSample;
}

/**
*   A rope with a number of segments.
*   Uses a Verlet integrator with dampened springs to simulate rope physics.
*/
class CRope : ScriptBaseAnimating {
    CRope() {
        m_lpszBodyModel = "models/rope16.mdl";
        m_lpszEndingModel = "models/rope16.mdl";
        seg = array<CRopeSegment@>(MAX_SEGMENTS, null);
        m_rgpSamples = array<CRopeSample@>(MAX_SAMPLES, null);
    }
    
    CBaseEntity@ GetSelf() {
        return self;
    }
    
    bool KeyValue(const string& in _Key, const string& in _Value) {
        if (_Key == "segments") {
            m_iSegments = atoi(_Value);

            if (m_iSegments >= MAX_SEGMENTS)
                m_iSegments = MAX_SEGMENTS - 1;
                
            return true;
        } else if (_Key == "bodymodel") {
            m_lpszBodyModel = _Value;
            
            return true;
        } else if (_Key == "endingmodel") {
            m_lpszEndingModel = _Value;
            
            return true;
        } else if (_Key == "disable") {
            m_bDisallowPlayerAttachment = atoi(_Value) != 0;
            
            return true;
        } else return BaseClass.KeyValue(_Key, _Value);
    }

    void Precache() {
        BaseClass.Precache();

        g_Game.PrecacheOther("rope_segment");
        g_Game.PrecacheOther("rope_sample");

        g_Game.PrecacheModel(GetBodyModel());
        g_Game.PrecacheModel(GetEndingModel());
        for (uint idx = 0; idx < g_pszCreakSounds.length(); idx++) {
            g_Game.PrecacheGeneric("sound/" + g_pszCreakSounds[idx]);
            g_SoundSystem.PrecacheSound(g_pszCreakSounds[idx]);
        }
    }

    void Spawn() {
        m_bMakeSound = true;

        Precache();

        m_vecGravity.x = m_vecGravity.y = 0.f;
        m_vecGravity.z = -800.f;

        m_bObjectAttached = false;

        m_iNumSamples = m_iSegments + 1;

        m_bActivated = false;
    }
    
    void Activate() {
        if (!m_bActivated) {
            InitRope();
            m_bActivated = true;
        }
    }

    void InitRope() {
        for (int uiSample = 0; uiSample < m_iNumSamples; ++uiSample) {
            @m_rgpSamples[uiSample] = UTIL_CreateSample();
            g_EntityFuncs.SetOrigin(m_rgpSamples[uiSample].GetSelf(), self.pev.origin);
        }

        {
            @seg[0] = UTIL_CreateSegment(m_rgpSamples[ 0 ], GetBodyModel(), @this);
            seg[0].SetAbsOrigin(self.pev.origin);
        }

        Vector vecOrigin;
        Vector vecAngles;

        const Vector vecGravity = m_vecGravity.Normalize();

        if (m_iSegments > 2) {
            for (int uiSeg = 1; uiSeg < m_iSegments - 1; ++uiSeg) {
                CRopeSample@ pSegSample = m_rgpSamples[uiSeg];
                @seg[uiSeg] = UTIL_CreateSegment(pSegSample, GetBodyModel(), @this);

                CRopeSegment@ pCurrent = seg[uiSeg - 1];
                CBaseEntity@ pEntity = pCurrent.GetSelf();
                CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);

                pAnimating.GetAttachment(0, vecOrigin, vecAngles);

                Vector vecPos = vecOrigin - pCurrent.pev.origin;

                const float flLength = vecPos.Length();

                vecOrigin = flLength * vecGravity + pCurrent.pev.origin;

                seg[uiSeg].SetAbsOrigin(vecOrigin);
            }
        }

        CRopeSample@ pSegSample = m_rgpSamples[m_iSegments - 1];
        @seg[m_iSegments - 1] = UTIL_CreateSegment(pSegSample, GetEndingModel(), @this);

        CRopeSegment@ pCurrent = seg[m_iSegments - 2];

        CBaseEntity@ pEntity = pCurrent.GetSelf();
        CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
        pAnimating.GetAttachment(0, vecOrigin, vecAngles);

        Vector vecPos = vecOrigin - pCurrent.pev.origin;

        const float flLength = vecPos.Length();

        vecOrigin = flLength * vecGravity + pCurrent.pev.origin;

        seg[m_iSegments - 1].SetAbsOrigin(vecOrigin);

        InitializeRopeSim();

        SetThink(ThinkFunction(RopeThink));
        self.pev.nextthink = g_Engine.time + 0.01f;
    }
    
    void RopeThink() {
        RunSimOnSamples();

        array<CRopeSegment@>@ ppPrimarySegs = GetSegments();

        SetRopeSegments(m_iSegments, ppPrimarySegs);

        if (ShouldCreak()) {
            Creak();
        }

        self.pev.nextthink = g_Engine.time + (1.f / RopeFrameRate);
    }

    /**
    *   Initializes the rope simulation data.
    */
    void InitializeRopeSim() {
        int uiIndex;

        for (int uiSeg = 0; uiSeg < m_iSegments; ++uiSeg) {
            CRopeSegment@ pSegment = seg[uiSeg];
            CRopeSample@ pSample = pSegment.GetSample();

            CRopeSampleData@ data = pSample.GetData();

            data.m_vecPosition = pSegment.pev.origin;

            data.m_vecVelocity = g_vecZero;
            data.m_vecForce = g_vecZero;
            data.m_flMassReciprocal = 1.f;
            data.m_bApplyExternalForce = false;
            data.m_vecExternalForce = g_vecZero;

            Vector vecOrigin, vecAngles;
            CBaseEntity@ pEntity = pSegment.GetSelf();
            CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
            pAnimating.GetAttachment(0, vecOrigin, vecAngles);
            data.m_flRestLength = (pSegment.pev.origin - vecOrigin).Length();
        }

        {
            //Zero out the anchored segment's mass so it stays in place.
            CRopeSample@ pSample = m_rgpSamples[0];

            pSample.GetData().m_flMassReciprocal = 0;
        }

        CRopeSegment@ pSegment = seg[m_iSegments - 1];

        Vector vecOrigin, vecAngles;

        CBaseEntity@ pEntity = pSegment.GetSelf();
        CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
        pAnimating.GetAttachment(0, vecOrigin, vecAngles);

        Vector vecDistance = vecOrigin - pSegment.pev.origin;

        const float flLength = vecDistance.Length();

        const Vector vecGravity = m_vecGravity.Normalize();

        vecOrigin = vecGravity * flLength + pSegment.pev.origin;

        CRopeSample@ pSample = m_rgpSamples[m_iNumSamples - 1];

        CRopeSampleData@ data = pSample.GetData();

        data.m_vecPosition = vecOrigin;
        data.m_vecOldPosition = data.m_vecPosition; // Initialize previous position

        m_vecLastEndPos = vecOrigin;

        data.m_vecVelocity = g_vecZero;

        data.m_vecForce = g_vecZero;

        data.m_flMassReciprocal = 0.25f;

        data.m_bApplyExternalForce = false;

        int uiNumSegs = ROPE_IGNORE_SAMPLES;

        if (m_iSegments <= ROPE_IGNORE_SAMPLES)
            uiNumSegs = m_iSegments;

        for (uiIndex = 0; uiIndex < uiNumSegs; ++uiIndex) {
            seg[uiIndex].SetCanBeGrabbed(false);
        }
        
        for (uiIndex = 0; uiIndex < uiNumSegs; ++uiIndex) {
            CRopeSampleData@ pData = m_rgpSamples[uiIndex].GetData();
            pData.m_flMassReciprocal = 0.0f; // Infinite mass, fixed point
        }
    }

    /**
    *   Runs simulation on the samples.
    */
    void RunSimOnSamples() {
        // Compute forces
        ComputeForces();

        // Integrate positions and velocities using Verlet integration
        VerletIntegrate(1.0f / RopeFrameRate /* flDeltaTime */);
        //HeunIntegrate(1.0f / RopeFrameRate /* flDeltaTime */);
    }

   void ComputeForces() {
        for (int uiIndex = 0; uiIndex < m_iNumSamples; ++uiIndex) {
            CRopeSampleData@ data = m_rgpSamples[uiIndex].GetData();

            // Reset force
            data.m_vecForce = g_vecZero;

            // Apply gravity
            if (data.m_flMassReciprocal != 0.0f) {
                data.m_vecForce = data.m_vecForce + (m_vecGravity / data.m_flMassReciprocal);
            }

            // Apply external forces
            if (data.m_bApplyExternalForce) {
                data.m_vecForce = data.m_vecForce + data.m_vecExternalForce;
                data.m_vecExternalForce = g_vecZero;
                data.m_bApplyExternalForce = false;
            }

            // Damping force (optional)
            data.m_vecForce = data.m_vecForce - (data.m_vecVelocity * SPRING_DAMPING);
        }
        
        //Heun integrator:
        /*
        for (int uiIndex = 0; uiIndex < m_iNumSamples; ++uiIndex) {
            CRopeSampleData@ data = m_rgpSamples[uiIndex].GetData();

            // Reset force
            data.m_vecForce = g_vecZero;

            // Apply gravity
            if (data.m_flMassReciprocal != 0.0f) {
                data.m_vecForce = data.m_vecForce + (m_vecGravity / data.m_flMassReciprocal);
            }

            // Apply external forces
            if (data.m_bApplyExternalForce) {
                data.m_vecForce = data.m_vecForce + data.m_vecExternalForce;
                data.m_vecExternalForce = g_vecZero;
                data.m_bApplyExternalForce = false;
            }

            // Damping force (optional)
            data.m_vecForce = data.m_vecForce - (data.m_vecVelocity * SPRING_DAMPING);
        }
        */
    }

    void VerletIntegrate(const float flDeltaTime) {
        const float flDeltaTimeSq = flDeltaTime * flDeltaTime;

        for (int uiIndex = 0; uiIndex < m_iNumSamples; ++uiIndex) {
            CRopeSampleData@ data = m_rgpSamples[uiIndex].GetData();

            // If mass is infinite (anchor point), skip integration
            if (data.m_flMassReciprocal == 0.0f) {
                data.m_vecVelocity = g_vecZero;
                data.m_vecOldPosition = data.m_vecPosition;
                continue;
            }

            // Calculate acceleration
            Vector acceleration = data.m_vecForce * data.m_flMassReciprocal;

            // Store current position
            Vector currentPosition = data.m_vecPosition;

            if (data.m_vecOldPosition == g_vecZero) {
                // First iteration, estimate previous position
                data.m_vecOldPosition = data.m_vecPosition - data.m_vecVelocity * flDeltaTime;
            }

            // Verlet integration formula
            data.m_vecPosition = (2.0f * data.m_vecPosition) - data.m_vecOldPosition + acceleration * flDeltaTimeSq;

            // Update velocity (optional, for damping or output)
            data.m_vecVelocity = (data.m_vecPosition - data.m_vecOldPosition) / (2.0f * flDeltaTime);

            // Prepare for next iteration
            data.m_vecOldPosition = currentPosition;
        }

        // After integration, apply constraints to enforce rope segment lengths
        ApplyConstraints();
    }
    
    /*void HeunIntegrate(const float flDeltaTime) {
        // We'll need to store the original force, as ComputeForces() overwrites it
        array<Vector> originalForces(m_iNumSamples);

        // Copy the original forces
        for (int uiIndex = 0; uiIndex < m_iNumSamples; ++uiIndex) {
            originalForces[uiIndex] = m_rgpSamples[uiIndex].GetData().m_vecForce;
        }

        for (int uiIndex = 0; uiIndex < m_iNumSamples; ++uiIndex) {
            CRopeSampleData@ data = m_rgpSamples[uiIndex].GetData();

            // If mass is infinite (anchor point), skip integration
            if (data.m_flMassReciprocal == 0.0f) {
                data.m_vecVelocity = g_vecZero;
                continue;
            }

            // --- Step 1: Compute the initial acceleration ---
            Vector acceleration1 = originalForces[uiIndex] * data.m_flMassReciprocal;

            // --- Step 2: Predict the velocity and position at the next time step ---
            Vector predictedVelocity = data.m_vecVelocity + acceleration1 * flDeltaTime;
            Vector predictedPosition = data.m_vecPosition + data.m_vecVelocity * flDeltaTime;

            // --- Step 3: Compute the predicted force at the predicted position ---
            Vector predictedForce = g_vecZero;

            // Apply gravity
            predictedForce = predictedForce + (m_vecGravity / data.m_flMassReciprocal);

            // Apply damping force using predicted velocity
            predictedForce = predictedForce - (predictedVelocity * SPRING_DAMPING);

            // --- Step 4: Compute the acceleration at the predicted position ---
            Vector acceleration2 = predictedForce * data.m_flMassReciprocal;

            // --- Step 5: Average the accelerations and update velocity and position ---
            Vector averageAcceleration = (acceleration1 + acceleration2) * 0.5f;

            // Update velocity and position using the averaged acceleration
            data.m_vecVelocity = data.m_vecVelocity + averageAcceleration * flDeltaTime;
            data.m_vecPosition = data.m_vecPosition + data.m_vecVelocity * flDeltaTime;
        }

        // After integration, apply constraints to enforce rope segment lengths
        ApplyConstraints();
    }*/

    void ApplyConstraints() {
        const int iterations = 5; // Number of constraint iterations
        //const float EPSILON = 1e-6f;
        const float EPSILON_SQ = 1e-12f;

        for (int iteration = 0; iteration < iterations; ++iteration) {
            for (int uiIndex = 0; uiIndex < m_iSegments; ++uiIndex) {
                CRopeSampleData@ data1 = m_rgpSamples[uiIndex].GetData();
                CRopeSampleData@ data2 = m_rgpSamples[uiIndex + 1].GetData();

                Vector delta = data2.m_vecPosition - data1.m_vecPosition;
                float deltaLengthSq = (delta.x * delta.x) + (delta.y * delta.y) + (delta.z * delta.z); // delta.Length() * delta.Length();

                if (deltaLengthSq > EPSILON_SQ) {
                    float deltaLength = sqrt(deltaLengthSq);
                    float m_flRestLength = data1.m_flRestLength;
                    float difference = (deltaLength - m_flRestLength) / deltaLength;

                    Vector correction = delta * 0.5f * difference;

                    // Apply correction based on mass
                    if (data1.m_flMassReciprocal != 0.0f) {
                        data1.m_vecPosition = data1.m_vecPosition + correction;
                    }
                    if (data2.m_flMassReciprocal != 0.0f) {
                        data2.m_vecPosition = data2.m_vecPosition - correction;
                    }
                }
            }
        }
    }
    
    void TraceModels(array<CRopeSegment@>@ pSegments) {
        if (m_iSegments > 1) {
            Vector vecAngles;
            GetAlignmentAngles(
                m_rgpSamples[0].GetData().m_vecPosition,
                m_rgpSamples[1].GetData().m_vecPosition,
                vecAngles
            );
            pSegments[0].pev.angles = vecAngles;
        }

        TraceResult tr;

        for (int uiSeg = 1; uiSeg < m_iSegments; ++uiSeg) {
            CRopeSample@ pSample = m_rgpSamples[uiSeg];
            Vector vecDist = pSample.GetData().m_vecPosition - pSegments[uiSeg].pev.origin;
            vecDist = vecDist.Normalize();

            float flTraceDist = 10.f;
            if (m_bObjectAttached) {
                // Adjust trace distance if an object is attached
                flTraceDist = (uiSeg - m_iAttachedObjectsSegment + 2) < 5 ? 50.f : 10.f;
            }

            Vector vecTraceDist = vecDist * flTraceDist;
            Vector vecEnd = pSample.GetData().m_vecPosition + vecTraceDist;

            g_Utility.TraceLine(pSegments[uiSeg].pev.origin, vecEnd, ignore_monsters, self.edict(), tr);

            if (tr.flFraction != 1.f || tr.fStartSolid == 1 || tr.fInOpen == 0) {
                Vector vecOrigin = tr.vecEndPos - vecTraceDist;
                TruncateEpsilon(vecOrigin, vecOrigin);
                pSegments[uiSeg].SetAbsOrigin(vecOrigin);

                Vector vecNormal = tr.vecPlaneNormal.Normalize() * 20000.0;
                CRopeSampleData@ data = pSegments[uiSeg].GetSample().GetData();
                data.m_bApplyExternalForce = true;
                data.m_vecExternalForce = vecNormal;
                data.m_vecVelocity = g_vecZero;
            } else {
                Vector vecOrigin = pSample.GetData().m_vecPosition;
                TruncateEpsilon(vecOrigin, vecOrigin);
                pSegments[uiSeg].SetAbsOrigin(vecOrigin);
            }
        }

        // Update segment angles
        Vector vecAngles;
        for (int uiSeg = 1; uiSeg < m_iSegments; ++uiSeg) {
            CRopeSegment@ pSegmentPrev = pSegments[uiSeg - 1];
            CRopeSegment@ pSegmentCurr = pSegments[uiSeg];
            GetAlignmentAngles(pSegmentPrev.pev.origin, pSegmentCurr.pev.origin, vecAngles);
            pSegmentPrev.pev.angles = vecAngles;
        }

        // Handle the last segment's orientation
        if (m_iSegments > 1) {
            CRopeSample@ pSample = m_rgpSamples[m_iNumSamples - 1];
            g_Utility.TraceLine(m_vecLastEndPos, pSample.GetData().m_vecPosition, ignore_monsters, self.edict(), tr);

            if (tr.flFraction == 1.f) {
                m_vecLastEndPos = pSample.GetData().m_vecPosition;
            } else {
                m_vecLastEndPos = tr.vecEndPos;
                pSample.GetData().m_bApplyExternalForce = true;
                pSample.GetData().m_vecExternalForce = tr.vecPlaneNormal.Normalize() * 4000.0;
            }

            CRopeSegment@ pSegment = pSegments[m_iNumSamples - 2];
            Vector vecAngles2;
            GetAlignmentAngles(pSegment.pev.origin, m_vecLastEndPos, vecAngles2);
            pSegment.pev.angles = vecAngles2;
        }
    }

    void SetRopeSegments(const int uiNumSegments, array<CRopeSegment@>@ pSegments) {
        if (uiNumSegments > 0) {
            TraceModels(pSegments);
            pSegments[0].pev.solid = SOLID_TRIGGER;
            pSegments[0].pev.effects = 0;

            for (int idx = 1; idx < uiNumSegments; ++idx) {
                CRopeSegment@ pSegment = pSegments[idx];
                pSegment.pev.solid = SOLID_TRIGGER;
                pSegment.pev.effects = 0;
            }
        }
    }

    /**
    *   Moves the attached object up.
    *   @param flDeltaTime Time between previous and current movement.
    *   @return true if the object is still on the rope, false otherwise.
    */
    bool MoveUp(float flDeltaTime) {
        if (m_iAttachedObjectsSegment > 4) {
            float flDistance = flDeltaTime * 128.f;

            Vector vecOrigin, vecAngles;

            while (true) {
                float flOldDist = flDistance;

                flDistance = 0.f;

                if (flOldDist <= 0.f)
                    break;

                if (m_iAttachedObjectsSegment <= 3)
                    break;

                if (flOldDist > m_flAttachedObjectsOffset) {
                    flDistance = flOldDist - m_flAttachedObjectsOffset;

                    --m_iAttachedObjectsSegment;

                    float flNewOffset = 0.f;

                    if (m_iAttachedObjectsSegment < m_iSegments) {
                        CRopeSegment@ pSegment = @seg[m_iAttachedObjectsSegment];

                        CBaseEntity@ pEntity = pSegment.self;
                        CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
                        pAnimating.GetAttachment(0, vecOrigin, vecAngles);

                        flNewOffset = (pSegment.self.pev.origin - vecOrigin).Length();
                    }

                    m_flAttachedObjectsOffset = flNewOffset;
                } else {
                    m_flAttachedObjectsOffset -= flOldDist;
                }
            }
        }

        return true;
    }

    /**
    *   Moves the attached object down.
    *   @param flDeltaTime Time between previous and current movement.
    *   @return true if the object is still on the rope, false otherwise.
    */
    bool MoveDown(float flDeltaTime) { 
        if (!m_bObjectAttached)
            return false;
        
        float flDistance = flDeltaTime * 128.f;

        Vector vecOrigin, vecAngles;

        CRopeSegment@ pSegment;

        bool bOnRope = true;

        bool bDoIteration = true;

        while (bDoIteration) {
            bDoIteration = false;

            if (flDistance > 0.f) {
                float flNewDist = flDistance;
                float flSegLength = 0.f;

                while (bOnRope) {
                    if (m_iAttachedObjectsSegment < m_iSegments) {
                        @pSegment = @seg[m_iAttachedObjectsSegment];

                        CBaseEntity@ pEntity = pSegment.self;
                        CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
                        pAnimating.GetAttachment(0, vecOrigin, vecAngles);

                        flSegLength = (pSegment.self.pev.origin - vecOrigin).Length();
                    }

                    const float flOffset = flSegLength - m_flAttachedObjectsOffset;

                    if (flNewDist <= flOffset) {
                        m_flAttachedObjectsOffset += flNewDist;
                        flDistance = 0.f;
                        bDoIteration = true;
                        break;
                    }

                    if (m_iAttachedObjectsSegment + 1 == m_iSegments)
                        bOnRope = false;
                    else
                        ++m_iAttachedObjectsSegment;

                    flNewDist -= flOffset;
                    flSegLength = 0;

                    m_flAttachedObjectsOffset = 0;

                    if (flNewDist <= 0)
                        break;
                }
            }
        }

        return bOnRope;
    }

    /**
    *   @return The attached object's velocity.
    */
    Vector GetAttachedObjectsVelocity() {
        if (!m_bObjectAttached)
            return g_vecZero;

        return seg[m_iAttachedObjectsSegment].GetSample().GetData().m_vecVelocity;
    }

    /**
    *   Applies force from the player. Only applies if there is currently an object attached to the rope.
    *   @param _Force Force.
    */
    void ApplyForceFromPlayer( const Vector& in _Force ) {
        if (!m_bObjectAttached)
            return;

        float flForce = g_pConVarPlayerForce.GetFloat();//20000.0;

        if (m_iSegments < 26)
            flForce *= (float(m_iSegments) / 26.f);

        const Vector vecScaledForce = _Force * flForce;

        ApplyForceToSegment(vecScaledForce, m_iAttachedObjectsSegment);
    }

    /**
    *   Applies force to a specific segment.
    *   @param _Force Force.
    *   @param _Segment Segment index.
    */
    void ApplyForceToSegment(const Vector& in _Force, const int _Segment) {
        if (_Segment < m_iSegments) {
            seg[_Segment].ApplyExternalForce(_Force);
        } else if(_Segment == m_iSegments) {
            //Apply force to the last sample.
            CRopeSampleData@ data = m_rgpSamples[_Segment - 1].GetData();

            data.m_vecExternalForce = data.m_vecExternalForce + _Force;

            data.m_bApplyExternalForce = true;
        }
    }

    /**
    *   Attached an object to the given segment.
    */
    void AttachObjectToSegment(CRopeSegment@ _Segment) {
        m_bObjectAttached = true;

        m_flDetachTime = 0.f;

        SetAttachedObjectsSegment(_Segment);

        m_flAttachedObjectsOffset = 0.f;
    }

    /**
    *   Detaches an attached object.
    */
    void DetachObject() {
        m_bObjectAttached = false;
        m_flDetachTime = g_Engine.time;
    }

    /**
    *   @return Whether an object is attached.
    */
    bool IsObjectAttached() { return m_bObjectAttached; }

    /**
    *   @return Whether this rope allows attachments.
    */
    bool IsAcceptingAttachment() {
        if (g_Engine.time - m_flDetachTime > 2.f && !m_bObjectAttached) {
            return !m_bDisallowPlayerAttachment;
        }

        return false;
    }

    /**
    *   @return The number of segments.
    */
    int GetNumSegments() { return m_iSegments; }

    /**
    *   @return The segments.
    */
    array<CRopeSegment@>@ GetSegments() { return @seg; }

    /**
    *   @return Whether this rope is allowed to make sounds.
    */
    bool IsSoundAllowed() { return m_bMakeSound; }

    /**
    *   Sets whether this rope is allowed to make sounds.
    */
    void SetSoundAllowed(bool _Rhs) {
        m_bMakeSound = _Rhs;
    }

    /**
    *   @return Whether this rope should creak.
    */
    bool ShouldCreak() {
        if (m_bObjectAttached && m_bMakeSound) {
            CRopeSample@ pSample = seg[m_iAttachedObjectsSegment].GetSample();

            if (pSample.GetData().m_vecVelocity.Length() > 200.0)
                return Math.RandomLong(1, 5) == 1;
        }

        return false;
    }

    /**
    *   Plays a creak sound.
    */
    void Creak() {
        g_SoundSystem.EmitSound(self.edict(), CHAN_BODY, g_pszCreakSounds[Math.RandomLong(0, g_pszCreakSounds.length() - 1)], VOL_NORM, ATTN_NORM);
    }

    /**
    *   @return The body model name.
    */
    string /* string_t -> string */ GetBodyModel() { return m_lpszBodyModel; }

    /**
    *   @return The ending model name.
    */
    string /* string_t -> string */ GetEndingModel() { return m_lpszEndingModel; }

    /**
    *   @return Segment length for the given segment.
    */
    float GetSegmentLength(int _SegmentIdx) {
        if (IsValidSegmentIndex(_SegmentIdx)) {
            Vector vecOrigin, vecAngles;

            CRopeSegment@ pSegment = seg[_SegmentIdx];
            CBaseEntity@ pEntity = pSegment.GetSelf();
            CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);

            pAnimating.GetAttachment(0, vecOrigin, vecAngles);

            return (pSegment.pev.origin - vecOrigin).Length();
        }

        return 0.f;
    }

    /**
    *   @return Total rope length.
    */
    float GetRopeLength() {
        float flLength = 0.f;

        Vector vecOrigin, vecAngles;

        for (int idx = 0; idx < m_iSegments; ++idx) {
            CRopeSegment@ pSegment = seg[idx];

            CBaseEntity@ pEntity = pSegment.GetSelf();
            CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
            pAnimating.GetAttachment(0, vecOrigin, vecAngles);

            flLength += (pSegment.pev.origin - vecOrigin).Length();
        }

        return flLength;
    }

    /**
    *   @return The rope's origin.
    */
    Vector GetRopeOrigin() {
        return m_rgpSamples[0].GetData().m_vecPosition;
    }

    /**
    *   @return Whether the given segment index is valid.
    */
    bool IsValidSegmentIndex(const int _Segment) {
        return _Segment < m_iSegments;
    }

    /**
    *   @return The origin of the given segment.
    */
    Vector GetSegmentOrigin(const int _Segment) {
        if (!IsValidSegmentIndex(_Segment))
            return g_vecZero;

        return m_rgpSamples[_Segment].GetData().m_vecPosition;
    }

    /**
    *   @return The attachment point of the given segment.
    */
    Vector GetSegmentAttachmentPoint(const int _Segment) {
        if (!IsValidSegmentIndex(_Segment))
            return g_vecZero;

        Vector vecOrigin, vecAngles;

        CRopeSegment@ pSegment = seg[_Segment];

        CBaseEntity@ pEntity = pSegment.GetSelf();
        CBaseAnimating@ pAnimating = cast<CBaseAnimating@>(pEntity);
        pAnimating.GetAttachment( 0, vecOrigin, vecAngles );

        return vecOrigin;
    }

    /**
    *   @param _Segment Segment.
    *   Sets the attached object segment.
    */
    void SetAttachedObjectsSegment(CRopeSegment@ _Segment) {
        for (int idx = 0; idx < m_iSegments; ++idx) {
            if (seg[idx] is _Segment) {
                m_iAttachedObjectsSegment = idx;
                break;
            }
        }
    }

    /**
    *   @param _SegmentIndex Segment index.
    *   @return The segment direction normal from its origin.
    */
    Vector GetSegmentDirFromOrigin(const int _SegmentIndex) {
        if (_SegmentIndex >= m_iSegments)
            return g_vecZero;

        //There is one more sample than there are segments, so this is fine.
        const Vector vecResult =  m_rgpSamples[_SegmentIndex + 1].GetData().m_vecPosition - m_rgpSamples[_SegmentIndex].GetData().m_vecPosition;

        return vecResult.Normalize();
    }

    /**
    *   @return The attached object position.
    */
    Vector GetAttachedObjectsPosition() {
        if (!m_bObjectAttached)
            return g_vecZero;

        Vector vecResult;

        if (m_iAttachedObjectsSegment < m_iSegments)
            vecResult = m_rgpSamples[m_iAttachedObjectsSegment].GetData().m_vecPosition;

        vecResult = vecResult + (m_flAttachedObjectsOffset * GetSegmentDirFromOrigin(m_iAttachedObjectsSegment));

        return vecResult;
    }

//Fields def
    int m_iSegments; //Size: 0x0004, offset: 0x0000

    array<CRopeSegment@> seg;//[ MAX_SEGMENTS ]; //Size: 0x0008, offset: 0x0004

    Vector m_vecLastEndPos; //Size: 0x000C, offset: 0x001A
    Vector m_vecGravity; //Size: 0x000C, offset: 0x0026

    array<CRopeSample@> m_rgpSamples;//[ MAX_SAMPLES ]; //Size: 0x0008, offset: 0x0032

    int m_iNumSamples; //Size: 0x0004, offset: 0x003A

    bool m_bObjectAttached; //Size: 0x0001, offset: 0x0043

    int m_iAttachedObjectsSegment; //Size: 0x0004, offset: 0x0044
    float m_flAttachedObjectsOffset; //Size: 0x0004, offset: 0x0048
    float m_flDetachTime; //Size: 0x0004, offset: 0x004C

    string m_lpszBodyModel; //Original type: string_t, mapped to string. //Size: 0x0008, offset: 0x0050
    string m_lpszEndingModel; //Original type: string_t, mapped to string. //Size: 0x0008, offset: 0x0058

    bool m_bDisallowPlayerAttachment; //Size: 0x0004, offset: 0x0060

    bool m_bMakeSound; //Size: 0x0001, offset: 0x0064

    protected bool m_bActivated; //Size: 0x0001, offset: 0x0065
}; //Size: 0x0066
//static_assert(sizeof(CRope) == 0x0066)

class CElectrifiedWire : CRope
{
	CElectrifiedWire()
    {
        m_bIsActive = true;
        m_iTipSparkFrequency = 3;
        m_iBodySparkFrequency = 100;
        m_iLightningFrequency = 150;
        m_iXJoltForce = 0;
        m_iYJoltForce = 0;
        m_iZJoltForce = 0;
        m_uiNumUninsulatedSegments = 0;
        @m_uiUninsulatedSegments = array<int>(MAX_SEGMENTS);
    }

	bool KeyValue(const string& in _Key, const string& in _Value) {
        if( _Key == "sparkfrequency"  )
        {
            m_iTipSparkFrequency = atoi(_Value);

            return true;
        }
        else if( _Key == "bodysparkfrequency" )
        {
            m_iBodySparkFrequency = atoi(_Value);

            return true;
        }
        else if( _Key == "lightningfrequency" )
        {
            m_iLightningFrequency = atoi(_Value);

            return true;
        }
        else if( _Key == "xforce" )
        {
            m_iXJoltForce = atoi(_Value);

            return true;
        }
        else if( _Key == "yforce" )
        {
            m_iYJoltForce = atoi(_Value);

            return true;
        }
        else if( _Key == "zforce" )
        {
            m_iZJoltForce = atoi(_Value);

            return true;
        }
        else
            return CRope::KeyValue( _Key, _Value );
    }

	void Precache()
    {
        CRope::Precache();

        m_iLightningSprite = g_Game.PrecacheModel( "sprites/lgtning.spr" );
    }

    void Spawn()
    {
        CRope::Spawn();
    }

    void Activate()
    {
        if (!m_bActivated)
        {
            InitElectrifiedRope();
            m_bActivated = true;
        }
    }

    void InitElectrifiedRope()
    {
        InitRope();

        m_uiNumUninsulatedSegments = 0;
        m_bIsActive = true;

        if( m_iBodySparkFrequency > 0 )
        {
            for( int uiIndex = 0; uiIndex < GetNumSegments(); ++uiIndex )
            {
                if( IsValidSegmentIndex( uiIndex ) )
                {
                    m_uiUninsulatedSegments[ m_uiNumUninsulatedSegments++ ] = uiIndex;
                }
            }
        }

        if( m_uiNumUninsulatedSegments > 0 )
        {
            for( int uiIndex = 0; uiIndex < m_uiNumUninsulatedSegments; ++uiIndex )
            {
                GetSegments()[ uiIndex ].SetCauseDamageOnTouch( m_bIsActive );
            }
        }

        if( m_iTipSparkFrequency > 0 )
        {
            GetSegments()[ GetNumSegments() - 1 ].SetCauseDamageOnTouch( m_bIsActive );
        }

        m_flLastSparkTime = g_Engine.time;

        SetSoundAllowed( false );

        self.pev.nextthink = g_Engine.time + 0.01f;
        SetThink(ThinkFunction(ElectrifiedRopeThink));
    }

	void ElectrifiedRopeThink()
    {
        if( g_Engine.time - m_flLastSparkTime > 0.1 )
        {
            m_flLastSparkTime = g_Engine.time;

            if( m_uiNumUninsulatedSegments > 0 )
            {
                for( int uiIndex = 0; uiIndex < m_uiNumUninsulatedSegments; ++uiIndex )
                {
                    if( ShouldDoEffect( m_iBodySparkFrequency ) )
                    {
                        DoSpark( m_uiUninsulatedSegments[ uiIndex ], false );
                    }
                }
            }

            if( ShouldDoEffect( m_iTipSparkFrequency ) )
            {
                DoSpark( GetNumSegments() - 1, true );
            }

            if( ShouldDoEffect( m_iLightningFrequency ) )
                DoLightning();
        }

        CRope::RopeThink();
    }

	void Use( CBaseEntity@ pActivator, CBaseEntity@ pCaller, USE_TYPE useType, float flValue ) {
        m_bIsActive = !m_bIsActive;

        if( m_uiNumUninsulatedSegments > 0 )
        {
            for( int uiIndex = 0; uiIndex < m_uiNumUninsulatedSegments; ++uiIndex )
            {
                GetSegments()[ m_uiUninsulatedSegments[ uiIndex ] ].SetCauseDamageOnTouch( m_bIsActive );
            }
        }

        if( m_iTipSparkFrequency > 0 )
        {
            GetSegments()[ GetNumSegments() - 1 ].SetCauseDamageOnTouch( m_bIsActive );
        }
    }

	/**
	*	@return Whether the wire is active.
	*/
	bool IsActive() const { return m_bIsActive; }

	/**
	*	@param iFrequency Frequency.
	*	@return Whether the spark effect should be performed.
	*/
	bool ShouldDoEffect( const int iFrequency ) {
        if( iFrequency <= 0 )
            return false;

        if( !IsActive() )
            return false;

        return Math.RandomLong( 1, iFrequency ) == 1;
    }

	/**
	*	Do spark effects.
	*/
	void DoSpark( const int uiSegment, const bool bExertForce )
    {
        const Vector vecOrigin = GetSegmentAttachmentPoint( uiSegment );

        g_Utility.Sparks( vecOrigin );

        if( bExertForce )
        {
            const Vector vecSparkForce(
                Math.RandomFloat( -m_iXJoltForce, m_iXJoltForce ),
                Math.RandomFloat( -m_iYJoltForce, m_iYJoltForce ),
                Math.RandomFloat( -m_iZJoltForce, m_iZJoltForce )
            );

            ApplyForceToSegment( vecSparkForce, uiSegment );
        }
    }

	/**
	*	Do lightning effects.
	*/
	void DoLightning() {
        const int uiSegment1 = Math.RandomLong( 0, GetNumSegments() - 1 );

        int uiSegment2;

        int uiIndex;

        //Try to get a random segment.
        for( uiIndex = 0; uiIndex < 10; ++uiIndex ) {
            uiSegment2 = Math.RandomLong( 0, GetNumSegments() - 1 );

            if( uiSegment2 != uiSegment1 )
                break;
        }

        if( uiIndex >= 10 )
            return;

        CRopeSegment@ pSegment1;
        CRopeSegment@ pSegment2;
        
        @pSegment1 = GetSegments()[ uiSegment1 ];
        @pSegment2 = GetSegments()[ uiSegment2 ];

        NetworkMessage beam( MSG_PVS, NetworkMessages::SVC_TEMPENTITY, self.pev.origin );
            beam.WriteByte( TE_BEAMENTS );
            beam.WriteShort( pSegment1.GetSelf().entindex() );
            beam.WriteShort( pSegment2.GetSelf().entindex() );
            beam.WriteShort( m_iLightningSprite );
            beam.WriteByte( 0 );
            beam.WriteByte( 0 );
            beam.WriteByte( 1 );
            beam.WriteByte( 10 );
            beam.WriteByte( 80 );
            beam.WriteByte( 255 );
            beam.WriteByte( 255 );
            beam.WriteByte( 255 );
            beam.WriteByte( 255 );
            beam.WriteByte( 255 );
        beam.End();
    }

	bool m_bIsActive;

	int m_iTipSparkFrequency;
	int m_iBodySparkFrequency;
	int m_iLightningFrequency;

	int m_iXJoltForce;
	int m_iYJoltForce;
	int m_iZJoltForce;

	int m_uiNumUninsulatedSegments;
	array<int>@ m_uiUninsulatedSegments;//[ MAX_SEGMENTS ];

	int m_iLightningSprite;

	float m_flLastSparkTime;
};