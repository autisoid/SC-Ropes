/**
 * Copyright - xWhitey, 2024-2026.
 * Ropes.as - hangin' on ropes with bruddas while completing teh pro op4 boot camp yea
 *
 * Half-Life C's (a Sven Co-op server) source file
 * Authors: xWhitey, Gearbox, FWGS. Refer to further comment blocks for some explanation and OG code authors (if any).
 * Do not delete this comment block. Respect others' work!
 */

// Uses https://github.com/FWGS/hlsdk-portable/blob/opforfixed/dlls/gearbox/ropes.h as base for classes. Author: Gearbox, FWGS.
// Uses https://github.com/FWGS/hlsdk-portable/blob/opforfixed/dlls/gearbox/ropes.cpp as base for the code of methods of the classes. Author: Gearbox, FWGS.
// Refers some stuff from https://github.com/twhl-community/halflife-op4-updated/blob/master/dlls/rope/CRope.cpp. Author: Gearbox, TWHL.
// Refers some code from https://github.com/autisoid/SC-ZombiePlague/blob/master/scripts/plugins/ZombieMod.as. Author: xWhitey (me, the creator of port), Half-Life Community.

//-----------------------------------------------------------------------------
// Typedefs
//-----------------------------------------------------------------------------

;

//-----------------------------------------------------------------------------
// Classes
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// Purpose: Represents the data of an average player in this server.
//-----------------------------------------------------------------------------
class CPlayerData
{
    CPlayerData( void )
    {
        m_eOldMovetype = MOVETYPE_NONE;
        m_fIsOnRope = m_fIsClimbing = FALSE;
        m_flLastClimbTime = 0.0f;
        m_flStartedClimbing = 0.0f;
        m_flDetachTime = 0.0f;
        @m_pMasterRope = null;
        @m_pPreviouslyHangingRope = null;
    }

    int     m_eOldMovetype;
    bool    m_fIsOnRope;
    bool    m_fIsClimbing;
    float   m_flLastClimbTime;
    CRope@  m_pMasterRope;
    float   m_flStartedClimbing;
    float   m_flDetachTime;
    CRope@  m_pPreviouslyHangingRope;
};

//-----------------------------------------------------------------------------
// Purpose: Data for a single rope joint.
//-----------------------------------------------------------------------------
class CRopeSampleData
{
    CRopeSampleData( void )
    {
        m_vecPosition = m_vecVelocity = m_vecForce = m_vecExternalForce = m_vecOldPosition = g_vecZero;
        
        m_bApplyExternalForce = FALSE;
        m_flMassReciprocal = 0.0f;
        m_flRestLength = 0.0f;
    }

    Vector  m_vecPosition;
    Vector  m_vecVelocity;
    Vector  m_vecForce;
    Vector  m_vecExternalForce;

    bool    m_bApplyExternalForce;
    float   m_flMassReciprocal;
    float   m_flRestLength;
    
    Vector  m_vecOldPosition;
};

//-----------------------------------------------------------------------------
// Constants & enums
//-----------------------------------------------------------------------------

const size_t MAX_LIST_SEGMENTS = 5;
const size_t MAX_SEGMENTS = 63;
const size_t MAX_SAMPLES = 64;

const float ROPE_FRAMERATE = 60.0f;    // The framerate that the rope aims to run at. Clamping simulation to this also fixes ropes being invisible in multiplayer.

const float SPRING_DAMPING = 0.04f;
const size_t ROPE_IGNORE_SAMPLES = 2;   // integrator may be hanging if less than

const Vector DOWN( 0, 0, -1 );
const Vector RIGHT( 0, 1, 0 );

float M_PI = 3.14159265358979323846f;

const bool FALSE = false;
const bool TRUE = true;

const uint APPLY_CONSTRAINTS_ITERATIONS = 5; // Number of constraint iterations

// How long can a player hang on a rope before they get detached automatically?
const float MAX_SECONDS_HANGING_ON_A_ROPE = 10.0f;

// How often can a player hang on a rope? (doesn't stack, doesn't transmit between ropes)
const float DETACH_PERIODICITY = 2.0f;

//-----------------------------------------------------------------------------
// Global variables
//-----------------------------------------------------------------------------

CCVar@ g_pConVarPlayerForce;    // How much does a player push a rope with WASD?

array< array< CRopeSampleData@ > > g_pTempList; // [ MAX_LIST_SEGMENTS ][ MAX_SEGMENTS ];

array< CPlayerData@ > g_rgpPlayerDatas;

// TRUE if the plugin initialisation has failed.
bool    g_fPluginInitFailed = FALSE;    // If TRUE, the plugin is disabled.

array< CScheduledFunction@ > g_rgpfnPlayerOnARopeThink;

array< string > g_rgszCreakSounds =
{
    "hlcancer/op4/rope/rope1.wav",
    "hlcancer/op4/rope/rope2.wav",
    "hlcancer/op4/rope/rope3.wav"
};

//-----------------------------------------------------------------------------
// Utility functions
//-----------------------------------------------------------------------------

void CheckPlayerStuck( CBasePlayer@ _Player )
{
    TraceResult tr;
    
    if ( _Player is null )
    {
        return;
    }
    
    g_Utility.TraceHull( _Player.pev.origin, _Player.pev.origin, dont_ignore_monsters, human_hull, _Player.edict( ), tr );
    
    if ( tr.fAllSolid == 1 || tr.fStartSolid == 1 )
    {
        g_PlayerFuncs.ClientPrint( _Player, HUD_PRINTTALK, "SERVER: You may have stuck in an obstacle. If so, press the L-Key to unstuck.\n" );
    }
}

//-----------------------------------------------------------------------------
// Purpose: Get rid of one number after the floating point.
//-----------------------------------------------------------------------------
void TruncateEpsilon( Vector& in _In, Vector& out _Out )
{
    Vector vecTemp =  _In * 10.0;
    vecTemp.x += 0.5;   // Why?
    _Out = vecTemp / 10;
}

//-----------------------------------------------------------------------------
// Purpose: 
//-----------------------------------------------------------------------------
void GetAlignmentAngles( const Vector& in _Top, const Vector& in _Bottom, Vector& out _Out )
{
    Vector vecDist = _Bottom - _Top;
    Vector vecResult = vecDist.Normalize( );
    float flRoll, flPitch;

    flRoll = acos( DotProduct( vecResult, RIGHT ) ) * ( 180.0f / M_PI );

    _Out.z = flRoll * -1.0f;

    vecDist.y = 0.0f;   //

    vecResult = vecDist.Normalize( );

    flPitch = acos( DotProduct( vecResult, DOWN ) ) * ( 180.0f / M_PI );

    _Out.x = ( vecResult.x >= 0.0f ) ? flPitch : ( flPitch * -1.0f );
    _Out.y = 0.0f;
}

/*
====================
InitialiseStuff

Null (re)initialise stuff.
====================
*/
void InitialiseTempList( void )
{
    size_t cbIndex, cbIndex2;
    array< CRopeSampleData@ >@ pList = null;

    g_pTempList.resize( MAX_LIST_SEGMENTS );
    
    for ( cbIndex = 0; cbIndex < MAX_LIST_SEGMENTS; cbIndex++ )
    {
        @pList = @g_pTempList[ cbIndex ];
        pList.resize( MAX_SEGMENTS );
        for ( cbIndex2 = 0; cbIndex2 < MAX_SEGMENTS; cbIndex2++ )
        {
            @pList[ cbIndex2 ] = CRopeSampleData( );    // Create a new sample...
        }
    }
}

//-----------------------------------------------------------------------------
// Purpose: 
//-----------------------------------------------------------------------------
void InitialisePlayerData( void )
{
    g_rgpPlayerDatas.resize( 0 );
    g_rgpPlayerDatas.resize( g_Engine.maxClients + 1 );
    
    g_rgpfnPlayerOnARopeThink.resize( 0 );
    g_rgpfnPlayerOnARopeThink.resize( g_Engine.maxClients + 1 );
    
    for ( size_t cbIndex = 0; cbIndex < g_rgpPlayerDatas.length( ); cbIndex++ )
    {
        @g_rgpPlayerDatas[ cbIndex ] = CPlayerData( );
    }
}

/*
====================
UnregisterCustomEntity

====================
*/
void UnregisterCustomEntity( const string& in _Name )
{
    if ( g_CustomEntityFuncs.IsCustomEntity( _Name ) )
    {
        g_CustomEntityFuncs.UnRegisterCustomEntity( _Name );
    }
}

/*
====================
RegisterStuff

====================
*/
bool RegisterStuff( void )
{
    UnregisterCustomEntity( "env_rope" );
    UnregisterCustomEntity( "env_electrified_wire" );
    UnregisterCustomEntity( "rope_sample" );
    UnregisterCustomEntity( "rope_segment" );

    g_CustomEntityFuncs.RegisterCustomEntity( "CRope", "env_rope" );
    g_CustomEntityFuncs.RegisterCustomEntity( "CRopeSample", "rope_sample" );
    g_CustomEntityFuncs.RegisterCustomEntity( "CRopeSegment", "rope_segment" );
    g_CustomEntityFuncs.RegisterCustomEntity( "CElectrifiedWire", "env_electrified_wire" );
    
    return g_CustomEntityFuncs.IsCustomEntity( "env_rope" ) && g_CustomEntityFuncs.IsCustomEntity( "rope_sample" ) && g_CustomEntityFuncs.IsCustomEntity( "rope_segment" ) && g_CustomEntityFuncs.IsCustomEntity( "env_electrified_wire" );
}

/*
====================
RegisterHooks
====================
*/
bool RegisterHooks( void )
{
//  return  g_Hooks.RegisterHook( Hooks::Player::PlayerPreThink, @HOOKED_PlayerPreThink );
    return TRUE;
}

/*
====================
UnregisterHooks
====================
*/
void UnregisterHooks( void )
{
//  g_Hooks.RemoveHook( Hooks::Player::PlayerPreThink, @HOOKED_PlayerPreThink );
}

//-----------------------------------------------------------------------------
// Hooks, module callbacks
//-----------------------------------------------------------------------------

/*
====================
PluginInit

The moment this plugin has just (re)loaded.
====================
*/
void PluginInit( void )
{
    g_Module.ScriptInfo.SetAuthor( "xWhitey" );
    g_Module.ScriptInfo.SetContactInfo( "tyabus @ Discord" );
    
    @g_pConVarPlayerForce = CCVar( "sv_ropes_player_force", "1500", "Player force amount", ConCommandFlag::AdminOnly );
    
    InitialiseTempList( );
    InitialisePlayerData( );
    
    if ( ROPE_FRAMERATE <= 0.0f )
    {
        g_Log.PrintF( "[Ropes] PluginInit: ROPE_FRAMERATE is invalid!\n" );
    }
    
    g_fPluginInitFailed = !RegisterHooks( );
}

/*
====================
PluginExit

Plugin unload event
====================
*/
void PluginExit( void )
{
    UnregisterHooks( );
}

/*
====================
MapInit

Called when the map was just loaded. The entities are not spawned yet!
Use MapActivate (called in CWorld#Activate) if you need to work with entities.
====================
*/
void MapInit( void )
{
    if ( g_fPluginInitFailed )
    {
        g_Log.PrintF( "[Ropes] MapInit: Plugin init failed, doing nothing!\n" );
        return;
    }

    InitialiseTempList( );
    InitialisePlayerData( );
    
    if ( !RegisterStuff( ) )
    {
        g_Log.PrintF( "[Ropes] MapInit: RegisterStuff failed!\n" );
    }
}

/*
====================
MapActivate

The moment when "worldspawn" thinks for its first time.
====================
*/
void MapActivate( void )
{
    ;
}

/*
====================
PlayerPreThink

Called every frame when the player isn't choking their network packets
or isn't lagging. Runs **BEFORE** the movement code ( PM_Move ), so be careful
in modifying physics stuff in here. Anything unusual will result in prediction errors.
====================
*/
//HookReturnCode HOOKED_PlayerPreThink( CBasePlayer@ _Player, uint& out )
void PlayerOnARopeThink( EHandle _Player )
{
    CBaseEntity@    pEntity = null;
    CBasePlayer@    pPlayer = null;
    int             nPlayerIdx;
    CPlayerData@    pData = null;
    CRope@          pRope = null;
    Observer@       pObserver = null;
    Vector          vecForward, vecRight, vecUp, vecAttachPos, vecForce;
    
    @pEntity = _Player.GetEntity( );
    if ( pEntity is null )
    {
        return;
    }
    
    @pPlayer = cast< CBasePlayer@ >( pEntity );
    if ( pPlayer is null )
    {
        return;
    }
    
    nPlayerIdx = pPlayer.entindex( );
    @pData = g_rgpPlayerDatas[ nPlayerIdx ];
    
    if ( pData is null )
    {
        return;
    }
    
    // Not climbing, nuffin.
    if ( !pData.m_fIsOnRope )
    {
        return;
    }
    
    if ( pData.m_pMasterRope is null )
    {
        // Not on a rope anymore.
        pData.m_fIsOnRope = FALSE;
        pData.m_fIsClimbing = FALSE;
        pData.m_flDetachTime = g_Engine.time;
        pPlayer.pev.movetype = pData.m_eOldMovetype;    // give them the preserved movetype... --xWhitey
        CheckPlayerStuck( pPlayer );
        pPlayer.UnblockWeapons( null );  // Is this ok?
        
        return;
    }
    
    @pRope = pData.m_pMasterRope;
    @pObserver = pPlayer.GetObserver();
    
    // If they disconnected, aren't alive anymore, if they're observer or if they've been climbing the rope for a long while...
    if ( !pPlayer.IsAlive( ) || !pPlayer.IsConnected( ) || ( pObserver !is null && pObserver.IsObserver( ) ) || ( g_Engine.time > ( pData.m_flStartedClimbing + MAX_SECONDS_HANGING_ON_A_ROPE ) ) )
    {
        if ( pRope !is null )
        {
            pRope.DetachObject( );  // Fling them away off me!
            
            pPlayer.UnblockWeapons( pRope.GetSelf( ) );
            @pData.m_pMasterRope = null;
        }
        
        // Not on a rope anymore.
        pData.m_fIsOnRope = FALSE;
        pData.m_fIsClimbing = FALSE;
        pData.m_flDetachTime = g_Engine.time;
        @pData.m_pPreviouslyHangingRope = pRope;
        pPlayer.pev.movetype = pData.m_eOldMovetype;    // give them the preserved movetype... --xWhitey
        
        return;
    }
    
    g_EngineFuncs.AngleVectors( pPlayer.pev.v_angle, vecForward, vecRight, vecUp );
    
    // Block their ability to shoot, they're having a fucking rope in their hands.
    pPlayer.BlockWeapons( pRope.GetSelf( ) );
    
    // Not moving anywhere.
    pPlayer.pev.velocity = g_vecZero;
    
    // Fake that they're on a ladder lol.   --xWhitey
    pPlayer.pev.movetype = MOVETYPE_FLY;

    vecAttachPos = pRope.GetAttachedObjectsPosition( );

    // And move them into the rope itself.
    pPlayer.pev.origin = vecAttachPos;
    
////////////////////////////////////////////////
// Compute the force
// Each button press is processed on its own

    if ( ( pPlayer.pev.button & IN_MOVERIGHT ) != 0 )
    {
        vecForce.x = vecRight.x;
        vecForce.y = vecRight.y;
        vecForce.z = 0.0f;

        pRope.ApplyForceFromPlayer( vecForce );
    }

    if ( ( pPlayer.pev.button & IN_MOVELEFT ) != 0 )
    {
        vecForce.x = vecRight.x * -1.0f;
        vecForce.y = vecRight.y * -1.0f;
        vecForce.z = 0.0f;
        
        pRope.ApplyForceFromPlayer( vecForce );
    }

    // Determine if any force should be applied to the rope, or if we should move around. - Solokiller
    if ( ( pPlayer.pev.button & ( IN_BACK | IN_FORWARD ) ) != 0 )
    {
        if ( (  vecForward.x * vecForward.x +
                vecForward.y * vecForward.y -
                vecForward.z * vecForward.z ) <= 0.0f )
        {
            if ( pData.m_fIsClimbing )
            {
                const float flDelta = g_Engine.time - pData.m_flLastClimbTime;
                pData.m_flLastClimbTime = g_Engine.time;

                if ( ( pPlayer.pev.button & IN_FORWARD ) != 0 )
                {   // Holding W
                    if ( vecForward.z < 0.0f )
                    {   // Looking down
                        if ( !pRope.MoveDown( flDelta ) )
                        {
                            // Let go of the rope, detach. - Solokiller
                            // ^ Because we reached the end of the rope. --xWhitey
                            pPlayer.UnblockWeapons( pRope.GetSelf( ) );
                            pPlayer.pev.movetype = pData.m_eOldMovetype;
                            CheckPlayerStuck( pPlayer );

                            pRope.DetachObject( );  // Fling them away off me!
                            
                            // Not on a rope anymore.
                            @pData.m_pMasterRope = null;
                            pData.m_fIsOnRope = FALSE;
                            pData.m_fIsClimbing = FALSE;
                            pData.m_flDetachTime = g_Engine.time;
                            @pData.m_pPreviouslyHangingRope = pRope;
                        }
                    }
                    else
                    {   // Looking up
                        pRope.MoveUp( flDelta );
                    }
                }
                if ( ( pPlayer.pev.button & IN_BACK ) != 0 )
                {   // Holding S
                    if ( vecForward.z > 0.0f )
                    {
                        if ( !pRope.MoveDown( flDelta ) )
                        {
                            // Let go of the rope, detach. - Solokiller
                            // ^ Because we reached the end of the rope. --xWhitey
                            pPlayer.UnblockWeapons( pRope.GetSelf( ) );
                            pPlayer.pev.movetype = pData.m_eOldMovetype;
                            CheckPlayerStuck( pPlayer );

                            pRope.DetachObject( );  // Fling them away off me!
                            
                            // Not on a rope anymore.
                            @pData.m_pMasterRope = null;
                            pData.m_fIsOnRope = FALSE;
                            pData.m_fIsClimbing = FALSE;
                            pData.m_flDetachTime = g_Engine.time;
                            @pData.m_pPreviouslyHangingRope = pRope;
                        }
                    } else {
                        pRope.MoveUp( flDelta );
                    }
                }
            } else {
                pData.m_fIsClimbing = TRUE;
                pData.m_flLastClimbTime = g_Engine.time;
            }
        }
        else
        {
            // Assume moving up
            vecForce.x = vecForward.x;
            vecForce.y = vecForward.y;
            vecForce.z = 0.0f;
            
            if ( ( pPlayer.pev.button & IN_BACK ) != 0 )
            {
                vecForce.x = vecForward.x * -1.0f;
                vecForce.y = vecForward.y * -1.0f;
                vecForce.z = 0.0f;
            }
            
            pRope.ApplyForceFromPlayer( vecForce );
            pData.m_fIsClimbing = FALSE;
        }
    }
    else
    {
        pData.m_fIsClimbing = FALSE;
    }

    if ( ( pPlayer.m_afButtonPressed & IN_JUMP ) != 0 )
    {   // We've jumped off the rope, give us some momentum - Solokiller
        Vector vecDir, vecVelocity;
        
        // Now their fucking hands are free.
        pPlayer.UnblockWeapons( pRope.GetSelf( ) );
        CheckPlayerStuck( pPlayer );
        
        // Restore movetype.
        pPlayer.pev.movetype = pData.m_eOldMovetype;
        
        pData.m_fIsOnRope = FALSE;

        vecDir = vecUp * 165.0 + vecForward * 150.0; // TODO: Why are these some magic numbers? Turn these into constants.

        vecVelocity = pRope.GetAttachedObjectsVelocity( ) * 2;
        vecVelocity = vecVelocity.Normalize( );
        vecVelocity = vecVelocity * 200.0f;

        // Whoosh
        pPlayer.pev.velocity = vecVelocity + vecDir;

        pRope.DetachObject( );
        @pData.m_pMasterRope = null;
        pData.m_fIsClimbing = FALSE;
        pData.m_flDetachTime = g_Engine.time;
        @pData.m_pPreviouslyHangingRope = pRope;
        
        return;
    }
    
    @g_rgpfnPlayerOnARopeThink[ pPlayer.entindex( ) ] = g_Scheduler.SetTimeout( "PlayerOnARopeThink", 0.0f, EHandle( pPlayer ) );
}

CRopeSegment@ UTIL_CreateSegment( CRopeSample@ _Sample, const string& in _ModelName, CRope@ _Rope )
{
    CBaseEntity@    pEntity = null;
    CRopeSegment@   pSegment = null;
    
    @pEntity = g_EntityFuncs.Create( "rope_segment", g_vecZero, g_vecZero, TRUE, null );
    if ( pEntity is null )
    {
        return null;
    }
    
    if ( g_EntityFuncs.DispatchSpawn( pEntity.edict( ) ) < 0 )
    {
        g_Log.PrintF( "[Ropes] UTIL_CreateSegment: DispatchSpawn returned < 0!\n" );
        return null;
    }
    
    @pSegment = cast< CRopeSegment@ >( CastToScriptClass( pEntity ) );

    pSegment.m_szModelName = _ModelName;
    pSegment.Spawn( );

    @pSegment.m_pSample = _Sample;

    pSegment.m_bCauseDamage = FALSE;    // Wow bruh why?
    pSegment.m_bCanBeGrabbed = TRUE;
    pSegment.m_flDefaultMass = _Sample.GetData().m_flMassReciprocal;
    pSegment.SetMasterRope( _Rope );

    return pSegment;
}

CRopeSample@ UTIL_CreateSample( void )
{
    CBaseEntity@ pEntity = null;
    CRopeSample@ pSample = null;

    @pEntity = g_EntityFuncs.Create( "rope_sample", g_vecZero, g_vecZero, TRUE, null );
    if ( pEntity is null )
    {
        return null;
    }
    
    if ( g_EntityFuncs.DispatchSpawn( pEntity.edict( ) ) < 0 )
    {
        g_Log.PrintF( "[Ropes] UTIL_CreateSample: DispatchSpawn returned < 0!\n" );
        return null;
    }
    
    @pSample = cast< CRopeSample@ >( CastToScriptClass( pEntity ) );
    pSample.Spawn( );

    return pSample;
}

//-----------------------------------------------------------------------------
// Plugin Implementation
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// Purpose: Represents a single joint in a rope. There are numSegments + 1 samples in a rope.
//-----------------------------------------------------------------------------
class CRopeSample : ScriptBaseEntity
{
    CRopeSample( void )
    {
        @m_pData = CRopeSampleData( );
    }

    CBaseEntity@ GetSelf( void )
    {
        return self;
    }
    
    void Spawn( void )
    {
        self.pev.effects |= EF_NODRAW;  // Should be not sent to the clients, although we don't even have a model, this is JIC. --xWhitey
    }
    
    // Moved to UTIL_CreateSample
//  static CRopeSample* CreateSample(); 

    CRopeSampleData@ GetData( void )
    {
        return m_pData;
    }

    CRopeSampleData@ m_pData;
};

//-----------------------------------------------------------------------------
// Purpose: A rope segment
//-----------------------------------------------------------------------------
class CRopeSegment : ScriptBaseAnimating
{
    CRopeSample@    m_pSample;
    string          m_szModelName;
    float           m_flDefaultMass;
    bool            m_bCauseDamage;
    bool            m_bCanBeGrabbed;
    CRope@          m_pMasterRope;
    float           m_flNextDamageTime;
    
    CBaseEntity@ GetSelf( void )
    {
        return self;
    }

    void Precache( void )
    {
        BaseClass.Precache( );
        
        if ( m_szModelName.IsEmpty( ) )
        {
            m_szModelName = "models/rope16.mdl";
        }

        g_Game.PrecacheModel( m_szModelName );
        g_Game.PrecacheGeneric( "sound/hlcancer/op4/rope/grab_rope.wav" );
        g_SoundSystem.PrecacheSound( "hlcancer/op4/rope/grab_rope.wav" );
    }

    void Spawn( void )
    {
        Precache( );

        g_EntityFuncs.SetModel( self, m_szModelName );

        self.pev.movetype = MOVETYPE_NOCLIP;
        self.pev.solid = SOLID_TRIGGER;
        self.pev.effects = EF_NODRAW;   // It is not sent to the clients
        SetAbsOrigin( self.pev.origin );

        // HACKHACK: Get rid of this
        // This is used to detect collision with the rope for Touch function
        g_EntityFuncs.SetSize( self.pev, Vector( -30.0f, -30.0f, -30.0f ), Vector( 30.0f, 30.0f, 30.0f ) );

        self.pev.nextthink = g_Engine.time + 0.5f;
    }

    void Touch( CBaseEntity@ _Toucher )
    {
        CBasePlayer@    pPlayer = null;
        CPlayerData@    pData   = null;
        Observer@       pObserver = null;
        CRope@          pMasterRope = GetMasterRope( );
        
        if ( pMasterRope is null )
        {
            return;
        }
    
        if ( !_Toucher.IsPlayer( ) || !_Toucher.IsAlive( ) )
        {
            return;
        }
    
        @pPlayer = cast< CBasePlayer@ >( _Toucher );
        @pData = g_rgpPlayerDatas[ pPlayer.entindex( ) ];
        @pObserver = pPlayer.GetObserver( );
        
        if ( pData is null )
        {
            return;
        }
        
        if ( pObserver !is null )
        {
            if ( pObserver.IsObserver( ) )
            {
                return;
            }
        }

        // Electrified wires deal damage. - Solokiller
        if ( m_bCauseDamage )
        {
            // Like trigger_hurt we need to deal half a second's worth of damage per touch to make this frametime-independent.
            if ( m_flNextDamageTime < g_Engine.time )
            {   // Time has come --xWhitey
                float flDamagePerHalfSecond = 30.0f / 2.0f;   // 1 damage per tick is 30 damage per second at 30 FPS.
                _Toucher.TakeDamage( self.pev, self.pev, flDamagePerHalfSecond, DMG_SHOCK );
                m_flNextDamageTime = g_Engine.time + 0.5f;
            }
        }
        
    // the main rope is just a decoration or it's an electrified cable
        if ( !pMasterRope.IsAcceptingAttachment( ) )
        {
            return;
        }
        
    // allready on a rope
        if ( pData.m_fIsOnRope ) 
        {
            return;
        }
        
    // have recently been on this rope?
        if ( g_Engine.time < pData.m_flDetachTime + DETACH_PERIODICITY )
        {
            if ( pData.m_pPreviouslyHangingRope is m_pMasterRope )
            {
                return;
            }
        }

        if ( m_bCanBeGrabbed )
        {
            CRopeSampleData@ pSampleData = m_pSample.GetData( );

            // Move them onto the rope.
            g_EntityFuncs.SetOrigin( _Toucher, pSampleData.m_vecPosition );

            @pData.m_pMasterRope = pMasterRope;
            pData.m_fIsOnRope = TRUE;
            pData.m_eOldMovetype = pPlayer.pev.movetype;
            pData.m_flStartedClimbing = g_Engine.time;
            pMasterRope.AttachObjectToSegment( @this );
            @g_rgpfnPlayerOnARopeThink[ pPlayer.entindex( ) ] = g_Scheduler.SetTimeout( "PlayerOnARopeThink", 0.0f, EHandle( pPlayer ) );

            // See if they jumped onto the rope, if so, make the rope react to this.
            if ( _Toucher.pev.velocity.Length( ) >= 320.0f )
            {   // Apply some external force to move the rope. - Solokiller
                pSampleData.m_bApplyExternalForce = TRUE;

                pSampleData.m_vecExternalForce = pSampleData.m_vecExternalForce + _Toucher.pev.velocity * 550.0f;
            }

            if ( pMasterRope.IsSoundAllowed( ) )
            {
                g_SoundSystem.EmitSound( self.edict( ), CHAN_BODY, "hlcancer/op4/rope/grab_rope.wav", 1.0f, ATTN_NORM );
            }
        }
        else
        {   // This segment cannot be grabbed (probably an anchor point), so grab the highest one if possible. - Solokiller
            CRopeSegment@ pSegment;

            if ( pMasterRope.GetNumSegments( ) <= ROPE_IGNORE_SAMPLES )
            {
                // Fewer than ROPE_IGNORE_SAMPLES segments exist, so allow grabbing the last one. - Solokiller
                @pSegment = pMasterRope.GetSegments( )[ pMasterRope.GetNumSegments() - 1 ];
                pSegment.SetCanBeGrabbed( TRUE );
            }
            else
            {   // Wow edge case
                @pSegment = pMasterRope.GetSegments( )[ ROPE_IGNORE_SAMPLES ];
            }

            pSegment.Touch( _Toucher );
        }
    }

    void SetAbsOrigin( const Vector& in _Position )
    {
        self.pev.origin = _Position;
    }

    // Moved to UTIL_CreateSegment
//  static CRopeSegment* CreateSegment(CRopeSample* pSample, string_t iszModelName , CRope *rope);

    CRopeSample@ GetSample( void )
    {
        return m_pSample;
    }

    void ApplyExternalForce( const Vector& in _Force )
    {
        CRopeSampleData@ pSampleData = m_pSample.GetData( );
            
        pSampleData.m_bApplyExternalForce = TRUE ;

        pSampleData.m_vecExternalForce = pSampleData.m_vecExternalForce + _Force;
    }

    void SetCauseDamageOnTouch( const bool _CauseDamage )
    {
        m_bCauseDamage = _CauseDamage;
    }
    
    void SetCanBeGrabbed( const bool _CanBeGrabbed )
    {
        m_bCanBeGrabbed = _CanBeGrabbed;
    }
    
    CRope@ GetMasterRope( void )
    {
        return m_pMasterRope;
    }
    
    void SetMasterRope( CRope@ _Rope )
    {
        @m_pMasterRope = _Rope;
    }
};

//-----------------------------------------------------------------------------
// Purpose: A rope with a number of segments.
//          Uses a Verlet integrator with dampened springs to simulate rope physics.
//-----------------------------------------------------------------------------
class CRope : ScriptBaseAnimating {
    array< CRopeSegment@ > m_rgpSegments; // MAX_SEGMENTS
    uint m_uiSegments;    // Segments amount...

    Vector m_vecLastEndPos;
    Vector m_vecGravity;    // Gravity in "our" system

    array< CRopeSample@ > m_rgpSamples; // MAX_SAMPLES
    uint m_cNumSamples;  // Samples amount...

    // Is there somebody hanging?
    bool m_bObjectAttached;

    uint m_iAttachedObjectsSegment;
    float m_flAttachedObjectsOffset;
    float m_flDetachTime;

    string m_szBodyModel;
    string m_szEndingModel;

    // Players cannot attach the rope
    bool m_bDisallowPlayerAttachment;

    // Make creak sounds?
    bool m_bMakeSound;

    // Is enabled?
    protected bool m_bActivated;
    
    // For fast accessing, avoids GetData
    array< CRopeSampleData@ > m_rgpCachedData;
    
    // Tracks solver convergence
    float m_flConstraintError;
    
    CRope( void )
    {
        m_szBodyModel = "models/rope16.mdl";
        m_szEndingModel = "models/rope16.mdl";
        m_rgpSegments = array< CRopeSegment@ >( MAX_SEGMENTS, null );
        m_rgpSamples = array< CRopeSample@ >( MAX_SAMPLES, null );
    }
    
    CBaseEntity@ GetSelf( void )
    {
        return self;
    }
    
    bool KeyValue( const string& in _Key, const string& in _Value )
    {
        if ( _Key == "segments" )
        {
            int iSegments = atoi( _Value );
            if ( iSegments < 0 )
            {
                m_uiSegments = 0;
                return FALSE;
            }
        
            m_uiSegments = uint( iSegments );

            if ( m_uiSegments >= MAX_SEGMENTS )
            {
                m_uiSegments = MAX_SEGMENTS - 1;
            }
                
            return TRUE;
        }
        else if ( _Key == "bodymodel" )
        {
            m_szBodyModel = _Value;
            
            return TRUE;
        }
        else if ( _Key == "endingmodel" )
        {
            m_szEndingModel = _Value;
            
            return TRUE;
        }
        else if ( _Key == "disable" )
        {
            m_bDisallowPlayerAttachment = atoi( _Value ) != 0;
            
            return TRUE;
        }
        
        return BaseClass.KeyValue( _Key, _Value );
    }

    void Precache( void )
    {
        BaseClass.Precache( );

        g_Game.PrecacheOther( "rope_segment" );
        g_Game.PrecacheOther( "rope_sample" );

        g_Game.PrecacheModel( GetBodyModel( ) );
        g_Game.PrecacheModel( GetEndingModel( ) );
        
        for ( size_t cbIndex = 0; cbIndex < g_rgszCreakSounds.length( ); cbIndex++ )
        {
            g_Game.PrecacheGeneric( "sound/" + g_rgszCreakSounds[ cbIndex ] );
            g_SoundSystem.PrecacheSound( g_rgszCreakSounds[ cbIndex ] );
        }
    }

    void Spawn( void )
    {
        m_bMakeSound = TRUE;

        Precache( );

        m_vecGravity.x = m_vecGravity.y = 0.0f;
        m_vecGravity.z = -800.0f;

        m_bObjectAttached = FALSE;

        m_cNumSamples = m_uiSegments + 1;

        m_bActivated = FALSE;
    }
    
    void Activate( void )
    {
        if ( !m_bActivated )
        {
            InitRope( );
            m_bActivated = TRUE;
        }
    }

    void InitializeCachedData( void )
    {
        uint cbIndex;
    
        m_rgpCachedData.resize( 0 );
        m_rgpCachedData.resize( m_cNumSamples );
        for ( cbIndex = 0; cbIndex < m_cNumSamples; ++cbIndex )
        {
            @m_rgpCachedData[ cbIndex ] = m_rgpSamples[ cbIndex ].GetData( );
        }
    }

    void InitRope( void )
    {
        Vector          vecOrigin, vecAngles, vecNormalizedGravity, vecTemp;
        CRopeSample@    pSegmentSample = null;
        CRopeSegment@   pCurrent = null;
        CBaseEntity@    pEntity = null;
        CBaseAnimating@ pAnimating = null;
        
        for ( uint uiSample = 0; uiSample < m_cNumSamples; ++uiSample )
        {
            @m_rgpSamples[ uiSample ] = UTIL_CreateSample( );
            g_EntityFuncs.SetOrigin( m_rgpSamples[ uiSample ].GetSelf( ), self.pev.origin );
        }

        {
            @m_rgpSegments[ 0 ] = UTIL_CreateSegment( m_rgpSamples[ 0 ], GetBodyModel( ), @this );
            m_rgpSegments[ 0 ].SetAbsOrigin( self.pev.origin );
        }

        vecNormalizedGravity = m_vecGravity.Normalize( );

        if ( m_uiSegments > 2 )
        {
            for ( uint uiSeg = 1; uiSeg < m_uiSegments - 1; ++uiSeg )
            {
                @pSegmentSample = m_rgpSamples[ uiSeg ];
                @m_rgpSegments[ uiSeg ] = UTIL_CreateSegment( pSegmentSample, GetBodyModel( ), @this );
                
                @pCurrent = m_rgpSegments[ uiSeg - 1 ];
                @pEntity = pCurrent.GetSelf( );
                @pAnimating = cast< CBaseAnimating@ >( pEntity );
                pAnimating.GetAttachment( 0, vecOrigin, vecAngles );
                
                vecTemp = ( vecOrigin - pCurrent.pev.origin );
                vecOrigin = vecTemp.Length( ) * vecNormalizedGravity + pCurrent.pev.origin;

                m_rgpSegments[ uiSeg ].SetAbsOrigin( vecOrigin );
            }
        }

        // Create the last segment.
        @pSegmentSample = m_rgpSamples[ m_uiSegments - 1 ];
        @m_rgpSegments[ m_uiSegments - 1 ] = UTIL_CreateSegment( pSegmentSample, GetEndingModel( ), @this );

        @pCurrent = m_rgpSegments[ m_uiSegments - 2 ];
        @pEntity = pCurrent.GetSelf( );
        @pAnimating = cast< CBaseAnimating@ >( pEntity );
        pAnimating.GetAttachment( 0, vecOrigin, vecAngles );
        
        vecTemp = ( vecOrigin - pCurrent.pev.origin );
        vecOrigin = vecTemp.Length( ) * vecNormalizedGravity + pCurrent.pev.origin;

        m_rgpSegments[ m_uiSegments - 1 ].SetAbsOrigin( vecOrigin );

        InitializeRopeSim( );
        InitializeCachedData( );

        SetThink( ThinkFunction( RopeThink ) );
        self.pev.nextthink = g_Engine.time + 0.01f;
    }
    
    void RopeThink( void )
    {
        array< CRopeSegment@ >@ ppPrimarySegs = null;
    
        RunSimOnSamples( );

        @ppPrimarySegs = GetSegments( );
        SetRopeSegments( m_uiSegments, ppPrimarySegs );

        if ( ShouldCreak( ) )
        {
            Creak( );
        }

        self.pev.nextthink = g_Engine.time + ( 1.0f / ROPE_FRAMERATE );
    }

    // Initializes the rope simulation data.
    void InitializeRopeSim( void )
    {
        uint            uiIndex;
        CRopeSegment@   pSegment = null;
        CRopeSample@    pSample = null;
        CRopeSampleData@ pSampleData = null;
        Vector          vecOrigin, vecAngles, vecTemp, vecNormalizedGravity;
        uint            uiNumSegs = ROPE_IGNORE_SAMPLES;

        for ( uiIndex = 0; uiIndex < m_uiSegments; ++uiIndex )
        {
            @pSegment = m_rgpSegments[ uiIndex ];
            @pSample = pSegment.GetSample( );
            @pSampleData = pSample.GetData( );

            pSampleData.m_vecPosition = pSegment.pev.origin;

            pSampleData.m_vecVelocity = g_vecZero;
            pSampleData.m_vecForce = g_vecZero;
            pSampleData.m_flMassReciprocal = 1.0f;
            pSampleData.m_bApplyExternalForce = FALSE;
            pSampleData.m_vecExternalForce = g_vecZero;
            
            vecTemp = ( pSegment.pev.origin - GetSegmentAttachmentPoint( uiIndex ) );
            pSampleData.m_flRestLength = vecTemp.Length( );
        }

        {
            // Zero out the anchored segment's mass so it stays in place.
            @pSample = m_rgpSamples[ 0 ];
            @pSampleData = pSample.GetData();

            pSampleData.m_flMassReciprocal = 0.0f;
        }

        @pSegment = m_rgpSegments[ m_uiSegments - 1 ];
        
        vecNormalizedGravity = m_vecGravity.Normalize( );
        vecOrigin = GetSegmentAttachmentPoint( m_uiSegments - 1 ) * vecNormalizedGravity + pSegment.pev.origin;

        @pSample = m_rgpSamples[ m_cNumSamples - 1 ];
        @pSampleData = pSample.GetData( );

        pSampleData.m_vecPosition = vecOrigin;
        pSampleData.m_vecOldPosition = pSampleData.m_vecPosition; // Initialize previous position

        m_vecLastEndPos = vecOrigin;

        pSampleData.m_vecVelocity = g_vecZero;
        pSampleData.m_vecForce = g_vecZero;
        pSampleData.m_flMassReciprocal = 0.25f; // TODO: Why magic number?
        pSampleData.m_bApplyExternalForce = FALSE;

        if ( m_uiSegments <= ROPE_IGNORE_SAMPLES )
        {
            uiNumSegs = m_uiSegments;
        }

        for ( uiIndex = 0; uiIndex < uiNumSegs; ++uiIndex )
        {
            m_rgpSegments[ uiIndex ].SetCanBeGrabbed( FALSE );
        }
        
        // Walk thru the ignored samples
        for ( uiIndex = 0; uiIndex < uiNumSegs; ++uiIndex )
        {
            @pSampleData = m_rgpSamples[ uiIndex ].GetData( );
            pSampleData.m_flMassReciprocal = 0.0f; // Infinite mass, fixed point
        }
    }

    // Runs simulation on the samples.
    void RunSimOnSamples( void )
    {
        // Compute forces
        ComputeForces( );

        // Integrate positions and velocities using Verlet integration
        VerletIntegrate( 1.0f / ROPE_FRAMERATE /* flDeltaTime */ );
    }

   void ComputeForces( void )
   {
        uint                cbIndex;
        CRopeSampleData@    pSampleData = null;
        
        for ( cbIndex = 0; cbIndex < m_cNumSamples; ++cbIndex) {
            @pSampleData = m_rgpCachedData[ cbIndex ];

            // Reset force
            pSampleData.m_vecForce = g_vecZero;

            // Apply gravity, if not an anchor point (moved to the integrator)
//          if ( pSampleData.m_flMassReciprocal != 0.0f )
//          {
//              pSampleData.m_vecForce = pSampleData.m_vecForce + ( m_vecGravity / pSampleData.m_flMassReciprocal );
//          }

            // Apply external forces
            if ( pSampleData.m_bApplyExternalForce )
            {
                pSampleData.m_vecForce = pSampleData.m_vecForce + pSampleData.m_vecExternalForce;
                pSampleData.m_vecExternalForce = g_vecZero;
                pSampleData.m_bApplyExternalForce = FALSE;
            }

            // Damping force (optional)
            pSampleData.m_vecForce = pSampleData.m_vecForce - ( pSampleData.m_vecVelocity * SPRING_DAMPING );
        }
    }

    void VerletIntegrate( const float flDeltaTime )
    {
        const float         flDeltaTimeSq = flDeltaTime * flDeltaTime;
        uint                cbIndex;
        CRopeSampleData@    pSampleData = null;
        Vector              vecAcceleration, vecCurrentPosition;
        
        m_flConstraintError = 0.0f;

        for ( cbIndex = 0; cbIndex < m_cNumSamples; ++cbIndex) {
            @pSampleData = m_rgpCachedData[ cbIndex ];

            // If mass is infinite (anchor point), skip integration
            if ( pSampleData.m_flMassReciprocal == 0.0f )
            {
                pSampleData.m_vecVelocity = g_vecZero;
                pSampleData.m_vecOldPosition = pSampleData.m_vecPosition;
                continue;
            }

            // Calculate acceleration
            vecAcceleration = ( pSampleData.m_vecForce * pSampleData.m_flMassReciprocal ) + m_vecGravity;

        // preserve current position
            vecCurrentPosition = pSampleData.m_vecPosition;

            if ( pSampleData.m_vecOldPosition == g_vecZero )
            {
                // First iteration, estimate previous position
                pSampleData.m_vecOldPosition = pSampleData.m_vecPosition - pSampleData.m_vecVelocity * flDeltaTime;
            }

            // Verlet integration formula
            pSampleData.m_vecPosition = ( 2.0f * pSampleData.m_vecPosition ) - pSampleData.m_vecOldPosition + vecAcceleration * flDeltaTimeSq;

            // Update velocity (optional, for damping or output)
            pSampleData.m_vecVelocity = ( pSampleData.m_vecPosition - pSampleData.m_vecOldPosition ) / ( 2.0f * flDeltaTime );

            // Prepare for next iteration
            pSampleData.m_vecOldPosition = vecCurrentPosition;
        }

        // After integration, apply constraints to enforce rope segment lengths
        ApplyConstraints();
    }
    
    void ApplyConstraints( void )
    {
        const float EPSILON_SQ = 1e-12f;
        const float REST_TOLERANCE_SQ = 0.005f; // ~0.5% length tolerance squared
        
        uint                cbIndex, nIteration, nIterations = APPLY_CONSTRAINTS_ITERATIONS;
        CRopeSampleData@    pOne = null;
        CRopeSampleData@    pTwo = null;
        Vector              vecDelta, vecCorrection;
        float               flDeltaMagnitudeSqr, flDeltaMagnitude, flDiff, flRestLengthSqr, flError;
        
        if ( m_flConstraintError < 0.01f )
            nIterations = Math.max( 2, APPLY_CONSTRAINTS_ITERATIONS / 2 );

        for ( nIteration = 0; nIteration < APPLY_CONSTRAINTS_ITERATIONS; ++nIteration )
        {
            bool fConverged = true;
        
            for ( cbIndex = 0; cbIndex < m_uiSegments; ++cbIndex )
            {
                @pOne = m_rgpCachedData[ cbIndex ];
                @pTwo = m_rgpCachedData[ cbIndex + 1 ];

                vecDelta = pTwo.m_vecPosition - pOne.m_vecPosition;
                flDeltaMagnitudeSqr = ( vecDelta.x * vecDelta.x ) + ( vecDelta.y * vecDelta.y ) + ( vecDelta.z * vecDelta.z ); // DotProduct( vecDelta, vecDelta ); // delta.Length( ) * delta.Length( );

                flRestLengthSqr = pOne.m_flRestLength * pOne.m_flRestLength;

                // Skip if within tolerance (flDiff = error)
                flError = abs( flDeltaMagnitudeSqr - flRestLengthSqr );
                if ( flError < REST_TOLERANCE_SQ * flRestLengthSqr )
                    continue;

                if ( flDeltaMagnitudeSqr < EPSILON_SQ )
                {
                    continue;
                }
                
                flDeltaMagnitude = sqrt( flDeltaMagnitudeSqr );
                flDiff = ( flDeltaMagnitude - pOne.m_flRestLength ) / flDeltaMagnitude;
                
                vecCorrection = vecDelta * 0.5f * flDiff;
                
                // Apply correction based on mass
                if ( pOne.m_flMassReciprocal != 0.0f )
                {
                    pOne.m_vecPosition = pOne.m_vecPosition + vecCorrection;
                    fConverged = FALSE;
                }
                if ( pTwo.m_flMassReciprocal != 0.0f )
                {
                    pTwo.m_vecPosition = pTwo.m_vecPosition - vecCorrection;
                    fConverged = FALSE;
                }
                
                if ( flError > m_flConstraintError )
                {
                    m_flConstraintError = flError;
                }
            }
            
            if ( fConverged )
            {   // Early exit if all constraints satisfied
                break;
            }
        }
    }
    
    void TraceModels( array< CRopeSegment@ >@ pSegments )
    {
        TraceResult     tr;
        uint            cbIndex;
        CRopeSample@    pSample = null;
        CRopeSegment@   pSegment = null;
        Vector          vecDist, vecTraceDist, vecEnd, vecOrigin, vecAngles;
        float           flTraceDist, flVelocitySqr;
        bool            fNeedsTracing;
        CRopeSampleData@ pSampleData = null;
        
        if ( m_uiSegments > 1 )
        {
            GetAlignmentAngles( m_rgpCachedData[ 0 ].m_vecPosition, m_rgpCachedData[ 1 ].m_vecPosition, vecAngles );
            pSegments[ 0 ].pev.angles = vecAngles;
        }

        for ( cbIndex = 1; cbIndex < m_uiSegments; ++cbIndex )
        {
            @pSample = m_rgpSamples[ cbIndex ];
            @pSampleData = m_rgpCachedData[ cbIndex ];
            
            vecDist = pSampleData.m_vecPosition - pSegments[ cbIndex ].pev.origin;
            vecDist = vecDist.Normalize( );
            
            flVelocitySqr = ( pSampleData.m_vecVelocity.x * pSampleData.m_vecVelocity.x ) + ( pSampleData.m_vecVelocity.y * pSampleData.m_vecVelocity.y ) + ( pSampleData.m_vecVelocity.z * pSampleData.m_vecVelocity.z );
            fNeedsTracing = ( flVelocitySqr > 400.0f ) || m_bObjectAttached || ( cbIndex <= 2 ) || ( cbIndex >= m_uiSegments - 2 );

            if ( fNeedsTracing )
                {
                if ( m_bObjectAttached )
                {   // Adjust trace distance if an object is attached
                    flTraceDist = ( cbIndex - m_iAttachedObjectsSegment + 2 ) < 5 ? 50.0f : 10.0f;  // Why?
                }
                else
                {
                    flTraceDist = 10.0f;
                }

                vecTraceDist = vecDist * flTraceDist;
                vecEnd = pSampleData.m_vecPosition + vecTraceDist;

                g_Utility.TraceLine( pSegments[ cbIndex ].pev.origin, vecEnd, ignore_monsters, self.edict( ), tr );

                if ( tr.flFraction != 1.0f || tr.fStartSolid == 1 || tr.fInOpen == 0 )
                {
                    vecOrigin = tr.vecEndPos - vecTraceDist;
                    TruncateEpsilon( vecOrigin, vecOrigin );
                    pSegments[ cbIndex ].SetAbsOrigin( vecOrigin );

                    pSampleData.m_bApplyExternalForce = TRUE;
                    pSampleData.m_vecExternalForce = tr.vecPlaneNormal.Normalize() * 20000.0f;
                    pSampleData.m_vecVelocity = g_vecZero;
                }
                else
                {
                    vecOrigin = pSampleData.m_vecPosition;
                    TruncateEpsilon(vecOrigin, vecOrigin);
                    pSegments[ cbIndex ].SetAbsOrigin(vecOrigin);
                }
            }
            else
            {
                vecOrigin = pSampleData.m_vecPosition;
                TruncateEpsilon(vecOrigin, vecOrigin);
                pSegments[ cbIndex ].SetAbsOrigin(vecOrigin);
            }
        }

        // Update segment angles
        for ( cbIndex = 1; cbIndex < m_uiSegments; ++cbIndex)
        {
            CRopeSegment@ pSegmentPrev = pSegments[ cbIndex - 1 ];
            CRopeSegment@ pSegmentCurr = pSegments[ cbIndex ];
            GetAlignmentAngles( pSegmentPrev.pev.origin, pSegmentCurr.pev.origin, vecAngles );
            pSegmentPrev.pev.angles = vecAngles;
        }

        // Handle the last segment's orientation
        if ( m_uiSegments > 1 )
        {
            @pSample = m_rgpSamples[ m_cNumSamples - 1 ];
            @pSampleData = m_rgpCachedData[ m_cNumSamples - 1 ];
            
            g_Utility.TraceLine( m_vecLastEndPos, pSampleData.m_vecPosition, ignore_monsters, self.edict( ), tr );

            if ( tr.flFraction == 1.0f )
            {
                m_vecLastEndPos = pSampleData.m_vecPosition;
            }
            else
            {
                m_vecLastEndPos = tr.vecEndPos;
                pSampleData.m_bApplyExternalForce = TRUE;
                pSampleData.m_vecExternalForce = tr.vecPlaneNormal.Normalize() * 4000.0f;
            }

            @pSegment = pSegments[ m_cNumSamples - 2 ];
            GetAlignmentAngles( pSegment.pev.origin, m_vecLastEndPos, vecAngles );
            pSegment.pev.angles = vecAngles;
        }
    }

    void SetRopeSegments( const uint uiNumSegments, array< CRopeSegment@ >@ pSegments )
    {
        uint            cbIndex;
        CRopeSegment@   pSegment = null;
    
        if ( uiNumSegments <= 0 )
        {
            return;
        }
        
        TraceModels( pSegments );
        pSegments[ 0 ].pev.solid = SOLID_TRIGGER;
        pSegments[ 0 ].pev.effects = 0;

        for ( cbIndex = 1; cbIndex < uiNumSegments; ++cbIndex )
        {
            @pSegment = pSegments[ cbIndex ];
            pSegment.pev.solid = SOLID_TRIGGER;
            pSegment.pev.effects = 0;
        }
    }

    /**
    *   Moves the attached object up.
    *   @param flDeltaTime Time between previous and current movement.
    *   @return TRUE if the object is still on the rope, FALSE otherwise.
    */
    bool MoveUp( float flDeltaTime )
    {
        CRopeSegment@ pSegment = null;
    
        if ( m_iAttachedObjectsSegment > 4 )
        {
            float flDistance = flDeltaTime * 128.0f;

            while ( TRUE )
            {
                float flOldDist = flDistance;

                flDistance = 0.0f;

                if ( flOldDist <= 0.0f )
                {
                    break;
                }

                if ( m_iAttachedObjectsSegment <= 3 )
                {
                    break;
                }

                if ( flOldDist > m_flAttachedObjectsOffset )
                {
                    float flNewOffset = 0.0f;
                    
                    flDistance = flOldDist - m_flAttachedObjectsOffset;

                    --m_iAttachedObjectsSegment;

                    if ( m_iAttachedObjectsSegment < m_uiSegments )
                    {
                        @pSegment = @m_rgpSegments[ m_iAttachedObjectsSegment ];
                        flNewOffset = ( pSegment.pev.origin - GetSegmentAttachmentPoint( m_iAttachedObjectsSegment ) ).Length( );
                    }

                    m_flAttachedObjectsOffset = flNewOffset;
                }
                else
                {
                    m_flAttachedObjectsOffset -= flOldDist;
                }
            }
        }

        return TRUE;
    }

    /**
    *   Moves the attached object down.
    *   @param flDeltaTime Time between previous and current movement.
    *   @return TRUE if the object is still on the rope, FALSE otherwise.
    */
    bool MoveDown( float flDeltaTime )
    { 
        CRopeSegment@   pSegment = null;
        float           flDistance = flDeltaTime * 128.0f;
        bool            bOnRope = TRUE;
        bool            bDoIteration = TRUE;
        
        if ( !m_bObjectAttached )
        {
            return FALSE;
        }

        while ( bDoIteration )
        {
            bDoIteration = FALSE;

            if ( flDistance > 0.0f )
            {
                float flNewDist = flDistance;
                float flSegLength = 0.0f;

                while ( bOnRope )
                {
                    float flOffset;
                
                    if ( m_iAttachedObjectsSegment < m_uiSegments )
                    {
                        @pSegment = @m_rgpSegments[ m_iAttachedObjectsSegment ];
                        flSegLength = ( pSegment.pev.origin - GetSegmentAttachmentPoint( m_iAttachedObjectsSegment ) ).Length( );
                    }

                    flOffset = flSegLength - m_flAttachedObjectsOffset;

                    if ( flNewDist <= flOffset )
                    {
                        m_flAttachedObjectsOffset += flNewDist;
                        flDistance = 0.0f;
                        bDoIteration = TRUE;
                        break;
                    }

                    if ( m_iAttachedObjectsSegment + 1 == m_uiSegments )
                    {
                        bOnRope = FALSE;
                    }
                    else
                    {
                        ++m_iAttachedObjectsSegment;
                    }

                    flNewDist -= flOffset;
                    flSegLength = 0.0f;

                    m_flAttachedObjectsOffset = 0;

                    if ( flNewDist <= 0.0f )
                    {
                        break;
                    }
                }
            }
        }

        return bOnRope;
    }

    Vector GetAttachedObjectsVelocity( void )
    {
        if ( !m_bObjectAttached )
        {
            return g_vecZero;
        }

        return m_rgpCachedData[ m_iAttachedObjectsSegment ].m_vecVelocity;
    }

    /**
    *   Applies force from the player. Only applies if there is currently an object attached to the rope.
    *   @param _Force Force.
    */
    void ApplyForceFromPlayer( const Vector& in _Force )
    {
        float   flForce = 20000.0f;
        Vector  vecScaledForce;
        
        if ( g_pConVarPlayerForce is null )
        {
            return;
        }
        
        if ( !m_bObjectAttached )
        {
            return;
        }
        
        // TODO: It should be 20k
        flForce = g_pConVarPlayerForce.GetFloat( );

        if ( m_uiSegments < 26 )    // TODO: Why magic number?
        {
            flForce *= ( float( m_uiSegments ) / 26.0f );
        }

        vecScaledForce = _Force * flForce;
        ApplyForceToSegment( vecScaledForce, m_iAttachedObjectsSegment );
    }

    void ApplyForceToSegment( const Vector& in _Force, uint _Segment )
    {
        CRopeSampleData@ pSampleData = null;
    
        if ( _Segment < m_uiSegments )
        {
            m_rgpSegments[ _Segment ].ApplyExternalForce( _Force );
        }
        else if (_Segment == m_uiSegments )
        {   // Apply force to the last sample.
            @pSampleData = m_rgpCachedData[ _Segment - 1 ];

            pSampleData.m_vecExternalForce = pSampleData.m_vecExternalForce + _Force;
            pSampleData.m_bApplyExternalForce = TRUE;
        }
    }

    void AttachObjectToSegment( CRopeSegment@ _Segment )
    {
        m_bObjectAttached = TRUE;
        m_flDetachTime = 0.0f;
        SetAttachedObjectsSegment( _Segment );
        m_flAttachedObjectsOffset = 0.0f;
    }

    void DetachObject( void )
    {
        m_bObjectAttached = FALSE;
        m_flDetachTime = g_Engine.time;
    }

    bool IsObjectAttached( void )
    {
        return m_bObjectAttached;
    }

    bool IsAcceptingAttachment( void )
    {
        // xWhitey: Now CPlayerData stores m_flDetachTime
//      if ( g_Engine.time - m_flDetachTime > 2.0f && !m_bObjectAttached )
        {
            return !m_bDisallowPlayerAttachment;
        }

//      return FALSE;
    }

    uint GetNumSegments( void )
    {
        return m_uiSegments;
    }

    array< CRopeSegment@ >@ GetSegments( void )
    {
        return @m_rgpSegments;
    }

    bool IsSoundAllowed( void )
    {
        return m_bMakeSound;
    }

    void SetSoundAllowed( bool _Allowed )
    {
        m_bMakeSound = _Allowed;
    }

    bool ShouldCreak( void )
    {
        CRopeSampleData@    pSampleData = null;
    
        if ( !m_bObjectAttached || !m_bMakeSound )
        {
            return FALSE;
        }
        
        @pSampleData = m_rgpCachedData[ m_iAttachedObjectsSegment ];

        if ( pSampleData.m_vecVelocity.Length( ) > 200.0 )   // TODO: Why magic number?
        {
            return Math.RandomLong( 1, 5 ) == 1;
        }

        return FALSE;
    }

    void Creak( void )
    {
        g_SoundSystem.EmitSound( self.edict( ), CHAN_BODY, g_rgszCreakSounds[ Math.RandomLong( 0, g_rgszCreakSounds.length( ) - 1 ) ], VOL_NORM, ATTN_NORM );
    }

    string GetBodyModel( void )
    {
        return m_szBodyModel;
    }
    
    string GetEndingModel( void )
    {
        return m_szEndingModel;
    }
    
    float GetSegmentLength( const uint _SegmentIdx )
    {
        Vector          vecOrigin, vecTemp;
        CRopeSegment@   pSegment = null;
        
        if ( !IsValidSegmentIndex( _SegmentIdx) )
        {
            return 0.0f;
        }
        
        @pSegment = m_rgpSegments[ _SegmentIdx ];
        
        vecOrigin = GetSegmentAttachmentPoint( _SegmentIdx );
        vecTemp = ( pSegment.pev.origin - vecOrigin );

        return vecTemp.Length( );
    }

    float GetRopeLength( void )
    {
        float   flLength = 0.0f;
        uint    cbIndex;

        for ( cbIndex = 0; cbIndex < m_uiSegments; ++cbIndex )
        {
            flLength += GetSegmentLength( cbIndex );
        }

        return flLength;
    }

    Vector GetRopeOrigin( void )
    {
        return m_rgpCachedData[ 0 ].m_vecPosition;
    }

    bool IsValidSegmentIndex( const uint _Segment )
    {
        return _Segment < m_uiSegments;
    }
    
    Vector GetSegmentOrigin( const int _Segment )
    {
        if ( !IsValidSegmentIndex( _Segment ) )
        {
            return g_vecZero;
        }

        return m_rgpCachedData[ _Segment ].m_vecPosition;
    }
    
    Vector GetSegmentAttachmentPoint( const uint _SegmentIdx )
    {
        Vector          vecOrigin, vecAngles;
        CRopeSegment@   pSegment = null;
        CBaseEntity@    pEntity = null;
        CBaseAnimating@ pAnimating = null;

        if ( !IsValidSegmentIndex( _SegmentIdx ) )
        {
            return g_vecZero;
        }
        
        @pSegment = m_rgpSegments[ _SegmentIdx ];
        @pEntity = pSegment.GetSelf( );
        @pAnimating = cast< CBaseAnimating@ >( pEntity );

        // Get the end of the model
        pAnimating.GetAttachment( 0, vecOrigin, vecAngles );

        return vecOrigin;
    }

    void SetAttachedObjectsSegment( CRopeSegment@ _Segment )
    {
        uint cbIndex;
    
        for ( cbIndex = 0; cbIndex < m_uiSegments; ++cbIndex )
        {
            if ( m_rgpSegments[ cbIndex ] is _Segment )
            {
                m_iAttachedObjectsSegment = cbIndex;
                break;
            }
        }
    }

    Vector GetSegmentDirFromOrigin( const uint _SegmentIndex )
    {
        Vector vecResult;
    
        if ( _SegmentIndex >= m_uiSegments )
        {
            return g_vecZero;
        }

        // There is one more sample than there are segments, so this is fine.
        vecResult = m_rgpCachedData[ _SegmentIndex + 1 ].m_vecPosition - m_rgpCachedData[ _SegmentIndex ].m_vecPosition;

        return vecResult.Normalize( );
    }

    Vector GetAttachedObjectsPosition( void )
    {
        Vector vecResult;
        
        if ( !m_bObjectAttached )
        {
            return g_vecZero;
        }

        if ( m_iAttachedObjectsSegment < m_uiSegments )
        {
            vecResult = m_rgpCachedData[ m_iAttachedObjectsSegment ].m_vecPosition;
        }

        vecResult = vecResult + ( m_flAttachedObjectsOffset * GetSegmentDirFromOrigin( m_iAttachedObjectsSegment ) );
        return vecResult;
    }
};

class CElectrifiedWire : CRope
{
    bool m_bIsActive;

    int m_iTipSparkFrequency;
    int m_iBodySparkFrequency;
    int m_iLightningFrequency;

    int m_iXJoltForce;
    int m_iYJoltForce;
    int m_iZJoltForce;

    uint m_uiNumUninsulatedSegments;
    array< uint >@ m_rguiUninsulatedSegments; // MAX_SEGMENTS

    int m_iLightningSprite;

    float m_flLastSparkTime;
    
    CElectrifiedWire( void )
    {
        m_bIsActive = TRUE;
        m_iTipSparkFrequency = 3;
        m_iBodySparkFrequency = 100;
        m_iLightningFrequency = 150;
        m_iXJoltForce = 0;
        m_iYJoltForce = 0;
        m_iZJoltForce = 0;
        m_uiNumUninsulatedSegments = 0;
        @m_rguiUninsulatedSegments = array< uint >( MAX_SEGMENTS );
    }

    bool KeyValue( const string& in _Key, const string& in _Value )
    {
        if ( _Key == "sparkfrequency"  )
        {
            m_iTipSparkFrequency = atoi( _Value );

            return TRUE;
        }
        else if ( _Key == "bodysparkfrequency" )
        {
            m_iBodySparkFrequency = atoi( _Value );

            return TRUE;
        }
        else if ( _Key == "lightningfrequency" )
        {
            m_iLightningFrequency = atoi( _Value );

            return TRUE;
        }
        else if ( _Key == "xforce" )
        {
            m_iXJoltForce = atoi( _Value );

            return TRUE;
        }
        else if( _Key == "yforce" )
        {
            m_iYJoltForce = atoi( _Value );

            return TRUE;
        }
        else if( _Key == "zforce" )
        {
            m_iZJoltForce = atoi( _Value );

            return TRUE;
        }
        
        return CRope::KeyValue( _Key, _Value );
    }

    void Precache( void )
    {
        CRope::Precache( );

        m_iLightningSprite = g_Game.PrecacheModel( "sprites/lgtning.spr" );
    }

    void Spawn( void )
    {
        CRope::Spawn( );
    }

    void Activate( void )
    {
        if ( !m_bActivated )
        {
            InitElectrifiedRope( );
            m_bActivated = TRUE;
        }
    }

    void InitElectrifiedRope( void )
    {
        uint uiIndex;
    
        InitRope();

        m_uiNumUninsulatedSegments = 0;
        m_bIsActive = TRUE;

        if ( m_iBodySparkFrequency > 0 )
        {
            for ( uiIndex = 0; uiIndex < GetNumSegments(); ++uiIndex )
            {
                if( IsValidSegmentIndex( uiIndex ) )
                {
                    m_rguiUninsulatedSegments[ m_uiNumUninsulatedSegments++ ] = uiIndex;
                }
            }
        }

        if( m_uiNumUninsulatedSegments > 0 )
        {
            for ( uiIndex = 0; uiIndex < m_uiNumUninsulatedSegments; ++uiIndex )
            {
                GetSegments( )[ uiIndex ].SetCauseDamageOnTouch( m_bIsActive );
            }
        }

        if( m_iTipSparkFrequency > 0 )
        {
            GetSegments( )[ GetNumSegments() - 1 ].SetCauseDamageOnTouch( m_bIsActive );
        }

        m_flLastSparkTime = g_Engine.time;

        SetSoundAllowed( FALSE );

        self.pev.nextthink = g_Engine.time + 0.01f;
        SetThink( ThinkFunction( ElectrifiedRopeThink ) );
    }

    void ElectrifiedRopeThink( void )
    {
        uint uiIndex;
    
        if ( g_Engine.time - m_flLastSparkTime > 0.1 )
        {
            m_flLastSparkTime = g_Engine.time;

            if ( m_uiNumUninsulatedSegments > 0 )
            {
                for ( uiIndex = 0; uiIndex < m_uiNumUninsulatedSegments; ++uiIndex )
                {
                    if ( ShouldDoEffect( m_iBodySparkFrequency ) )
                    {
                        DoSpark( m_rguiUninsulatedSegments[ uiIndex ], FALSE );
                    }
                }
            }

            if ( ShouldDoEffect( m_iTipSparkFrequency ) )
            {
                DoSpark( GetNumSegments( ) - 1, TRUE );
            }

            if ( ShouldDoEffect( m_iLightningFrequency ) )
            {
                DoLightning( );
            }
        }

        CRope::RopeThink( );
    }

    void Use( CBaseEntity@ pActivator, CBaseEntity@ pCaller, USE_TYPE useType, float flValue )
    {
        uint uiIndex;
    
        m_bIsActive = !m_bIsActive;

        if ( m_uiNumUninsulatedSegments > 0 )
        {
            for ( uiIndex = 0; uiIndex < m_uiNumUninsulatedSegments; ++uiIndex )
            {
                GetSegments( )[ m_rguiUninsulatedSegments[ uiIndex ] ].SetCauseDamageOnTouch( m_bIsActive );
            }
        }

        if ( m_iTipSparkFrequency > 0 )
        {
            GetSegments( )[ GetNumSegments() - 1 ].SetCauseDamageOnTouch( m_bIsActive );
        }
    }

    bool IsActive( void ) const
    {
        return m_bIsActive;
    }
    
    bool ShouldDoEffect( const int iFrequency )
    {
        if ( !IsActive( ) )
        {
            return FALSE;
        }
            
        if ( iFrequency <= 0 )
        {
            return FALSE;
        }

        return Math.RandomLong( 1, iFrequency ) == 1;
    }

    void DoSpark( const uint uiSegment, const bool bExertForce )
    {
        const Vector vecOrigin = GetSegmentAttachmentPoint( uiSegment );

        g_Utility.Sparks( vecOrigin );

        if ( bExertForce )
        {
            const Vector vecSparkForce(
                Math.RandomFloat( -m_iXJoltForce, m_iXJoltForce ),
                Math.RandomFloat( -m_iYJoltForce, m_iYJoltForce ),
                Math.RandomFloat( -m_iZJoltForce, m_iZJoltForce )
            );

            ApplyForceToSegment( vecSparkForce, uiSegment );
        }
    }

    void DoLightning( void )
    {
        uint            uiSegment1 = Math.RandomLong( 0, GetNumSegments( ) - 1 );
        uint            uiSegment2;
        CRopeSegment@   pSegment1;
        CRopeSegment@   pSegment2;
        uint            uiIndex;

        // Try to get a random segment.
        for ( uiIndex = 0; uiIndex < 10; ++uiIndex )
        {
            uiSegment2 = Math.RandomLong( 0, GetNumSegments( ) - 1 );

            if ( uiSegment2 != uiSegment1 )
                break;
        }

        if ( uiIndex >= 10 )
            return;
        
        @pSegment1 = GetSegments( )[ uiSegment1 ];
        @pSegment2 = GetSegments( )[ uiSegment2 ];

        NetworkMessage beam( MSG_PVS, NetworkMessages::SVC_TEMPENTITY, self.pev.origin );
            beam.WriteByte( TE_BEAMENTS );
            beam.WriteShort( pSegment1.GetSelf( ).entindex( ) );
            beam.WriteShort( pSegment2.GetSelf( ).entindex( ) );
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
};
