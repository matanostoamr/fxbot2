#property copyright "Copyright 2026"
#property version   "1.00"
#property strict
#property description "Dual-sided EURUSD harvesting EA with current-market adaptive brakes"

#define EA_TAG              "FX2"
#define MAX_OWNED_POSITIONS 8
#define MAX_OWNED_ORDERS    8
#define MAX_TICK_SAMPLES    1024

input long   InpMagic                         = 26092026;
input double InpLots                          = 0.02;
input double InpTakeProfitPips                = 2.5;
input double InpAnchorServerStopPips          = 50.0;
input double InpBrakeOffsetPips               = 1.0;
input double InpBrakeSoftReleasePips          = 1.0;
input uint   InpBrakeDeadlineMs                = 250;
input uint   InpIntentTimeoutMs                 = 10000;
input uint   InpUnknownIntentQuarantineMs       = 30000;
input uint   InpTimedOutIntentRetentionMinutes  = 1440;
input uint   InpSettlementQuietMs               = 500;
input double InpPolicyResetPips               = 25.0;
input double InpSoftCycleLossGBP              = 3.24;
input double InpHardCycleLossGBP              = 7.79;
input double InpLedgerEscapeTargetGBP         = 0.00;
input double InpExitCommissionPerLotGBP       = 3.50;
input double InpEmergencySlippageReserveGBP   = 0.20;
input double InpUnlinkedChargeReserveGBP       = 0.10;
input uint   InpMaximumAnchorAgeMinutes       = 360;
input uint   InpNoNewRiskBeforeCloseMinutes   = 90;
input uint   InpFridayFlattenMinutes           = 60;
input uint   InpTripleSwapFlattenMinutes      = 30;
input int    InpTripleSwapRolloverHour        = 0;
input int    InpTripleSwapRolloverMinute      = 0;
input double InpEntrySpreadHardMaxPips        = 0.8;
input double InpEntryRange2sMaxPips           = 1.0;
input double InpEntryEwmaDistanceMaxPips      = 0.25;
input uint   InpEntryQuoteMaxAgeMs            = 1000;
input uint   InpMaxDeviationPoints            = 20;
input uint   InpTimerPeriodMs                  = 50;
input uint   InpLeaseStaleSeconds              = 15;

// The engine deliberately uses synchronous OrderSend calls and then reconciles
// broker inventory. Request acceptance is never treated as fill confirmation.

enum CyclePhase
{
   PHASE_FLAT = 0,
   PHASE_ARMING,
   PHASE_DUAL,
   PHASE_ANCHOR,
   PHASE_BRAKE_PENDING,
   PHASE_BRAKED,
   PHASE_FLATTENING,
   PHASE_INVALID
};

enum PositionRole
{
   ROLE_UNKNOWN = 0,
   ROLE_INITIAL_BUY,
   ROLE_INITIAL_SELL,
   ROLE_BRAKE
};

enum ResolveReason
{
   RESOLVE_NONE = 0,
   RESOLVE_HARD_BUDGET,
   RESOLVE_FRIDAY,
   RESOLVE_TRIPLE_SWAP,
   RESOLVE_MAX_AGE,
   RESOLVE_INVARIANT,
   RESOLVE_SOFT_DISTANCE,
   RESOLVE_SOFT_CASH,
   RESOLVE_LEDGER_ESCAPE,
   RESOLVE_RUNTIME_INVALID
};

enum ProtectionResult
{
   PROTECTION_UNCHANGED = 0,
   PROTECTION_REQUESTED,
   PROTECTION_FAILED
};

enum FallbackStage
{
   FALLBACK_NONE = 0,
   FALLBACK_CANCEL_REQUESTED,
   FALLBACK_MARKET_REQUESTED,
   FALLBACK_MARKET_REQUIRED
};

enum IntentOperation
{
   INTENT_NONE = 0,
   INTENT_ARM_FIRST,
   INTENT_ARM_SECOND,
   INTENT_BRAKE_STOP,
   INTENT_BRAKE_CANCEL,
   INTENT_BRAKE_MARKET,
   INTENT_CLOSE_POSITION,
   INTENT_CLOSE_BY,
   INTENT_DELETE_ORDER,
   INTENT_MODIFY_PROTECTION
};

enum IntentStatus
{
   INTENT_STATUS_NONE = 0,
   INTENT_STATUS_PREPARED,
   INTENT_STATUS_ACCEPTED,
   INTENT_STATUS_TIMED_OUT
};

struct PositionRecord
{
   ulong              ticket;
   ulong              identifier;
   ulong              cycle_id;
   ulong              generation;
   PositionRole       role;
   ENUM_POSITION_TYPE type;
   double             volume;
   double             open_price;
   double             sl;
   double             tp;
   double             profit;
   double             swap;
   datetime           open_time;
};

struct OrderRecord
{
   ulong           ticket;
   ulong           cycle_id;
   ulong           generation;
   PositionRole    role;
   ENUM_ORDER_TYPE type;
   double          volume_current;
   double          open_price;
   double          sl;
   double          tp;
   long            setup_time_msc;
};

struct TickSample
{
   long   time_msc;
   double mid;
   double spread_pips;
};

PositionRecord g_positions[MAX_OWNED_POSITIONS];
OrderRecord    g_orders[MAX_OWNED_ORDERS];
TickSample     g_samples[MAX_TICK_SAMPLES];

int           g_position_count             = 0;
int           g_order_count                = 0;
int           g_sample_count               = 0;
int           g_sample_next                = 0;
int           g_entry_admissible_ticks     = 0;

ulong         g_cycle_id                   = 0;
ulong         g_last_cycle_id              = 0;
datetime      g_cycle_start                = 0;
datetime      g_anchor_since               = 0;
CyclePhase    g_phase                      = PHASE_FLAT;
ResolveReason g_resolve_reason             = RESOLVE_NONE;
FallbackStage g_fallback_stage             = FALLBACK_NONE;
bool          g_harvested                  = false;
bool          g_snapshot_invalid           = false;
bool          g_drive_busy                 = false;
bool          g_static_valid               = false;
bool          g_entry_config_valid         = false;
bool          g_arming_second_sent         = false;

MqlTick       g_last_tick;
ulong         g_last_tick_local_msc         = 0;
long          g_brake_cross_tick_msc       = 0;
ulong         g_brake_cross_local_msc      = 0;
ulong         g_last_action_request_id     = 0;
ulong         g_last_result_order          = 0;
ulong         g_brake_order_ticket         = 0;
ulong         g_arming_first_order         = 0;
ulong         g_arming_second_order        = 0;

// One durable single-flight intent. Every broker-mutating request is prepared
// and flushed before OrderSend, then reconciled from inventory + history before
// another request can be emitted. This gives at-most-once submission across
// timer/tick/callback re-ordering and terminal restarts.
IntentOperation g_intent_operation          = INTENT_NONE;
IntentStatus    g_intent_status             = INTENT_STATUS_NONE;
PositionRole   g_intent_role               = ROLE_UNKNOWN;
ENUM_ORDER_TYPE g_intent_order_type         = ORDER_TYPE_BUY;
ulong         g_intent_cycle              = 0;
ulong         g_intent_generation         = 0;
ulong         g_intent_request_id          = 0;
ulong         g_intent_order_ticket        = 0;
ulong         g_intent_deal_ticket         = 0;
ulong         g_intent_target_ticket       = 0;
ulong         g_intent_target_by_ticket    = 0;
double        g_intent_expected_volume     = 0.0;
double        g_intent_target_volume       = 0.0;
double        g_intent_target_by_volume    = 0.0;
datetime      g_intent_submitted_at        = 0;
datetime      g_quarantine_until           = 0;
ulong         g_intent_submitted_local_msc = 0;
// A timed-out request moves here instead of being forgotten. Late inventory
// matching this tombstone is always flattened and can never be adopted into a
// fresh cycle. The bounded retention is deliberately much longer than normal
// broker settlement latency.
IntentOperation g_tomb_operation            = INTENT_NONE;
PositionRole   g_tomb_role                 = ROLE_UNKNOWN;
ulong         g_tomb_cycle                = 0;
ulong         g_tomb_generation           = 0;
ulong         g_tomb_order_ticket         = 0;
double        g_tomb_expected_volume      = 0.0;
datetime      g_tomb_expires              = 0;

double        g_lease_token               = 0.0;
string        g_lease_owner_key           = "";
string        g_lease_heartbeat_key       = "";

string        g_global_prefix               = "";

// -----------------------------------------------------------------------------
// Basic symbol and persistence utilities
// -----------------------------------------------------------------------------

double PipSize()
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return ((digits == 3 || digits == 5) ? 10.0 * point : point);
}

double TickSize()
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0)
      tick_size = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return tick_size;
}

double NormalizePriceNearest(const double price)
{
   const double tick_size = TickSize();
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick_size <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathRound(price / tick_size) * tick_size, digits);
}

double NormalizePriceUp(const double price)
{
   const double tick_size = TickSize();
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(MathCeil((price / tick_size) - 1.0e-10) * tick_size, digits);
}

double NormalizePriceDown(const double price)
{
   const double tick_size = TickSize();
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(MathFloor((price / tick_size) + 1.0e-10) * tick_size, digits);
}

bool NearlyEqual(const double left, const double right)
{
   return (MathAbs(left - right) <= TickSize() * 0.5);
}

bool VolumeEqual(const double left, const double right)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   return (MathAbs(left - right) <= step * 0.25);
}

uint StableInstanceHash(const string text)
{
   uint hash = 2166136261;
   for(int index = 0; index < StringLen(text); ++index)
   {
      hash ^= (uint)StringGetCharacter(text, index);
      hash *= 16777619;
   }
   return hash;
}

bool AcquireInstanceLease()
{
   const datetime now = TimeLocal();
   g_lease_owner_key = StateKey("lease_owner");
   g_lease_heartbeat_key = StateKey("lease_heartbeat");
   g_lease_token = (double)((ulong)now * 100000 + (ulong)(ChartID() % 100000));

   if(!GlobalVariableCheck(g_lease_owner_key))
      GlobalVariableSet(g_lease_owner_key, 0.0);

   double owner = GlobalVariableGet(g_lease_owner_key);
   const datetime heartbeat = (GlobalVariableCheck(g_lease_heartbeat_key)
                               ? (datetime)GlobalVariableGet(g_lease_heartbeat_key) : 0);
   if(owner != 0.0 && owner != g_lease_token && now - heartbeat <= (datetime)InpLeaseStaleSeconds)
      return false;
   if(!GlobalVariableSetOnCondition(g_lease_owner_key, g_lease_token, owner))
      return false;
   if(GlobalVariableSet(g_lease_heartbeat_key, (double)now) == 0)
      return false;
   return (GlobalVariableGet(g_lease_owner_key) == g_lease_token);
}

bool RefreshInstanceLease()
{
   if(g_lease_owner_key == "" || GlobalVariableGet(g_lease_owner_key) != g_lease_token)
      return false;
   return (GlobalVariableSet(g_lease_heartbeat_key, (double)TimeLocal()) != 0);
}

void ReleaseInstanceLease()
{
   if(g_lease_owner_key != "" && g_lease_token != 0.0)
      GlobalVariableSetOnCondition(g_lease_owner_key, 0.0, g_lease_token);
}

string StateKey(const string suffix)
{
   return g_global_prefix + suffix;
}

// Terminal Global Variables store IEEE-754 doubles, so a raw 64-bit ticket can
// lose precision above 2^53. Store each ulong as exact high/low 32-bit words.
void PersistUlong(const string suffix, const ulong value)
{
   const ulong mask = 0xFFFFFFFF;
   GlobalVariableSet(StateKey(suffix + "_hi"), (double)(value >> 32));
   GlobalVariableSet(StateKey(suffix + "_lo"), (double)(value & mask));
}

ulong LoadUlong(const string suffix, const ulong legacy_value = 0)
{
   const string high_key = StateKey(suffix + "_hi");
   const string low_key = StateKey(suffix + "_lo");
   if(!GlobalVariableCheck(high_key) || !GlobalVariableCheck(low_key))
      return legacy_value;
   const ulong high = (ulong)GlobalVariableGet(high_key);
   const ulong low = (ulong)GlobalVariableGet(low_key);
   return (high << 32) | low;
}

bool HasOutstandingIntent()
{
   return (g_intent_operation != INTENT_NONE && g_intent_status != INTENT_STATUS_NONE);
}

void PersistState()
{
   if(g_global_prefix == "")
      return;

   GlobalVariableSet(StateKey("cycle"),       (double)g_cycle_id);
   GlobalVariableSet(StateKey("last_cycle"),  (double)g_last_cycle_id);
   GlobalVariableSet(StateKey("start"),       (double)g_cycle_start);
   GlobalVariableSet(StateKey("anchor"),      (double)g_anchor_since);
   GlobalVariableSet(StateKey("phase"),       (double)g_phase);
   GlobalVariableSet(StateKey("resolve"),     (double)g_resolve_reason);
   GlobalVariableSet(StateKey("harvested"),   (g_harvested ? 1.0 : 0.0));
   GlobalVariableSet(StateKey("fallback"),    (double)g_fallback_stage);
   GlobalVariableSet(StateKey("cross_tick"),  (double)g_brake_cross_tick_msc);
   GlobalVariableSet(StateKey("arm_second"),  (g_arming_second_sent ? 1.0 : 0.0));

   PersistUlong("cycle",          g_cycle_id);
   PersistUlong("last_cycle",     g_last_cycle_id);
   PersistUlong("brake_order",    g_brake_order_ticket);
   PersistUlong("arm_first_id",   g_arming_first_order);
   PersistUlong("arm_second_id",  g_arming_second_order);
   PersistUlong("intent_cycle",   g_intent_cycle);
   PersistUlong("intent_gen",     g_intent_generation);
   PersistUlong("intent_request", g_intent_request_id);
   PersistUlong("intent_order",   g_intent_order_ticket);
   PersistUlong("intent_deal",    g_intent_deal_ticket);
   PersistUlong("intent_target",  g_intent_target_ticket);
   PersistUlong("intent_targetby",g_intent_target_by_ticket);
   PersistUlong("tomb_cycle",     g_tomb_cycle);
   PersistUlong("tomb_gen",       g_tomb_generation);
   PersistUlong("tomb_order",     g_tomb_order_ticket);

   GlobalVariableSet(StateKey("intent_op"),       (double)g_intent_operation);
   GlobalVariableSet(StateKey("intent_status"),   (double)g_intent_status);
   GlobalVariableSet(StateKey("intent_role"),     (double)g_intent_role);
   GlobalVariableSet(StateKey("intent_type"),     (double)g_intent_order_type);
   GlobalVariableSet(StateKey("intent_volume"),   g_intent_expected_volume);
   GlobalVariableSet(StateKey("intent_targetvol"),g_intent_target_volume);
   GlobalVariableSet(StateKey("intent_byvol"),    g_intent_target_by_volume);
   GlobalVariableSet(StateKey("intent_time"),     (double)g_intent_submitted_at);
   GlobalVariableSet(StateKey("quarantine"),      (double)g_quarantine_until);
   GlobalVariableSet(StateKey("tomb_op"),         (double)g_tomb_operation);
   GlobalVariableSet(StateKey("tomb_role"),       (double)g_tomb_role);
   GlobalVariableSet(StateKey("tomb_volume"),     g_tomb_expected_volume);
   GlobalVariableSet(StateKey("tomb_expires"),    (double)g_tomb_expires);
   GlobalVariablesFlush();
}

void LoadState()
{
   if(GlobalVariableCheck(StateKey("cycle")))
      g_cycle_id = (ulong)GlobalVariableGet(StateKey("cycle"));
   if(GlobalVariableCheck(StateKey("last_cycle")))
      g_last_cycle_id = (ulong)GlobalVariableGet(StateKey("last_cycle"));
   g_cycle_id = LoadUlong("cycle", g_cycle_id);
   g_last_cycle_id = LoadUlong("last_cycle", g_last_cycle_id);
   if(g_cycle_id > g_last_cycle_id)
      g_last_cycle_id = g_cycle_id;
   if(GlobalVariableCheck(StateKey("start")))
      g_cycle_start = (datetime)GlobalVariableGet(StateKey("start"));
   if(GlobalVariableCheck(StateKey("anchor")))
      g_anchor_since = (datetime)GlobalVariableGet(StateKey("anchor"));
   if(GlobalVariableCheck(StateKey("phase")))
      g_phase = (CyclePhase)(int)GlobalVariableGet(StateKey("phase"));
   if(GlobalVariableCheck(StateKey("resolve")))
      g_resolve_reason = (ResolveReason)(int)GlobalVariableGet(StateKey("resolve"));
   if(GlobalVariableCheck(StateKey("harvested")))
      g_harvested = (GlobalVariableGet(StateKey("harvested")) > 0.5);
   if(GlobalVariableCheck(StateKey("fallback")))
      g_fallback_stage = (FallbackStage)(int)GlobalVariableGet(StateKey("fallback"));
   if(GlobalVariableCheck(StateKey("cross_tick")))
      g_brake_cross_tick_msc = (long)GlobalVariableGet(StateKey("cross_tick"));
   ulong legacy_brake = 0;
   if(GlobalVariableCheck(StateKey("brake_order")))
      legacy_brake = (ulong)GlobalVariableGet(StateKey("brake_order"));
   g_brake_order_ticket = LoadUlong("brake_order", legacy_brake);
   if(GlobalVariableCheck(StateKey("arm_second")))
      g_arming_second_sent = (GlobalVariableGet(StateKey("arm_second")) > 0.5);
   ulong legacy_first = 0;
   ulong legacy_second = 0;
   if(GlobalVariableCheck(StateKey("arm_first_id")))
      legacy_first = (ulong)GlobalVariableGet(StateKey("arm_first_id"));
   if(GlobalVariableCheck(StateKey("arm_second_id")))
      legacy_second = (ulong)GlobalVariableGet(StateKey("arm_second_id"));
   g_arming_first_order = LoadUlong("arm_first_id", legacy_first);
   g_arming_second_order = LoadUlong("arm_second_id", legacy_second);

   if(GlobalVariableCheck(StateKey("intent_op")))
      g_intent_operation = (IntentOperation)(int)GlobalVariableGet(StateKey("intent_op"));
   if(GlobalVariableCheck(StateKey("intent_status")))
      g_intent_status = (IntentStatus)(int)GlobalVariableGet(StateKey("intent_status"));
   if(GlobalVariableCheck(StateKey("intent_role")))
      g_intent_role = (PositionRole)(int)GlobalVariableGet(StateKey("intent_role"));
   if(GlobalVariableCheck(StateKey("intent_type")))
      g_intent_order_type = (ENUM_ORDER_TYPE)(int)GlobalVariableGet(StateKey("intent_type"));
   if(GlobalVariableCheck(StateKey("intent_volume")))
      g_intent_expected_volume = GlobalVariableGet(StateKey("intent_volume"));
   if(GlobalVariableCheck(StateKey("intent_targetvol")))
      g_intent_target_volume = GlobalVariableGet(StateKey("intent_targetvol"));
   if(GlobalVariableCheck(StateKey("intent_byvol")))
      g_intent_target_by_volume = GlobalVariableGet(StateKey("intent_byvol"));
   if(GlobalVariableCheck(StateKey("intent_time")))
      g_intent_submitted_at = (datetime)GlobalVariableGet(StateKey("intent_time"));
   if(GlobalVariableCheck(StateKey("quarantine")))
      g_quarantine_until = (datetime)GlobalVariableGet(StateKey("quarantine"));
   g_intent_cycle = LoadUlong("intent_cycle");
   g_intent_generation = LoadUlong("intent_gen");
   g_intent_request_id = LoadUlong("intent_request");
   g_intent_order_ticket = LoadUlong("intent_order");
   g_intent_deal_ticket = LoadUlong("intent_deal");
   g_intent_target_ticket = LoadUlong("intent_target");
   g_intent_target_by_ticket = LoadUlong("intent_targetby");
   if(GlobalVariableCheck(StateKey("tomb_op")))
      g_tomb_operation = (IntentOperation)(int)GlobalVariableGet(StateKey("tomb_op"));
   if(GlobalVariableCheck(StateKey("tomb_role")))
      g_tomb_role = (PositionRole)(int)GlobalVariableGet(StateKey("tomb_role"));
   if(GlobalVariableCheck(StateKey("tomb_volume")))
      g_tomb_expected_volume = GlobalVariableGet(StateKey("tomb_volume"));
   if(GlobalVariableCheck(StateKey("tomb_expires")))
      g_tomb_expires = (datetime)GlobalVariableGet(StateKey("tomb_expires"));
   g_tomb_cycle = LoadUlong("tomb_cycle");
   g_tomb_generation = LoadUlong("tomb_gen");
   g_tomb_order_ticket = LoadUlong("tomb_order");
}

bool HasTimedOutTombstone()
{
   return (g_tomb_operation != INTENT_NONE && g_tomb_cycle != 0);
}

void ClearTombstone()
{
   g_tomb_operation = INTENT_NONE;
   g_tomb_role = ROLE_UNKNOWN;
   g_tomb_cycle = 0;
   g_tomb_generation = 0;
   g_tomb_order_ticket = 0;
   g_tomb_expected_volume = 0.0;
   g_tomb_expires = 0;
   PersistState();
}

void ClearIntent()
{
   g_intent_operation = INTENT_NONE;
   g_intent_status = INTENT_STATUS_NONE;
   g_intent_role = ROLE_UNKNOWN;
   g_intent_order_type = ORDER_TYPE_BUY;
   g_intent_cycle = 0;
   g_intent_request_id = 0;
   g_intent_order_ticket = 0;
   g_intent_deal_ticket = 0;
   g_intent_target_ticket = 0;
   g_intent_target_by_ticket = 0;
   g_intent_expected_volume = 0.0;
   g_intent_target_volume = 0.0;
   g_intent_target_by_volume = 0.0;
   g_intent_submitted_at = 0;
   g_intent_submitted_local_msc = 0;
   PersistState();
}

void ClearCycleState()
{
   // Never declare a cycle complete while an accepted/prepared request can
   // still materialize. The intent reconciler clears the barrier first.
   if(HasOutstandingIntent() || HasTimedOutTombstone())
      return;
   g_cycle_id                = 0;
   g_cycle_start             = 0;
   g_anchor_since            = 0;
   g_phase                   = PHASE_FLAT;
   g_resolve_reason          = RESOLVE_NONE;
   g_harvested               = false;
   g_fallback_stage          = FALLBACK_NONE;
   g_brake_cross_tick_msc    = 0;
   g_brake_cross_local_msc   = 0;
   g_brake_order_ticket      = 0;
   g_arming_second_sent      = false;
   g_arming_first_order      = 0;
   g_arming_second_order     = 0;
   g_quarantine_until        = 0;
   PersistState();
}

string RoleCode(const PositionRole role)
{
   if(role == ROLE_INITIAL_BUY)
      return "IB";
   if(role == ROLE_INITIAL_SELL)
      return "IS";
   if(role == ROLE_BRAKE)
      return "BR";
   return "UK";
}

string IntentComment(const PositionRole role, const ulong generation = 0)
{
   if(generation == 0)
      return StringFormat("%s|%I64u|%s", EA_TAG, g_cycle_id, RoleCode(role));
   return StringFormat("%s|%I64u|%s|%I64u", EA_TAG, g_cycle_id, RoleCode(role), generation);
}

PositionRole ParseIntentCommentEx(const string comment, ulong &cycle_id, ulong &generation)
{
   cycle_id = 0;
   generation = 0;
   if(StringFind(comment, EA_TAG + "|") != 0)
      return ROLE_UNKNOWN;

   const int first = StringLen(EA_TAG) + 1;
   const int separator = StringFind(comment, "|", first);
   if(separator < 0)
      return ROLE_UNKNOWN;

   const string cycle_text = StringSubstr(comment, first, separator - first);
   const int generation_separator = StringFind(comment, "|", separator + 1);
   const string role_text = (generation_separator < 0
                             ? StringSubstr(comment, separator + 1)
                             : StringSubstr(comment, separator + 1,
                                            generation_separator - separator - 1));
   if(generation_separator >= 0)
      generation = (ulong)StringToInteger(StringSubstr(comment, generation_separator + 1));
   cycle_id = (ulong)StringToInteger(cycle_text);

   if(cycle_id == 0)
      return ROLE_UNKNOWN;
   if(role_text == "IB")
      return ROLE_INITIAL_BUY;
   if(role_text == "IS")
      return ROLE_INITIAL_SELL;
   if(role_text == "BR")
      return ROLE_BRAKE;
   return ROLE_UNKNOWN;
}

PositionRole ParseIntentComment(const string comment, ulong &cycle_id)
{
   ulong generation = 0;
   return ParseIntentCommentEx(comment, cycle_id, generation);
}

// -----------------------------------------------------------------------------
// Inventory and history reconstruction
// -----------------------------------------------------------------------------

void ResetSnapshot()
{
   g_position_count = 0;
   g_order_count = 0;
   g_snapshot_invalid = false;
}

bool AdoptOrValidateCycle(const ulong observed_cycle)
{
   if(observed_cycle == 0)
      return false;
   if(g_cycle_id == 0)
   {
      g_cycle_id = observed_cycle;
      if(observed_cycle > g_last_cycle_id)
         g_last_cycle_id = observed_cycle;
      return true;
   }
   return (g_cycle_id == observed_cycle);
}

void RefreshSnapshot()
{
   ResetSnapshot();

   const int total_positions = PositionsTotal();
   for(int index = 0; index < total_positions; ++index)
   {
      const ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      if(g_position_count >= MAX_OWNED_POSITIONS)
      {
         g_snapshot_invalid = true;
         continue;
      }

      ulong observed_cycle = 0;
      ulong observed_generation = 0;
      const PositionRole role = ParseIntentCommentEx(PositionGetString(POSITION_COMMENT), observed_cycle,
                                                      observed_generation);
      if(role == ROLE_UNKNOWN || !AdoptOrValidateCycle(observed_cycle))
         g_snapshot_invalid = true;

      PositionRecord record;
      record.ticket       = ticket;
      record.identifier   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      record.cycle_id     = observed_cycle;
      record.generation   = observed_generation;
      record.role         = role;
      record.type         = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      record.volume       = PositionGetDouble(POSITION_VOLUME);
      record.open_price   = PositionGetDouble(POSITION_PRICE_OPEN);
      record.sl           = PositionGetDouble(POSITION_SL);
      record.tp           = PositionGetDouble(POSITION_TP);
      record.profit       = PositionGetDouble(POSITION_PROFIT);
      record.swap         = PositionGetDouble(POSITION_SWAP);
      record.open_time    = (datetime)PositionGetInteger(POSITION_TIME);
      g_positions[g_position_count++] = record;
   }

   const int total_orders = OrdersTotal();
   for(int index = 0; index < total_orders; ++index)
   {
      const ulong ticket = OrderGetTicket(index);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      if(g_order_count >= MAX_OWNED_ORDERS)
      {
         g_snapshot_invalid = true;
         continue;
      }

      ulong observed_cycle = 0;
      ulong observed_generation = 0;
      const PositionRole role = ParseIntentCommentEx(OrderGetString(ORDER_COMMENT), observed_cycle,
                                                      observed_generation);
      if(role != ROLE_BRAKE || !AdoptOrValidateCycle(observed_cycle))
         g_snapshot_invalid = true;

      OrderRecord record;
      record.ticket          = ticket;
      record.cycle_id        = observed_cycle;
      record.generation      = observed_generation;
      record.role            = role;
      record.type            = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      record.volume_current  = OrderGetDouble(ORDER_VOLUME_CURRENT);
      record.open_price      = OrderGetDouble(ORDER_PRICE_OPEN);
      record.sl              = OrderGetDouble(ORDER_SL);
      record.tp              = OrderGetDouble(ORDER_TP);
      record.setup_time_msc  = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);
      g_orders[g_order_count++] = record;
      if(role == ROLE_BRAKE && g_brake_order_ticket == 0)
         g_brake_order_ticket = ticket;
   }

   if(g_cycle_id != 0 && g_cycle_start == 0)
   {
      // Cycle ids are seeded from epoch tick milliseconds. This survives loss
      // of terminal globals and preserves already-closed harvests in history.
      const datetime encoded_start = (datetime)(g_cycle_id / 1000);
      const datetime now = TimeTradeServer();
      if(encoded_start >= D'2020.01.01 00:00:00' && encoded_start <= now + 86400)
         g_cycle_start = encoded_start;
      else
      {
         datetime earliest = now;
         for(int index = 0; index < g_position_count; ++index)
            if(g_positions[index].open_time < earliest)
               earliest = g_positions[index].open_time;
         for(int index = 0; index < g_order_count; ++index)
         {
            const datetime setup = (datetime)(g_orders[index].setup_time_msc / 1000);
            if(setup > 0 && setup < earliest)
               earliest = setup;
         }
         g_cycle_start = earliest;
      }
   }
}

int BasePositionCount()
{
   int count = 0;
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].role == ROLE_INITIAL_BUY || g_positions[index].role == ROLE_INITIAL_SELL)
         ++count;
   return count;
}

int BrakePositionCount()
{
   int count = 0;
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].role == ROLE_BRAKE)
         ++count;
   return count;
}

int BrakeOrderCount()
{
   int count = 0;
   for(int index = 0; index < g_order_count; ++index)
      if(g_orders[index].role == ROLE_BRAKE)
         ++count;
   return count;
}

int FindAnchorIndex()
{
   if(BasePositionCount() != 1)
      return -1;
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].role == ROLE_INITIAL_BUY || g_positions[index].role == ROLE_INITIAL_SELL)
         return index;
   return -1;
}

int FindBrakePositionIndex()
{
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].role == ROLE_BRAKE)
         return index;
   return -1;
}

int FindBrakeOrderIndex()
{
   for(int index = 0; index < g_order_count; ++index)
      if(g_orders[index].role == ROLE_BRAKE)
         return index;
   return -1;
}

double BrakePositionVolume()
{
   double volume = 0.0;
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].role == ROLE_BRAKE)
         volume += g_positions[index].volume;
   return volume;
}

double BrakeOrderVolume()
{
   double volume = 0.0;
   for(int index = 0; index < g_order_count; ++index)
      if(g_orders[index].role == ROLE_BRAKE)
         volume += g_orders[index].volume_current;
   return volume;
}

double VolumeTolerance()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   return step * 0.25;
}

double NormalizeVolumeDown(const double volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   const double units = MathFloor((volume + VolumeTolerance()) / step);
   return NormalizeDouble(units * step, 8);
}

bool PositionIdInArray(const ulong id, const ulong &ids[], const int count)
{
   for(int index = 0; index < count; ++index)
      if(ids[index] == id)
         return true;
   return false;
}

void AddUniquePositionId(const ulong id, ulong &ids[], int &count)
{
   if(id == 0 || PositionIdInArray(id, ids, count))
      return;
   ArrayResize(ids, count + 1);
   ids[count++] = id;
}

bool OrderIdInArray(const ulong id, const ulong &ids[], const int count)
{
   for(int index = 0; index < count; ++index)
      if(ids[index] == id)
         return true;
   return false;
}

void AddUniqueOrderId(const ulong id, ulong &ids[], int &count)
{
   if(id == 0 || OrderIdInArray(id, ids, count))
      return;
   ArrayResize(ids, count + 1);
   ids[count++] = id;
}

bool RealizedCycleNet(double &realized, bool &tp_harvest_found)
{
   realized = 0.0;
   tp_harvest_found = false;
   if(g_cycle_id == 0)
      return true;

   datetime from_time = g_cycle_start;
   if(from_time <= 0)
      return false;
   from_time -= 300;

   if(!HistorySelect(from_time, TimeTradeServer() + 60))
      return false;

   ulong order_ids[];
   ulong position_ids[];
   int order_id_count = 0;
   int position_id_count = 0;

   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].cycle_id == g_cycle_id && g_positions[index].role != ROLE_UNKNOWN)
         AddUniquePositionId(g_positions[index].identifier, position_ids, position_id_count);

   AddUniqueOrderId(g_arming_first_order, order_ids, order_id_count);
   AddUniqueOrderId(g_arming_second_order, order_ids, order_id_count);
   AddUniqueOrderId(g_brake_order_ticket, order_ids, order_id_count);
   if(HasOutstandingIntent() &&
      (g_intent_operation == INTENT_ARM_FIRST || g_intent_operation == INTENT_ARM_SECOND ||
       g_intent_operation == INTENT_BRAKE_STOP || g_intent_operation == INTENT_BRAKE_MARKET))
      AddUniqueOrderId(g_intent_order_ticket, order_ids, order_id_count);

   // Seed ownership from historical order comments. Order tickets are the
   // strongest bridge to brokers that post the resulting deals without magic,
   // symbol, or an intact deal comment.
   const int order_total = HistoryOrdersTotal();
   for(int index = 0; index < order_total; ++index)
   {
      const ulong order = HistoryOrderGetTicket(index);
      if(order == 0)
         continue;
      if(HistoryOrderGetString(order, ORDER_SYMBOL) != _Symbol ||
         (long)HistoryOrderGetInteger(order, ORDER_MAGIC) != InpMagic)
         continue;
      const string comment = HistoryOrderGetString(order, ORDER_COMMENT);
      ulong cycle = 0;
      const PositionRole role = ParseIntentComment(comment, cycle);
      if(cycle == g_cycle_id && role != ROLE_UNKNOWN)
         AddUniqueOrderId(order, order_ids, order_id_count);
   }

   // First closure pass: owned orders and intact cycle comments discover every
   // position identifier. Do not require symbol/magic once causal ownership is
   // established through DEAL_ORDER.
   const int deal_total = HistoryDealsTotal();
   for(int index = 0; index < deal_total; ++index)
   {
      const ulong deal = HistoryDealGetTicket(index);
      if(deal == 0)
         continue;
      const ulong order = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
      ulong deal_cycle = 0;
      const PositionRole deal_role = ParseIntentComment(HistoryDealGetString(deal, DEAL_COMMENT),
                                                         deal_cycle);
      const bool linked_order = OrderIdInArray(order, order_ids, order_id_count);
      const bool owned_entry_comment = (deal_cycle == g_cycle_id && deal_role != ROLE_UNKNOWN);
      if(linked_order || owned_entry_comment)
      {
         AddUniqueOrderId(order, order_ids, order_id_count);
         AddUniquePositionId((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID),
                             position_ids, position_id_count);
      }
   }

   const bool ownership_found = (order_id_count > 0 || position_id_count > 0);
   if((g_position_count > 0 || g_order_count > 0 || HasOutstandingIntent()) && !ownership_found)
      return false;

   for(int index = 0; index < deal_total; ++index)
   {
      const ulong deal = HistoryDealGetTicket(index);
      if(deal == 0)
         continue;

      const ulong order = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
      const ulong position_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      ulong deal_cycle = 0;
      const PositionRole deal_role = ParseIntentComment(HistoryDealGetString(deal, DEAL_COMMENT),
                                                         deal_cycle);
      const bool owned = OrderIdInArray(order, order_ids, order_id_count) ||
                         PositionIdInArray(position_id, position_ids, position_id_count) ||
                         (deal_cycle == g_cycle_id && deal_role != ROLE_UNKNOWN);
      if(!owned)
         continue;

      realized += HistoryDealGetDouble(deal, DEAL_PROFIT);
      realized += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      realized += HistoryDealGetDouble(deal, DEAL_SWAP);
      realized += HistoryDealGetDouble(deal, DEAL_FEE);

      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
      if((entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) && reason == DEAL_REASON_TP)
         tp_harvest_found = true;
   }
   return true;
}

double ExitCommissionEstimate()
{
   double total_volume = 0.0;
   for(int index = 0; index < g_position_count; ++index)
      total_volume += g_positions[index].volume;
   return total_volume * InpExitCommissionPerLotGBP;
}

bool LiquidationValueGBP(double &value, bool &tp_harvest_found)
{
   value = 0.0;
   tp_harvest_found = false;
   if(!RealizedCycleNet(value, tp_harvest_found))
      return false;

   for(int index = 0; index < g_position_count; ++index)
      value += g_positions[index].profit + g_positions[index].swap;

   value -= ExitCommissionEstimate();
   value -= InpEmergencySlippageReserveGBP;
   // Truly linkless balance/commission deals (no order, position, magic or
   // cycle comment) cannot be attributed safely on a shared MT5 account. This
   // explicit reserve keeps the hard budget conservative without stealing
   // deposits, withdrawals, or another strategy's charges into this ledger.
   value -= InpUnlinkedChargeReserveGBP;
   return true;
}

// -----------------------------------------------------------------------------
// Trade request helpers
// -----------------------------------------------------------------------------

ENUM_ORDER_TYPE_FILLING MarketFillingMode()
{
   const long modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   const ENUM_SYMBOL_TRADE_EXECUTION execution =
      (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);
   if(execution != SYMBOL_TRADE_EXECUTION_MARKET)
      return ORDER_FILLING_RETURN;
   // Static validation rejects this configuration; FOK is only a fail-safe
   // return value for a transiently changed broker capability.
   return ORDER_FILLING_FOK;
}

bool RetcodeAccepted(const IntentOperation operation, const uint retcode)
{
   if(operation == INTENT_MODIFY_PROTECTION)
      return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_NO_CHANGES);
   if(operation == INTENT_DELETE_ORDER || operation == INTENT_BRAKE_CANCEL)
      return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED);
   return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED ||
           retcode == TRADE_RETCODE_DONE_PARTIAL);
}

bool CriticalIntentPersisted()
{
   if(!GlobalVariableCheck(StateKey("intent_op")) ||
      !GlobalVariableCheck(StateKey("intent_status")) ||
      !GlobalVariableCheck(StateKey("intent_role")) ||
      !GlobalVariableCheck(StateKey("intent_time")))
      return false;
   return ((IntentOperation)(int)GlobalVariableGet(StateKey("intent_op")) == g_intent_operation &&
           (IntentStatus)(int)GlobalVariableGet(StateKey("intent_status")) == g_intent_status &&
           LoadUlong("intent_cycle") == g_intent_cycle &&
           LoadUlong("intent_gen") == g_intent_generation);
}

bool SubmitRequest(MqlTradeRequest &request, const string label, const bool check_request,
                   const IntentOperation operation, const PositionRole role = ROLE_UNKNOWN)
{
   if(HasOutstandingIntent())
   {
      PrintFormat("%s suppressed: unresolved intent op=%d generation=%I64u",
                  label, (int)g_intent_operation, g_intent_generation);
      return false;
   }

   // Allocate the generation before OrderCheck so opening comments uniquely
   // identify retries and can reconstruct a crash between send and result flush.
   const ulong generation = g_intent_generation + 1;
   if(role != ROLE_UNKNOWN &&
      (operation == INTENT_ARM_FIRST || operation == INTENT_ARM_SECOND ||
       operation == INTENT_BRAKE_STOP || operation == INTENT_BRAKE_MARKET))
      request.comment = IntentComment(role, generation);

   if(check_request)
   {
      MqlTradeCheckResult check;
      ZeroMemory(check);
      if(!OrderCheck(request, check))
      {
         PrintFormat("%s OrderCheck transport failure: %d", label, GetLastError());
         return false;
      }
      if(check.retcode != TRADE_RETCODE_DONE && check.retcode != TRADE_RETCODE_PLACED)
      {
         PrintFormat("%s OrderCheck rejected: %u %s", label, check.retcode, check.comment);
         return false;
      }
   }

   g_intent_operation = operation;
   g_intent_status = INTENT_STATUS_PREPARED;
   g_intent_role = role;
   g_intent_order_type = request.type;
   g_intent_cycle = g_cycle_id;
   g_intent_generation = generation;
   g_intent_request_id = 0;
   g_intent_order_ticket = 0;
   g_intent_deal_ticket = 0;
   g_intent_target_ticket = (request.position != 0 ? request.position : request.order);
   g_intent_target_by_ticket = request.position_by;
   g_intent_expected_volume = request.volume;
   g_intent_target_volume = CurrentPositionVolumeByTicket(g_intent_target_ticket);
   g_intent_target_by_volume = CurrentPositionVolumeByTicket(g_intent_target_by_ticket);
   g_intent_submitted_at = TimeTradeServer();
   g_intent_submitted_local_msc = GetTickCount64();
   PersistState();
   if(!CriticalIntentPersisted())
   {
      PrintFormat("%s aborted: PREPARED intent was not durably persisted", label);
      ClearIntent();
      return false;
   }

   MqlTradeResult result;
   ZeroMemory(result);
   ResetLastError();
   const bool sent = OrderSend(request, result);
   g_last_action_request_id = result.request_id;
   g_last_result_order = result.order;
   g_intent_request_id = result.request_id;
   g_intent_order_ticket = result.order;
   g_intent_deal_ticket = result.deal;

   if(!sent || !RetcodeAccepted(operation, result.retcode))
   {
      PrintFormat("%s rejected: sent=%s retcode=%u comment=%s error=%d",
                  label, (sent ? "true" : "false"), result.retcode, result.comment, GetLastError());
      ClearIntent();
      return false;
   }

   g_intent_status = INTENT_STATUS_ACCEPTED;
   PersistState();
   PrintFormat("%s accepted: op=%d generation=%I64u retcode=%u order=%I64u deal=%I64u request=%u",
               label, (int)operation, generation, result.retcode, result.order, result.deal, result.request_id);
   return true;
}

bool SendMarketOpen(const ENUM_ORDER_TYPE type, const double volume, const PositionRole role,
                    const IntentOperation operation)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double pip = PipSize();
   const bool buy = (type == ORDER_TYPE_BUY);
   const double price = (buy ? tick.ask : tick.bid);

   MqlTradeRequest request;
   ZeroMemory(request);
   request.action       = TRADE_ACTION_DEAL;
   request.magic        = (ulong)InpMagic;
   request.symbol       = _Symbol;
   request.volume       = volume;
   request.type         = type;
   request.price        = price;
   request.deviation    = InpMaxDeviationPoints;
   request.type_filling = MarketFillingMode();
   request.comment      = IntentComment(role);
   request.sl           = NormalizePriceNearest(price + (buy ? -1.0 : 1.0) * InpAnchorServerStopPips * pip);
   request.tp           = NormalizePriceNearest(price + (buy ? 1.0 : -1.0) * InpTakeProfitPips * pip);
   return SubmitRequest(request, "Market open " + RoleCode(role), true, operation, role);
}

bool SendBrakeStop(const int anchor_index)
{
   if(anchor_index < 0 || anchor_index >= g_position_count)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const PositionRecord anchor = g_positions[anchor_index];
   const double pip = PipSize();
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double stop_level_pips = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point / pip;
   const double freeze_level_pips = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point / pip;
   const double effective_h = MathMax(InpBrakeOffsetPips, MathMax(stop_level_pips, freeze_level_pips) + 0.1);
   const bool need_buy = (anchor.type == POSITION_TYPE_SELL);
   const double missing_volume = NormalizeVolumeDown(anchor.volume - BrakePositionVolume());
   if(missing_volume <= VolumeTolerance())
      return true;
   const double raw_price = (need_buy ? tick.ask + effective_h * pip : tick.bid - effective_h * pip);
   const double stop_price = (need_buy ? NormalizePriceUp(raw_price) : NormalizePriceDown(raw_price));

   MqlTradeRequest request;
   ZeroMemory(request);
   request.action       = TRADE_ACTION_PENDING;
   request.magic        = (ulong)InpMagic;
   request.symbol       = _Symbol;
   request.volume       = missing_volume;
   request.type         = (need_buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
   request.price        = stop_price;
   request.type_filling = ORDER_FILLING_RETURN;
   request.type_time    = ORDER_TIME_GTC;
   request.comment      = IntentComment(ROLE_BRAKE);
   request.sl           = NormalizePriceNearest(stop_price + (need_buy ? -1.0 : 1.0) * InpAnchorServerStopPips * pip);
   request.tp           = NormalizePriceNearest(stop_price + (need_buy ? 1.0 : -1.0) * InpTakeProfitPips * pip);

   const bool accepted = SubmitRequest(request, "Immutable brake stop", true,
                                       INTENT_BRAKE_STOP, ROLE_BRAKE);
   if(accepted)
   {
      g_brake_order_ticket = g_last_result_order;
      g_brake_cross_tick_msc = 0;
      g_brake_cross_local_msc = 0;
      g_fallback_stage = FALLBACK_NONE;
      PersistState();
   }
   return accepted;
}

bool SendMarketBrake(const int anchor_index)
{
   if(anchor_index < 0 || anchor_index >= g_position_count)
      return false;

   const PositionRecord anchor = g_positions[anchor_index];
   double confirmed_opposite = 0.0;
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].type != anchor.type)
         confirmed_opposite += g_positions[index].volume;

   const double required = NormalizeVolumeDown(MathMax(0.0, anchor.volume - confirmed_opposite));
   if(required <= VolumeTolerance())
      return true;

   if(confirmed_opposite + required > anchor.volume + VolumeTolerance())
      return false;

   const ENUM_ORDER_TYPE type = (anchor.type == POSITION_TYPE_SELL ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   return SendMarketOpen(type, required, ROLE_BRAKE, INTENT_BRAKE_MARKET);
}

bool ModifyPositionProtection(const PositionRecord &position, const double sl, const double tp, const string label)
{
   MqlTradeRequest request;
   ZeroMemory(request);
   request.action   = TRADE_ACTION_SLTP;
   request.magic    = (ulong)InpMagic;
   request.symbol   = _Symbol;
   request.position = position.ticket;
   request.sl       = sl;
   request.tp       = tp;
   return SubmitRequest(request, label, false, INTENT_MODIFY_PROTECTION);
}

bool DeleteOrderTicket(const ulong ticket, const string label,
                       const IntentOperation operation = INTENT_DELETE_ORDER)
{
   MqlTradeRequest request;
   ZeroMemory(request);
   request.action = TRADE_ACTION_REMOVE;
   request.magic  = (ulong)InpMagic;
   request.symbol = _Symbol;
   request.order  = ticket;
   return SubmitRequest(request, label, false, operation);
}

bool ClosePositionTicket(const PositionRecord &position, const string label)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const bool closing_buy = (position.type == POSITION_TYPE_SELL);
   MqlTradeRequest request;
   ZeroMemory(request);
   request.action       = TRADE_ACTION_DEAL;
   request.magic        = (ulong)InpMagic;
   request.symbol       = _Symbol;
   request.position     = position.ticket;
   request.volume       = position.volume;
   request.type         = (closing_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   request.price        = (closing_buy ? tick.ask : tick.bid);
   request.deviation    = InpMaxDeviationPoints;
   request.type_filling = MarketFillingMode();
   request.comment      = StringFormat("%s|%I64u|CL", EA_TAG, g_cycle_id);
   return SubmitRequest(request, label, true, INTENT_CLOSE_POSITION);
}

bool CloseByTickets(const PositionRecord &first, const PositionRecord &second)
{
   if(first.type == second.type || !VolumeEqual(first.volume, second.volume))
      return false;

   const long order_modes = SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE);
   if((order_modes & SYMBOL_ORDER_CLOSEBY) != SYMBOL_ORDER_CLOSEBY)
      return false;

   MqlTradeRequest request;
   ZeroMemory(request);
   request.action      = TRADE_ACTION_CLOSE_BY;
   request.magic       = (ulong)InpMagic;
   request.symbol      = _Symbol;
   request.position    = first.ticket;
   request.position_by = second.ticket;
   request.comment     = StringFormat("%s|%I64u|CB", EA_TAG, g_cycle_id);
   return SubmitRequest(request, "Close-by cycle pair", true, INTENT_CLOSE_BY);
}

// -----------------------------------------------------------------------------
// Entry quality, calendar, and risk calculations
// -----------------------------------------------------------------------------

void RecordTick(const MqlTick &tick)
{
   TickSample sample;
   sample.time_msc = tick.time_msc;
   sample.mid = 0.5 * (tick.bid + tick.ask);
   sample.spread_pips = (tick.ask - tick.bid) / PipSize();
   g_samples[g_sample_next] = sample;
   g_sample_next = (g_sample_next + 1) % MAX_TICK_SAMPLES;
   if(g_sample_count < MAX_TICK_SAMPLES)
      ++g_sample_count;
}

int CollectRecentSamples(const long window_ms, double &spreads[], double &mids[])
{
   ArrayResize(spreads, 0);
   ArrayResize(mids, 0);
   if(g_sample_count <= 0)
      return 0;

   const long newest = g_last_tick.time_msc;
   int count = 0;
   for(int offset = 0; offset < g_sample_count; ++offset)
   {
      int index = g_sample_next - 1 - offset;
      if(index < 0)
         index += MAX_TICK_SAMPLES;
      if(newest - g_samples[index].time_msc > window_ms)
         break;
      ArrayResize(spreads, count + 1);
      ArrayResize(mids, count + 1);
      spreads[count] = g_samples[index].spread_pips;
      mids[count] = g_samples[index].mid;
      ++count;
   }
   return count;
}

double Median(double &values[])
{
   const int count = ArraySize(values);
   if(count == 0)
      return 0.0;
   ArraySort(values);
   if((count % 2) == 1)
      return values[count / 2];
   return 0.5 * (values[count / 2 - 1] + values[count / 2]);
}

double DynamicSpreadLimitPips()
{
   double spreads[];
   double mids[];
   const int count = CollectRecentSamples(60000, spreads, mids);
   if(count < 20)
      return InpEntrySpreadHardMaxPips;

   double median_values[];
   ArrayCopy(median_values, spreads);
   const double median = Median(median_values);

   double deviations[];
   ArrayResize(deviations, count);
   for(int index = 0; index < count; ++index)
      deviations[index] = MathAbs(spreads[index] - median);
   const double mad = Median(deviations);
   return MathMin(InpEntrySpreadHardMaxPips, median + MathMax(0.10, 3.0 * mad));
}

bool CurrentTickEntryAdmissible()
{
   if(g_last_tick.ask <= g_last_tick.bid || g_last_tick.bid <= 0.0)
      return false;
   if(GetTickCount64() - g_last_tick_local_msc > InpEntryQuoteMaxAgeMs)
      return false;

   const double spread = (g_last_tick.ask - g_last_tick.bid) / PipSize();
   if(spread > DynamicSpreadLimitPips())
      return false;

   double spreads[];
   double mids[];
   const int count = CollectRecentSamples(2000, spreads, mids);
   if(count < 3)
      return false;

   double low = mids[0];
   double high = mids[0];
   double weighted_sum = 0.0;
   double total_weight = 0.0;
   for(int index = 0; index < count; ++index)
   {
      low = MathMin(low, mids[index]);
      high = MathMax(high, mids[index]);
      const double age_seconds = (double)(g_last_tick.time_msc - g_samples[(g_sample_next - 1 - index + MAX_TICK_SAMPLES) % MAX_TICK_SAMPLES].time_msc) / 1000.0;
      const double weight = MathExp(-age_seconds);
      weighted_sum += mids[index] * weight;
      total_weight += weight;
   }

   if((high - low) / PipSize() > InpEntryRange2sMaxPips)
      return false;
   if(total_weight <= 0.0)
      return false;
   const double ewma = weighted_sum / total_weight;
   const double mid = 0.5 * (g_last_tick.bid + g_last_tick.ask);
   return (MathAbs(mid - ewma) / PipSize() <= InpEntryEwmaDistanceMaxPips);
}

bool BaseTradePermissionsAvailable()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   return (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
}

bool CanOpenRisk()
{
   if(!BaseTradePermissionsAvailable())
      return false;
   const ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (mode == SYMBOL_TRADE_MODE_FULL);
}

bool CanReduceRisk()
{
   if(!BaseTradePermissionsAvailable())
      return false;
   const ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (mode == SYMBOL_TRADE_MODE_FULL || mode == SYMBOL_TRADE_MODE_CLOSEONLY);
}

bool StrictEntryGate()
{
   if(!g_entry_config_valid || !CanOpenRisk())
      return false;
   if(g_position_count != 0 || g_order_count != 0 || g_cycle_id != 0)
      return false;
   if(g_entry_admissible_ticks < 3)
      return false;
   return CurrentTickEntryAdmissible();
}

int FridaySessionCloseSecond()
{
   int latest_second = -1;
   for(uint session = 0; session < 16; ++session)
   {
      datetime from_time = 0;
      datetime to_time = 0;
      if(!SymbolInfoSessionTrade(_Symbol, FRIDAY, session, from_time, to_time))
         break;
      MqlDateTime parts;
      TimeToStruct(to_time, parts);
      int seconds = parts.hour * 3600 + parts.min * 60 + parts.sec;
      if(seconds == 0)
         seconds = 24 * 3600;
      if(seconds > latest_second)
         latest_second = seconds;
   }
   if(latest_second < 0)
      latest_second = 23 * 3600 + 59 * 60;
   return latest_second;
}

bool InFridayWindow(const uint minutes_before_close)
{
   MqlDateTime now_parts;
   TimeToStruct(TimeTradeServer(), now_parts);
   if(now_parts.day_of_week != FRIDAY)
      return false;
   const long current_second = (long)now_parts.hour * 3600 + (long)now_parts.min * 60 + now_parts.sec;
   const long lead_seconds = (long)minutes_before_close * 60;
   return (current_second >= (long)FridaySessionCloseSecond() - lead_seconds);
}

datetime NextTripleSwapRollover()
{
   const datetime now = TimeTradeServer();
   MqlDateTime parts;
   TimeToStruct(now, parts);
   const int target_day = (int)SymbolInfoInteger(_Symbol, SYMBOL_SWAP_ROLLOVER3DAYS);
   int days_ahead = target_day - parts.day_of_week;
   if(days_ahead < 0)
      days_ahead += 7;

   parts.hour = InpTripleSwapRolloverHour;
   parts.min = InpTripleSwapRolloverMinute;
   parts.sec = 0;
   datetime target = StructToTime(parts) + days_ahead * 86400;
   if(target <= now)
      target += 7 * 86400;
   return target;
}

bool NearTripleSwapRollover()
{
   const datetime now = TimeTradeServer();
   const datetime rollover = NextTripleSwapRollover();
   return (rollover > now && rollover - now <= (datetime)InpTripleSwapFlattenMinutes * 60);
}

bool InTripleSwapWindow()
{
   if(!NearTripleSwapRollover())
      return false;
   if(FindAnchorIndex() < 0)
      return false;

   const int anchor_index = FindAnchorIndex();
   if(anchor_index < 0)
      return false;

   const PositionRecord anchor = g_positions[anchor_index];
   double adverse = 0.0;
   if(anchor.type == POSITION_TYPE_BUY)
      adverse = (anchor.open_price - g_last_tick.bid) / PipSize();
   else
      adverse = (g_last_tick.ask - anchor.open_price) / PipSize();
   return (adverse > 0.0);
}

double AnchorAdversePips()
{
   const int anchor_index = FindAnchorIndex();
   if(anchor_index < 0)
      return 0.0;
   const PositionRecord anchor = g_positions[anchor_index];
   if(anchor.type == POSITION_TYPE_BUY)
      return MathMax(0.0, (anchor.open_price - g_last_tick.bid) / PipSize());
   return MathMax(0.0, (g_last_tick.ask - anchor.open_price) / PipSize());
}

bool MaximumAnchorAgeReached()
{
   return (g_anchor_since > 0 && TimeTradeServer() - g_anchor_since >= (datetime)InpMaximumAnchorAgeMinutes * 60);
}

// -----------------------------------------------------------------------------
// Invariants, protection, flattening, and phase reconciliation
// -----------------------------------------------------------------------------

bool PendingBrakeValid()
{
   if(BrakeOrderCount() == 0)
      return true;

   const int anchor_index = FindAnchorIndex();
   const int order_index = FindBrakeOrderIndex();
   if(anchor_index < 0 || order_index < 0)
      return false;

   const PositionRecord anchor = g_positions[anchor_index];
   const OrderRecord order = g_orders[order_index];
   const ENUM_ORDER_TYPE expected_type = (anchor.type == POSITION_TYPE_SELL ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
   const double expected_remaining = NormalizeVolumeDown(anchor.volume - BrakePositionVolume());
   if(order.type != expected_type || MathAbs(order.volume_current - expected_remaining) > VolumeTolerance() ||
      order.open_price <= 0.0)
      return false;
   if(g_brake_order_ticket != 0 && order.ticket != g_brake_order_ticket)
      return false;

   const bool buy_stop = (order.type == ORDER_TYPE_BUY_STOP);
   const double desired_sl = NormalizePriceNearest(order.open_price + (buy_stop ? -1.0 : 1.0) * InpAnchorServerStopPips * PipSize());
   const double desired_tp = NormalizePriceNearest(order.open_price + (buy_stop ? 1.0 : -1.0) * InpTakeProfitPips * PipSize());
   return (NearlyEqual(order.sl, desired_sl) && NearlyEqual(order.tp, desired_tp));
}

bool InventoryShapeValid()
{
   if(g_snapshot_invalid || !PendingBrakeValid())
      return false;
   if(g_position_count > MAX_OWNED_POSITIONS || g_order_count > 1)
      return false;

   const int base_count = BasePositionCount();
   const int brake_count = BrakePositionCount();
   const int brake_orders = BrakeOrderCount();
   if(base_count + brake_count != g_position_count || brake_orders != g_order_count)
      return false;

   for(int index = 0; index < g_position_count; ++index)
   {
      const PositionRecord position = g_positions[index];
      if(position.volume <= VolumeTolerance() || position.volume > InpLots + VolumeTolerance())
         return false;
      if(position.role == ROLE_INITIAL_BUY && position.type != POSITION_TYPE_BUY)
         return false;
      if(position.role == ROLE_INITIAL_SELL && position.type != POSITION_TYPE_SELL)
         return false;
   }

   if(base_count == 2)
   {
      if(brake_count != 0 || brake_orders != 0 || g_position_count != 2)
         return false;
      bool have_buy_role = false;
      bool have_sell_role = false;
      for(int index = 0; index < g_position_count; ++index)
      {
         have_buy_role = (have_buy_role || g_positions[index].role == ROLE_INITIAL_BUY);
         have_sell_role = (have_sell_role || g_positions[index].role == ROLE_INITIAL_SELL);
         if(!VolumeEqual(g_positions[index].volume, InpLots))
            return false;
      }
      return (have_buy_role && have_sell_role && g_positions[0].type != g_positions[1].type);
   }

   if(base_count == 1)
   {
      const int anchor_index = FindAnchorIndex();
      if(anchor_index < 0 || !VolumeEqual(g_positions[anchor_index].volume, InpLots))
         return false;
      const PositionRecord anchor = g_positions[anchor_index];
      for(int index = 0; index < g_position_count; ++index)
         if(g_positions[index].role == ROLE_BRAKE && g_positions[index].type == anchor.type)
            return false;

      const double protective_volume = BrakePositionVolume() + BrakeOrderVolume();
      if(protective_volume > anchor.volume + VolumeTolerance())
         return false;                         // over-hedge is never legal
      return (brake_orders <= 1);              // partial fill + residual order is legal
   }

   return (base_count == 0 && brake_count == 0 && g_order_count == 0);
}

void LatchResolution(const ResolveReason reason)
{
   if(g_resolve_reason == RESOLVE_NONE)
   {
      g_resolve_reason = reason;
      g_phase = PHASE_FLATTENING;
      PrintFormat("Cycle %I64u resolution latched: %d", g_cycle_id, (int)reason);
      PersistState();
   }
}

bool CurrentOrderTicketExists(const ulong ticket)
{
   if(ticket == 0)
      return false;
   for(int index = 0; index < g_order_count; ++index)
      if(g_orders[index].ticket == ticket)
         return true;
   return false;
}

double IntentPositionVolume()
{
   double volume = 0.0;
   for(int index = 0; index < g_position_count; ++index)
   {
      if(g_positions[index].cycle_id != g_intent_cycle || g_positions[index].role != g_intent_role)
         continue;
      if(g_intent_generation != 0 && g_positions[index].generation != g_intent_generation)
         continue;
      volume += g_positions[index].volume;
   }
   return volume;
}

ulong IntentCurrentOrderTicket()
{
   for(int index = 0; index < g_order_count; ++index)
   {
      if(g_orders[index].cycle_id != g_intent_cycle || g_orders[index].role != g_intent_role)
         continue;
      if(g_intent_generation != 0 && g_orders[index].generation != g_intent_generation)
         continue;
      return g_orders[index].ticket;
   }
   return 0;
}

double CurrentOrderVolumeByTicket(const ulong ticket)
{
   for(int index = 0; index < g_order_count; ++index)
      if(g_orders[index].ticket == ticket)
         return g_orders[index].volume_current;
   return 0.0;
}

double CurrentPositionVolumeByTicket(const ulong ticket)
{
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].ticket == ticket)
         return g_positions[index].volume;
   return 0.0;
}

bool IntentAgeReached(const uint timeout_ms)
{
   if(g_intent_submitted_local_msc != 0)
      return (GetTickCount64() - g_intent_submitted_local_msc >= timeout_ms);
   if(g_intent_submitted_at <= 0)
      return true;
   const ulong age_seconds = (ulong)MathMax(0, (long)(TimeTradeServer() - g_intent_submitted_at));
   return (age_seconds * 1000 >= timeout_ms);
}

bool OrderStateTerminal(const ENUM_ORDER_STATE state)
{
   return (state == ORDER_STATE_FILLED || state == ORDER_STATE_PARTIAL ||
           state == ORDER_STATE_CANCELED || state == ORDER_STATE_REJECTED ||
           state == ORDER_STATE_EXPIRED);
}

bool OrderStateUnfilled(const ENUM_ORDER_STATE state)
{
   return (state == ORDER_STATE_CANCELED || state == ORDER_STATE_REJECTED ||
           state == ORDER_STATE_EXPIRED);
}

bool FindIntentHistoryOrder(ulong &ticket, ENUM_ORDER_STATE &state)
{
   ticket = g_intent_order_ticket;
   if(ticket != 0 && HistoryOrderSelect(ticket))
   {
      state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
      return true;
   }

   datetime from_time = (g_cycle_start > 0 ? g_cycle_start - 60 : TimeTradeServer() - 86400);
   if(!HistorySelect(from_time, TimeTradeServer() + 60))
      return false;

   for(int index = HistoryOrdersTotal() - 1; index >= 0; --index)
   {
      const ulong candidate = HistoryOrderGetTicket(index);
      if(candidate == 0)
         continue;
      ulong cycle = 0;
      ulong generation = 0;
      const PositionRole role = ParseIntentCommentEx(HistoryOrderGetString(candidate, ORDER_COMMENT),
                                                      cycle, generation);
      if(cycle != g_intent_cycle || role != g_intent_role || generation != g_intent_generation)
         continue;
      ticket = candidate;
      state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(candidate, ORDER_STATE);
      g_intent_order_ticket = candidate;
      PersistState();
      return true;
   }
   return false;
}

bool HistoricalOrderDealVolumes(const ulong order_ticket, double &entry_volume,
                                double &exit_volume)
{
   entry_volume = 0.0;
   exit_volume = 0.0;
   if(order_ticket == 0)
      return false;
   const datetime from_time = (g_cycle_start > 0 ? g_cycle_start - 300 : TimeTradeServer() - 86400);
   if(!HistorySelect(from_time, TimeTradeServer() + 60))
      return false;

   ulong position_ids[];
   int position_count = 0;
   const int deals = HistoryDealsTotal();
   for(int index = 0; index < deals; ++index)
   {
      const ulong deal = HistoryDealGetTicket(index);
      if(deal == 0 || (ulong)HistoryDealGetInteger(deal, DEAL_ORDER) != order_ticket)
         continue;
      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         entry_volume += HistoryDealGetDouble(deal, DEAL_VOLUME);
      AddUniquePositionId((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID),
                          position_ids, position_count);
   }

   for(int index = 0; index < deals; ++index)
   {
      const ulong deal = HistoryDealGetTicket(index);
      if(deal == 0)
         continue;
      const ulong position_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(!PositionIdInArray(position_id, position_ids, position_count))
         continue;
      const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         exit_volume += HistoryDealGetDouble(deal, DEAL_VOLUME);
   }
   return true;
}

void TimeoutOutstandingIntent()
{
   PrintFormat("Intent timeout: op=%d generation=%I64u order=%I64u; latching fail-safe quarantine",
               (int)g_intent_operation, g_intent_generation, g_intent_order_ticket);
   g_intent_status = INTENT_STATUS_TIMED_OUT;
   const ulong quarantine_seconds = ((ulong)InpUnknownIntentQuarantineMs + 999) / 1000;
   g_quarantine_until = TimeTradeServer() + (datetime)MathMax(1, (long)quarantine_seconds);

   const bool can_create_late_inventory =
      (g_intent_operation == INTENT_ARM_FIRST || g_intent_operation == INTENT_ARM_SECOND ||
       g_intent_operation == INTENT_BRAKE_STOP || g_intent_operation == INTENT_BRAKE_MARKET);
   if(can_create_late_inventory)
   {
      g_tomb_operation = g_intent_operation;
      g_tomb_role = g_intent_role;
      g_tomb_cycle = g_intent_cycle;
      g_tomb_generation = g_intent_generation;
      g_tomb_order_ticket = g_intent_order_ticket;
      g_tomb_expected_volume = g_intent_expected_volume;
      g_tomb_expires = TimeTradeServer() + (datetime)InpTimedOutIntentRetentionMinutes * 60;
   }

   LatchResolution(RESOLVE_INVARIANT);
   // The tombstone preserves causal identity; freeing the single-flight slot
   // permits risk-reducing closes if the timed-out request materializes.
   ClearIntent();
}

bool TombstonePositionOrOrderVisible()
{
   for(int index = 0; index < g_position_count; ++index)
      if(g_positions[index].cycle_id == g_tomb_cycle && g_positions[index].role == g_tomb_role &&
         (g_tomb_generation == 0 || g_positions[index].generation == g_tomb_generation))
         return true;
   for(int index = 0; index < g_order_count; ++index)
      if(g_orders[index].cycle_id == g_tomb_cycle && g_orders[index].role == g_tomb_role &&
         (g_tomb_generation == 0 || g_orders[index].generation == g_tomb_generation))
         return true;
   return false;
}

void ReconcileTimedOutTombstone()
{
   if(!HasTimedOutTombstone())
      return;

   if(TombstonePositionOrOrderVisible())
   {
      LatchResolution(RESOLVE_INVARIANT);
      return;                                  // Drive's resolution path flattens it
   }

   datetime from_time = (g_cycle_start > 0 ? g_cycle_start - 300 : TimeTradeServer() - 86400);
   ulong order_ticket = g_tomb_order_ticket;
   ENUM_ORDER_STATE state = ORDER_STATE_STARTED;
   bool have_history = false;
   if(HistorySelect(from_time, TimeTradeServer() + 60))
   {
      if(order_ticket != 0 && HistoryOrderSelect(order_ticket))
      {
         state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(order_ticket, ORDER_STATE);
         have_history = true;
      }
      else
      {
         for(int index = HistoryOrdersTotal() - 1; index >= 0; --index)
         {
            const ulong candidate = HistoryOrderGetTicket(index);
            if(candidate == 0)
               continue;
            ulong cycle = 0;
            ulong generation = 0;
            const PositionRole role = ParseIntentCommentEx(HistoryOrderGetString(candidate, ORDER_COMMENT),
                                                            cycle, generation);
            if(cycle == g_tomb_cycle && role == g_tomb_role && generation == g_tomb_generation)
            {
               order_ticket = candidate;
               state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(candidate, ORDER_STATE);
               have_history = true;
               g_tomb_order_ticket = candidate;
               PersistState();
               break;
            }
         }
      }
   }

   if(have_history && !CurrentOrderTicketExists(order_ticket) && OrderStateTerminal(state))
   {
      double entry_volume = 0.0;
      double exit_volume = 0.0;
      const bool deals_available = HistoricalOrderDealVolumes(order_ticket, entry_volume, exit_volume);
      const bool complete_round_trip = (deals_available && entry_volume > 0.0 &&
                                        exit_volume + VolumeTolerance() >= entry_volume);
      if(OrderStateUnfilled(state) || complete_round_trip)
      {
         PrintFormat("Timed-out intent tombstone settled: generation=%I64u order=%I64u",
                     g_tomb_generation, order_ticket);
         ClearTombstone();
         return;
      }
   }

   if(g_tomb_expires > 0 && TimeTradeServer() >= g_tomb_expires)
   {
      PrintFormat("Timed-out intent tombstone retention expired after %u minutes; no late inventory observed",
                  InpTimedOutIntentRetentionMinutes);
      ClearTombstone();
   }
}

// Returns true while the current drive must stop and wait for broker/history
// convergence. A false result means no outstanding intent remains.
bool ReconcileOutstandingIntent()
{
   if(!HasOutstandingIntent())
      return false;

   const double visible_volume = IntentPositionVolume();
   const ulong current_order = IntentCurrentOrderTicket();
   if(current_order != 0 && g_intent_order_ticket == 0)
   {
      g_intent_order_ticket = current_order;
      PersistState();
   }

   ulong history_order = 0;
   ENUM_ORDER_STATE history_state = ORDER_STATE_STARTED;
   const bool have_history = FindIntentHistoryOrder(history_order, history_state);
   const bool terminal = (have_history && !CurrentOrderTicketExists(history_order) &&
                          OrderStateTerminal(history_state));
   const bool terminal_unfilled = (terminal && OrderStateUnfilled(history_state));
   double entry_volume = 0.0;
   double exit_volume = 0.0;
   bool deal_history_available = false;
   if(have_history)
      deal_history_available = HistoricalOrderDealVolumes(history_order, entry_volume, exit_volume);
   const bool complete_round_trip = (deal_history_available && entry_volume > 0.0 && exit_volume +
                                     SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP) * 0.25 >= entry_volume);

   if(g_intent_operation == INTENT_MODIFY_PROTECTION)
   {
      if(g_intent_status == INTENT_STATUS_ACCEPTED && IntentAgeReached(InpSettlementQuietMs))
      {
         ClearIntent();
         return false;
      }
   }
   else if(g_intent_operation == INTENT_BRAKE_STOP)
   {
      const double tolerance = VolumeTolerance();
      if(current_order != 0)
      {
         const double residual_volume = CurrentOrderVolumeByTicket(current_order);
         // Clear only when the coherent partial-fill equation is visible:
         // confirmed filled + live residual == originally requested volume.
         if(MathAbs(visible_volume + residual_volume - g_intent_expected_volume) <= tolerance)
         {
            g_brake_order_ticket = current_order;
            ClearIntent();
            return false;
         }
      }
      else if(visible_volume + tolerance >= g_intent_expected_volume)
      {
         ClearIntent();
         return false;
      }
      else if(terminal && visible_volume > tolerance)
      {
         // Terminal partial fill with no live residual: request only the missing
         // volume in a new generation; never replay the original amount.
         g_fallback_stage = FALLBACK_MARKET_REQUIRED;
         g_brake_order_ticket = 0;
         ClearIntent();
         return false;
      }
      if(terminal_unfilled)
      {
         g_fallback_stage = FALLBACK_MARKET_REQUIRED;
         g_brake_order_ticket = 0;
         ClearIntent();
         return false;
      }
      if(complete_round_trip)
      {
         g_fallback_stage = FALLBACK_NONE;
         g_brake_order_ticket = 0;
         ClearIntent();
         return false;
      }
   }
   else if(g_intent_operation == INTENT_BRAKE_CANCEL ||
           g_intent_operation == INTENT_DELETE_ORDER)
   {
      if(!CurrentOrderTicketExists(g_intent_target_ticket) && terminal)
      {
         if(g_intent_operation == INTENT_BRAKE_CANCEL && !terminal_unfilled)
         {
            // A cancel that lost the race to a fill is not terminal from the
            // strategy's perspective until the resulting position or its full
            // round trip is visible. Otherwise a duplicate brake could be sent.
            if(BrakePositionVolume() <= VolumeTolerance() && !complete_round_trip)
            {
               if(IntentAgeReached(InpIntentTimeoutMs))
                  TimeoutOutstandingIntent();
               return true;
            }
            g_fallback_stage = FALLBACK_NONE;
         }
         else if(g_intent_operation == INTENT_BRAKE_CANCEL)
            g_fallback_stage = FALLBACK_MARKET_REQUIRED;
         ClearIntent();
         return false;
      }
   }
   else if(g_intent_operation == INTENT_CLOSE_POSITION)
   {
      const double current_volume = CurrentPositionVolumeByTicket(g_intent_target_ticket);
      const bool disappeared = (current_volume <= VolumeTolerance());
      const bool reduced = (current_volume + VolumeTolerance() < g_intent_target_volume);
      if(disappeared || (terminal && reduced))
      {
         // A terminal partial close is complete for this generation. The
         // flatten controller submits only the newly observed remainder.
         ClearIntent();
         return false;
      }
   }
   else if(g_intent_operation == INTENT_CLOSE_BY)
   {
      const double current_first = CurrentPositionVolumeByTicket(g_intent_target_ticket);
      const double current_second = CurrentPositionVolumeByTicket(g_intent_target_by_ticket);
      const bool both_gone = (current_first <= VolumeTolerance() && current_second <= VolumeTolerance());
      const bool reduced = (current_first + VolumeTolerance() < g_intent_target_volume ||
                            current_second + VolumeTolerance() < g_intent_target_by_volume);
      if(both_gone || (terminal && reduced))
      {
         ClearIntent();
         return false;
      }
   }
   else if(g_intent_operation == INTENT_ARM_FIRST ||
           g_intent_operation == INTENT_ARM_SECOND ||
           g_intent_operation == INTENT_BRAKE_MARKET)
   {
      const double tolerance = VolumeTolerance();
      const bool full_visible = (visible_volume + tolerance >= g_intent_expected_volume);
      const bool terminal_partial = (terminal && visible_volume > tolerance && !full_visible);
      if(full_visible || terminal_partial)
      {
         const bool partial = !full_visible;
         const IntentOperation completed_operation = g_intent_operation;
         if(completed_operation == INTENT_ARM_FIRST && history_order != 0)
            g_arming_first_order = history_order;
         else if(completed_operation == INTENT_ARM_SECOND && history_order != 0)
            g_arming_second_order = history_order;
         ClearIntent();

         if(partial && completed_operation != INTENT_BRAKE_MARKET)
            LatchResolution(RESOLVE_INVARIANT);
         else if(partial)
            g_fallback_stage = FALLBACK_MARKET_REQUIRED;
         else if(completed_operation == INTENT_BRAKE_MARKET)
            g_fallback_stage = FALLBACK_NONE;
         PersistState();
         return false;
      }
      if(complete_round_trip)
      {
         // A very fast TP/SL may complete before the position snapshot becomes
         // visible. History proves the request cannot create late inventory.
         if(g_intent_operation == INTENT_BRAKE_MARKET)
            g_fallback_stage = FALLBACK_NONE;
         ClearIntent();
         return false;
      }
      if(terminal_unfilled)
      {
         const IntentOperation failed_operation = g_intent_operation;
         ClearIntent();
         if(failed_operation == INTENT_ARM_FIRST)
            ClearCycleState();
         else if(failed_operation == INTENT_ARM_SECOND)
         {
            g_arming_second_sent = false;
            g_phase = PHASE_ANCHOR;
            g_anchor_since = TimeTradeServer();
         }
         else
            LatchResolution(RESOLVE_INVARIANT);
         PersistState();
         return false;
      }
   }

   if(IntentAgeReached(InpIntentTimeoutMs))
   {
      TimeoutOutstandingIntent();
      return false;
   }
   return true;
}

bool FlattenOneAction()
{
   if(HasOutstandingIntent())
      return false;

   if(g_order_count > 0)
      return DeleteOrderTicket(g_orders[0].ticket, "Flatten delete pending");

   if(g_position_count >= 2)
   {
      for(int first = 0; first < g_position_count; ++first)
      {
         for(int second = first + 1; second < g_position_count; ++second)
         {
            if(g_positions[first].type != g_positions[second].type &&
               VolumeEqual(g_positions[first].volume, g_positions[second].volume))
            {
               if(CloseByTickets(g_positions[first], g_positions[second]))
                  return true;
            }
         }
      }
   }

   if(g_position_count > 0)
      return ClosePositionTicket(g_positions[0], "Flatten close position");

   if(TimeTradeServer() < g_quarantine_until)
      return false;
   ClearCycleState();
   return true;
}

ProtectionResult EnsurePositionProtection(const PositionRecord &position, const bool remove_tp)
{
   const double pip = PipSize();
   const bool buy = (position.type == POSITION_TYPE_BUY);
   const double desired_sl = NormalizePriceNearest(position.open_price + (buy ? -1.0 : 1.0) * InpAnchorServerStopPips * pip);
   const double desired_tp = (remove_tp ? 0.0 : NormalizePriceNearest(position.open_price + (buy ? 1.0 : -1.0) * InpTakeProfitPips * pip));

   const bool tp_wrong = (remove_tp ? position.tp != 0.0 : !NearlyEqual(position.tp, desired_tp));
   if(NearlyEqual(position.sl, desired_sl) && !tp_wrong)
      return PROTECTION_UNCHANGED;

   if(ModifyPositionProtection(position, desired_sl, desired_tp,
                               (remove_tp ? "Remove anchor TP in adaptive state" : "Correct position SL/TP")))
      return PROTECTION_REQUESTED;
   return PROTECTION_FAILED;
}

ProtectionResult ReconcileProtectionOneAction()
{
   const int anchor_index = FindAnchorIndex();
   const int brake_index = FindBrakePositionIndex();

   // A confirmed anchor has TP=0 before a pending or live brake exists.
   // During PHASE_ARMING the first leg retains its original TP while the
   // opposite initial leg is still being submitted.
   if(anchor_index >= 0 && g_phase != PHASE_ARMING)
   {
      const ProtectionResult anchor_result = EnsurePositionProtection(g_positions[anchor_index], true);
      if(anchor_result != PROTECTION_UNCHANGED)
         return anchor_result;
   }

   if(brake_index >= 0)
   {
      for(int index = 0; index < g_position_count; ++index)
      {
         if(g_positions[index].role != ROLE_BRAKE)
            continue;
         const ProtectionResult brake_result = EnsurePositionProtection(g_positions[index], false);
         if(brake_result != PROTECTION_UNCHANGED)
            return brake_result;
      }
   }

   if(BasePositionCount() == 2)
   {
      for(int index = 0; index < g_position_count; ++index)
      {
         const ProtectionResult base_result = EnsurePositionProtection(g_positions[index], false);
         if(base_result != PROTECTION_UNCHANGED)
            return base_result;
      }
   }
   return PROTECTION_UNCHANGED;
}

void InferPhase()
{
   const int base_count = BasePositionCount();
   const int brake_count = BrakePositionCount();
   const int brake_orders = BrakeOrderCount();

   if(g_position_count == 0 && g_order_count == 0)
   {
      if(g_resolve_reason != RESOLVE_NONE)
         g_phase = PHASE_FLATTENING;
      else if(g_phase != PHASE_ARMING)
         g_phase = PHASE_FLAT;
      return;
   }

   if(base_count == 2)
   {
      g_phase = PHASE_DUAL;
      g_anchor_since = 0;
      g_fallback_stage = FALLBACK_NONE;
      g_arming_second_sent = false;
      g_arming_first_order = 0;
      g_arming_second_order = 0;
      return;
   }

   if(base_count == 1 && brake_orders == 1)
   {
      if(g_anchor_since == 0 && g_phase != PHASE_ARMING)
         g_anchor_since = TimeTradeServer();
      g_phase = PHASE_BRAKE_PENDING;
      return;
   }

   if(base_count == 1 && brake_count >= 1)
   {
      if(g_anchor_since == 0)
         g_anchor_since = TimeTradeServer();
      g_phase = PHASE_BRAKED;
      if(BrakePositionVolume() + VolumeTolerance() >= g_positions[FindAnchorIndex()].volume)
         g_fallback_stage = FALLBACK_NONE;
      g_brake_order_ticket = 0;
      g_brake_cross_tick_msc = 0;
      g_brake_cross_local_msc = 0;
      return;
   }

   if(base_count == 1 && brake_count == 0 && brake_orders == 0)
   {
      if(g_phase != PHASE_ARMING && g_anchor_since == 0)
         g_anchor_since = TimeTradeServer();
      if(g_phase != PHASE_ARMING)
         g_phase = PHASE_ANCHOR;
   }
}

// -----------------------------------------------------------------------------
// Priority actions P0 through P8
// -----------------------------------------------------------------------------

bool HistoricalOrderTerminal(const ulong ticket, bool &filled, bool &unfilled)
{
   filled = false;
   unfilled = false;
   if(ticket == 0 || !HistoryOrderSelect(ticket))
      return false;

   const ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
   filled = (state == ORDER_STATE_FILLED || state == ORDER_STATE_PARTIAL);
   unfilled = (state == ORDER_STATE_CANCELED || state == ORDER_STATE_REJECTED || state == ORDER_STATE_EXPIRED);
   return (filled || unfilled);
}

bool ReconcileArmingTerminal()
{
   if(g_phase != PHASE_ARMING)
      return false;

   // Crash before PREPARED was flushed means OrderSend was never called. With
   // no broker inventory and no intent/order id it is safe to resume leg one.
   if(g_position_count == 0 && g_order_count == 0 && !HasOutstandingIntent() &&
      g_arming_first_order == 0)
   {
      const bool buy_first = ((g_cycle_id % 2) == 0);
      if(SendMarketOpen((buy_first ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), InpLots,
                        (buy_first ? ROLE_INITIAL_BUY : ROLE_INITIAL_SELL),
                        INTENT_ARM_FIRST))
      {
         g_arming_first_order = g_last_result_order;
         PersistState();
         return true;
      }
      ClearCycleState();
      return true;
   }

   if(TimeTradeServer() - g_cycle_start < 5)
      return false;

   bool filled = false;
   bool unfilled = false;
   if(g_position_count == 0 && HistoricalOrderTerminal(g_arming_first_order, filled, unfilled))
   {
      // The first request is terminal and no owned inventory remains. No late
      // fill is possible for this order, so flat-only re-arming is safe.
      ClearCycleState();
      return true;
   }

   if(BasePositionCount() == 1 && g_arming_second_sent &&
      HistoricalOrderTerminal(g_arming_second_order, filled, unfilled))
   {
      // If the terminal second leg is absent, it either never filled or has
      // already exited. In both cases the confirmed survivor is now the anchor.
      g_phase = PHASE_ANCHOR;
      g_anchor_since = TimeTradeServer();
      g_arming_second_sent = false;
      g_arming_first_order = 0;
      g_arming_second_order = 0;
      PersistState();
      return true;
   }
   return false;
}

bool HandleArmingCompletion()
{
   if(g_phase != PHASE_ARMING || BasePositionCount() != 1 || g_position_count != 1 || g_order_count != 0)
      return false;

   const int anchor_index = FindAnchorIndex();
   if(anchor_index < 0)
      return false;

   PositionRole missing_role;
   ENUM_ORDER_TYPE missing_type;
   if(g_positions[anchor_index].role == ROLE_INITIAL_BUY)
   {
      missing_role = ROLE_INITIAL_SELL;
      missing_type = ORDER_TYPE_SELL;
   }
   else
   {
      missing_role = ROLE_INITIAL_BUY;
      missing_type = ORDER_TYPE_BUY;
   }

   if(g_arming_second_sent)
      return false;

   if(SendMarketOpen(missing_type, InpLots, missing_role, INTENT_ARM_SECOND))
   {
      g_arming_second_sent = true;
      g_arming_second_order = g_last_result_order;
      PersistState();
      return true;
   }

   // A definitive synchronous rejection creates no unresolved intent; the
   // confirmed first leg converges to an anchor instead of being replayed.
   g_arming_second_sent = false;
   g_phase = PHASE_ANCHOR;
   g_anchor_since = TimeTradeServer();
   PersistState();
   return false;
}

bool BrakeSoftReleaseTriggered(const PositionRecord &brake)
{
   const double distance = InpBrakeSoftReleasePips * PipSize();
   if(brake.type == POSITION_TYPE_BUY)
      return (g_last_tick.bid <= brake.open_price - distance);
   return (g_last_tick.ask >= brake.open_price + distance);
}

bool HandleBrakeLifecycle()
{
   // Do not release a partially filled brake while its residual stop remains
   // live; that would invalidate the stop's residual-volume invariant.
   if(BrakeOrderCount() > 0)
      return false;

   // Partial fallback fills may legitimately produce multiple brake tickets.
   // Release one ticket per drive; the single-flight intent blocks duplicate
   // closes while its disappearance is not yet visible.
   for(int index = 0; index < g_position_count; ++index)
   {
      if(g_positions[index].role != ROLE_BRAKE)
         continue;
      if(BrakeSoftReleaseTriggered(g_positions[index]))
         return ClosePositionTicket(g_positions[index], "Brake one-pip soft release");
   }
   return false;
}

bool BrakeStopCrossed(const OrderRecord &order)
{
   if(order.type == ORDER_TYPE_BUY_STOP)
      return (g_last_tick.ask >= order.open_price);
   if(order.type == ORDER_TYPE_SELL_STOP)
      return (g_last_tick.bid <= order.open_price);
   return false;
}

bool HistoricalBrakeOrderOutcome(const ulong ticket, bool &terminal_unfilled, bool &filled)
{
   terminal_unfilled = false;
   filled = false;
   if(ticket == 0 || !HistoryOrderSelect(ticket))
      return false;

   const ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
   filled = (state == ORDER_STATE_FILLED || state == ORDER_STATE_PARTIAL);
   terminal_unfilled = (state == ORDER_STATE_CANCELED || state == ORDER_STATE_REJECTED || state == ORDER_STATE_EXPIRED);
   return (filled || terminal_unfilled);
}

bool HandlePendingBrake()
{
   const int anchor_index = FindAnchorIndex();
   const int order_index = FindBrakeOrderIndex();

   if(anchor_index < 0)
      return false;

   if(g_fallback_stage == FALLBACK_CANCEL_REQUESTED)
   {
      // Normally the durable INTENT_BRAKE_CANCEL is consumed by the generic
      // reconciler before reaching this branch. This path supports migration
      // from an older persisted state that has no intent record.
      if(order_index >= 0)
         return false;

      bool terminal_unfilled = false;
      bool filled = false;
      if(!HistoricalBrakeOrderOutcome(g_brake_order_ticket, terminal_unfilled, filled))
         return false;
      g_fallback_stage = (terminal_unfilled ? FALLBACK_MARKET_REQUIRED : FALLBACK_NONE);
      g_brake_order_ticket = 0;
      PersistState();
      return false;
   }

   if(g_fallback_stage == FALLBACK_MARKET_REQUIRED)
   {
      // The previous STOP is causally terminal. Submit exactly the missing
      // confirmed opposite volume once; the durable market intent prevents a
      // timer/callback/restart replay while broker visibility lags.
      if(SendMarketBrake(anchor_index))
      {
         g_fallback_stage = FALLBACK_MARKET_REQUESTED;
         PersistState();
         return true;
      }
      LatchResolution(RESOLVE_INVARIANT);
      return false;
   }

   if(g_fallback_stage == FALLBACK_MARKET_REQUESTED)
   {
      // ReconcileOutstandingIntent owns the accepted-but-invisible timeout.
      // Reaching here with no intent means it observed a live/complete fill.
      if(!HasOutstandingIntent())
      {
         g_fallback_stage = FALLBACK_NONE;
         g_brake_order_ticket = 0;
         PersistState();
      }
      return false;
   }

   if(FindBrakePositionIndex() >= 0 &&
      BrakePositionVolume() + VolumeTolerance() >= g_positions[anchor_index].volume)
   {
      g_fallback_stage = FALLBACK_NONE;
      return false;
   }

   if(order_index < 0)
   {
      g_brake_order_ticket = 0;
      return SendBrakeStop(anchor_index);
   }

   const OrderRecord order = g_orders[order_index];
   if(!BrakeStopCrossed(order))
   {
      // Final invariant #2: never modify or chase an accepted brake price.
      g_brake_cross_tick_msc = 0;
      g_brake_cross_local_msc = 0;
      return false;
   }

   if(g_brake_cross_tick_msc == 0)
   {
      g_brake_cross_tick_msc = g_last_tick.time_msc;
      g_brake_cross_local_msc = GetTickCount64();
      PersistState();
      return false;
   }

   const bool elapsed = (GetTickCount64() - g_brake_cross_local_msc >= InpBrakeDeadlineMs);
   const bool newer_tick = (g_last_tick.time_msc > g_brake_cross_tick_msc);
   if(!elapsed && !newer_tick)
      return false;

   // Zero-duplicate fallback: cancellation must be broker-confirmed by a later
   // inventory snapshot before a market hedge is permitted.
   if(DeleteOrderTicket(order.ticket, "Crossed brake fallback cancel", INTENT_BRAKE_CANCEL))
   {
      g_fallback_stage = FALLBACK_CANCEL_REQUESTED;
      PersistState();
      return true;
   }
   return false;
}

bool ArmFreshCycle()
{
   if(!StrictEntryGate())
      return false;

   ulong candidate = (g_last_tick.time_msc > 0 ? (ulong)g_last_tick.time_msc : (ulong)TimeTradeServer() * 1000);
   if(candidate <= g_last_cycle_id)
      candidate = g_last_cycle_id + 1;
   g_cycle_id = candidate;
   g_last_cycle_id = candidate;
   g_cycle_start = TimeTradeServer();
   g_anchor_since = 0;
   g_phase = PHASE_ARMING;
   g_harvested = false;
   g_resolve_reason = RESOLVE_NONE;
   g_arming_second_sent = false;
   g_arming_first_order = 0;
   g_arming_second_order = 0;
   PersistState();

   const bool buy_first = ((g_cycle_id % 2) == 0);
   const bool accepted = SendMarketOpen((buy_first ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), InpLots,
                                        (buy_first ? ROLE_INITIAL_BUY : ROLE_INITIAL_SELL),
                                        INTENT_ARM_FIRST);
   if(!accepted)
   {
      ClearCycleState();
      return false;
   }
   g_arming_first_order = g_last_result_order;
   PersistState();
   return true;
}

void Drive()
{
   if(g_drive_busy)
      return;
   g_drive_busy = true;

   if(!RefreshInstanceLease())
   {
      Print("Instance lease lost; suppressing all broker mutations to prevent duplicate execution.");
      g_drive_busy = false;
      return;
   }

   RefreshSnapshot();
   ReconcileTimedOutTombstone();
   InferPhase();
   // OrderSend and callbacks. No other action
   // may be emitted until the durable single-flight intent is causally settled.
   if(ReconcileOutstandingIntent())
   {
      g_drive_busy = false;
      return;
   }

   const bool active_cycle = (g_position_count > 0 || g_order_count > 0 ||
                              g_cycle_id != 0 || HasOutstandingIntent() || HasTimedOutTombstone() ||
                              TimeTradeServer() < g_quarantine_until);

   if(g_position_count == 0 && g_order_count == 0 && g_cycle_id != 0 &&
      !HasOutstandingIntent() && !HasTimedOutTombstone() &&
      TimeTradeServer() >= g_quarantine_until &&
      g_phase != PHASE_ARMING && g_resolve_reason == RESOLVE_NONE)
   {
      ClearCycleState();
      RefreshSnapshot();
   }

   // P0: invalid configuration or unavailable broker transport never initiates
   // exposure. CLOSEONLY still permits a previously latched cycle to flatten.
   if(!g_static_valid)
   {
      g_phase = PHASE_INVALID;
      g_drive_busy = false;
      return;
   }
   if(!BaseTradePermissionsAvailable())
   {
      if(active_cycle)
         LatchResolution(RESOLVE_RUNTIME_INVALID);
      g_drive_busy = false;
      return;
   }

   if(g_resolve_reason != RESOLVE_NONE)
   {
      if(CanReduceRisk())
         FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   if(active_cycle && !CanOpenRisk())
   {
      LatchResolution(RESOLVE_RUNTIME_INVALID);
      if(CanReduceRisk())
         FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   if(active_cycle && !InventoryShapeValid())
   {
      LatchResolution(RESOLVE_INVARIANT);
      if(CanReduceRisk())
         FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   double liquidation = 0.0;
   bool tp_found = false;
   if(active_cycle && !LiquidationValueGBP(liquidation, tp_found))
   {
      LatchResolution(RESOLVE_INVARIANT);
      if(CanReduceRisk())
         FlattenOneAction();
      g_drive_busy = false;
      return;
   }
   if(tp_found)
      g_harvested = true;

   // P1: hard monetary loss budget.
   if(active_cycle && liquidation <= -InpHardCycleLossGBP)
   {
      LatchResolution(RESOLVE_HARD_BUDGET);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   // P2: calendar and maximum anchor-age exits.
   if(active_cycle && InFridayWindow(InpFridayFlattenMinutes))
   {
      LatchResolution(RESOLVE_FRIDAY);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }
   if(active_cycle && InTripleSwapWindow())
   {
      LatchResolution(RESOLVE_TRIPLE_SWAP);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }
   if(active_cycle && MaximumAnchorAgeReached())
   {
      LatchResolution(RESOLVE_MAX_AGE);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   // P3: protection and arming invariants. Inventory shape was validated
   // before monetary policy so malformed/foreign records cannot contaminate
   // the cycle ledger.
   const ProtectionResult protection_result = ReconcileProtectionOneAction();
   if(protection_result == PROTECTION_FAILED)
   {
      LatchResolution(RESOLVE_INVARIANT);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }
   if(protection_result == PROTECTION_REQUESTED)
   {
      PersistState();
      g_drive_busy = false;
      return;
   }
   if(ReconcileArmingTerminal())
   {
      g_drive_busy = false;
      return;
   }
   if(HandleArmingCompletion())
   {
      PersistState();
      g_drive_busy = false;
      return;
   }

   // A failed second arming leg converges to a provisional anchor.
   InferPhase();

   // P4: soft distance and soft cash reset.
   if(FindAnchorIndex() >= 0 && AnchorAdversePips() >= InpPolicyResetPips)
   {
      LatchResolution(RESOLVE_SOFT_DISTANCE);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }
   if(active_cycle && liquidation <= -InpSoftCycleLossGBP)
   {
      LatchResolution(RESOLVE_SOFT_CASH);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   // P5: ledger escape is enabled only after a TP harvest created imbalance.
   if(g_harvested && FindAnchorIndex() >= 0 && liquidation >= InpLedgerEscapeTargetGBP)
   {
      LatchResolution(RESOLVE_LEDGER_ESCAPE);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }

   // P6: live brake TP is server-side; reversal release is EA-managed.
   if(HandleBrakeLifecycle())
   {
      PersistState();
      g_drive_busy = false;
      return;
   }

   // P7: immutable pending brake and cancel-confirm-market fallback.
   if(g_phase != PHASE_ARMING && FindAnchorIndex() >= 0 && BasePositionCount() == 1 &&
      BrakePositionVolume() + VolumeTolerance() < g_positions[FindAnchorIndex()].volume)
   {
      if(HandlePendingBrake())
      {
         PersistState();
         g_drive_busy = false;
         return;
      }
   }

   // P8: only a fully flat, order-free cycle may arm a fresh symmetric pair.
   if(g_position_count == 0 && g_order_count == 0 && g_cycle_id == 0 &&
      !HasOutstandingIntent() && !HasTimedOutTombstone() &&
      !InFridayWindow(InpNoNewRiskBeforeCloseMinutes) && !NearTripleSwapRollover())
      ArmFreshCycle();

   PersistState();
   g_drive_busy = false;
}

// -----------------------------------------------------------------------------
// Initialization and event handlers
// -----------------------------------------------------------------------------

bool ValidateStaticConfiguration()
{
   if(AccountInfoString(ACCOUNT_CURRENCY) != "GBP")
   {
      Print("Initialization failed: account deposit currency must be GBP for the GBP risk budget.");
      return false;
   }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Initialization failed: a retail hedging account is required.");
      return false;
   }
   if(SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE) != "EUR" ||
      SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT) != "USD")
   {
      Print("Initialization failed: attach the EA to a EUR/USD symbol, including broker suffixes.");
      return false;
   }

   const double volume_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double volume_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpLots < volume_min || InpLots > volume_max || volume_step <= 0.0 ||
      MathAbs(InpLots / volume_step - MathRound(InpLots / volume_step)) > 1.0e-8)
   {
      Print("Initialization failed: 0.02 lot volume is invalid for this symbol.");
      return false;
   }

   const long order_modes = SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE);
   if((order_modes & SYMBOL_ORDER_MARKET) != SYMBOL_ORDER_MARKET ||
      (order_modes & SYMBOL_ORDER_STOP) != SYMBOL_ORDER_STOP ||
      (order_modes & SYMBOL_ORDER_SL) != SYMBOL_ORDER_SL ||
      (order_modes & SYMBOL_ORDER_TP) != SYMBOL_ORDER_TP)
   {
      Print("Initialization failed: symbol lacks market, stop, SL, or TP support.");
      return false;
   }

   const long filling_modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   const ENUM_SYMBOL_TRADE_EXECUTION execution =
      (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);
   if(execution == SYMBOL_TRADE_EXECUTION_MARKET &&
      (filling_modes & (SYMBOL_FILLING_FOK | SYMBOL_FILLING_IOC)) == 0)
   {
      Print("Initialization failed: market execution requires FOK or IOC filling support.");
      return false;
   }

   const double min_stop_pips = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                                SymbolInfoDouble(_Symbol, SYMBOL_POINT) / PipSize();
   if(InpTakeProfitPips <= min_stop_pips)
   {
      PrintFormat("Initialization failed: %.2f-pip TP does not exceed broker stop level %.2f pips.",
                  InpTakeProfitPips, min_stop_pips);
      return false;
   }

   if(InpLots <= 0.0 || InpTakeProfitPips <= 0.0 || InpAnchorServerStopPips <= 0.0 ||
      InpPolicyResetPips <= 0.0 || InpPolicyResetPips >= InpAnchorServerStopPips ||
      InpSoftCycleLossGBP <= 0.0 || InpHardCycleLossGBP <= InpSoftCycleLossGBP ||
      InpEmergencySlippageReserveGBP < 0.0 || InpUnlinkedChargeReserveGBP < 0.0 ||
      InpEmergencySlippageReserveGBP + InpUnlinkedChargeReserveGBP >= InpHardCycleLossGBP ||
      InpBrakeOffsetPips <= 0.0 || InpBrakeSoftReleasePips <= 0.0 ||
      InpBrakeDeadlineMs == 0 || InpIntentTimeoutMs <= InpBrakeDeadlineMs ||
      InpUnknownIntentQuarantineMs < InpIntentTimeoutMs || InpSettlementQuietMs == 0 ||
      InpTimerPeriodMs < 10 || InpTimerPeriodMs > 60000 || InpLeaseStaleSeconds < 5 ||
      InpTimedOutIntentRetentionMinutes == 0 ||
      InpNoNewRiskBeforeCloseMinutes > 1440 || InpFridayFlattenMinutes > 1440 ||
      InpTripleSwapFlattenMinutes > 1440 ||
      InpTripleSwapRolloverHour < 0 || InpTripleSwapRolloverHour > 23 ||
      InpTripleSwapRolloverMinute < 0 || InpTripleSwapRolloverMinute > 59)
   {
      Print("Initialization failed: one or more strategy inputs are inconsistent.");
      return false;
   }
   return true;
}

int OnInit()
{
   const string instance_identity = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "|" +
                                    _Symbol + "|" + IntegerToString(InpMagic);
   g_global_prefix = EA_TAG + "." + IntegerToString((long)StableInstanceHash(instance_identity)) + ".";
   if(StringLen(StateKey("intent_targetby_hi")) > 63)
   {
      Print("Initialization failed: persistence key exceeds terminal limit.");
      return INIT_FAILED;
   }
   if(!AcquireInstanceLease())
   {
      Print("Initialization failed: another EA instance owns this account/symbol/magic lease.");
      return INIT_FAILED;
   }
   LoadState();

   if(!SymbolInfoTick(_Symbol, g_last_tick))
      ZeroMemory(g_last_tick);
   else
   {
      g_last_tick_local_msc = GetTickCount64();
      RecordTick(g_last_tick);
   }

   RefreshSnapshot();
   const bool configuration_valid = ValidateStaticConfiguration();
   g_entry_config_valid = configuration_valid;
   if(!configuration_valid && g_position_count == 0 && g_order_count == 0 &&
      g_cycle_id == 0 && !HasOutstandingIntent() && !HasTimedOutTombstone())
   {
      ReleaseInstanceLease();
      return INIT_FAILED;
   }

   // If configuration became invalid while owned inventory exists, remain
   // loaded only to cancel/flatten that inventory; never open a new cycle.
   g_static_valid = true;
   if(!configuration_valid)
      LatchResolution(RESOLVE_RUNTIME_INVALID);

   if(g_position_count == 0 && g_order_count == 0 && g_cycle_id != 0 &&
      !HasOutstandingIntent() && !HasTimedOutTombstone() &&
      TimeTradeServer() >= g_quarantine_until &&
      g_phase != PHASE_ARMING && g_resolve_reason == RESOLVE_NONE)
      ClearCycleState();
   else
   {
      InferPhase();
      PersistState();
   }

   if(!EventSetMillisecondTimer((int)InpTimerPeriodMs))
   {
      PrintFormat("Millisecond timer unavailable, error=%d; attempting one-second safety timer", GetLastError());
      if(!EventSetTimer(1))
      {
         PrintFormat("Initialization failed: no watchdog timer could be created, error=%d", GetLastError());
         ReleaseInstanceLease();
         return INIT_FAILED;
      }
   }
   Drive();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PersistState();
   ReleaseInstanceLease();
   EventKillTimer();
   PrintFormat("EA deinitialized, reason=%d", reason);
}

void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_last_tick))
      return;
   g_last_tick_local_msc = GetTickCount64();
   RecordTick(g_last_tick);
   if(CurrentTickEntryAdmissible())
      ++g_entry_admissible_ticks;
   else
      g_entry_admissible_ticks = 0;
   Drive();
}

void OnTimer()
{
   Drive();
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Capture identifiers opportunistically; broker inventory/history remains
   // authoritative because transaction arrival order is not guaranteed.
   if(HasOutstandingIntent() && request.magic == (ulong)InpMagic)
   {
      ulong request_cycle = 0;
      ulong request_generation = 0;
      ParseIntentCommentEx(request.comment, request_cycle, request_generation);
      const bool same_intent = (result.request_id == g_intent_request_id ||
                                (request_cycle == g_intent_cycle &&
                                 request_generation == g_intent_generation));
      if(same_intent)
      {
         if(g_intent_request_id == 0)
            g_intent_request_id = result.request_id;
         if(g_intent_order_ticket == 0 && transaction.order != 0)
            g_intent_order_ticket = transaction.order;
         if(g_intent_deal_ticket == 0 && transaction.deal != 0)
            g_intent_deal_ticket = transaction.deal;
         PersistState();
      }
   }

   if(transaction.type == TRADE_TRANSACTION_DEAL_ADD ||
      transaction.type == TRADE_TRANSACTION_ORDER_ADD ||
      transaction.type == TRADE_TRANSACTION_ORDER_UPDATE ||
      transaction.type == TRADE_TRANSACTION_ORDER_DELETE ||
      transaction.type == TRADE_TRANSACTION_POSITION ||
      result.request_id == g_last_action_request_id ||
      request.magic == (ulong)InpMagic)
      Drive();
}
