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
input double InpPolicyResetPips               = 25.0;
input double InpSoftCycleLossGBP              = 3.24;
input double InpHardCycleLossGBP              = 7.79;
input double InpLedgerEscapeTargetGBP         = 0.00;
input double InpExitCommissionPerLotGBP       = 3.50;
input double InpEmergencySlippageReserveGBP   = 0.20;
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
   FALLBACK_MARKET_REQUESTED
};

struct PositionRecord
{
   ulong              ticket;
   ulong              identifier;
   ulong              cycle_id;
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

string StateKey(const string suffix)
{
   return g_global_prefix + suffix;
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
   GlobalVariableSet(StateKey("brake_order"), (double)g_brake_order_ticket);
   GlobalVariableSet(StateKey("arm_second"),  (g_arming_second_sent ? 1.0 : 0.0));
   GlobalVariableSet(StateKey("arm_first_id"),(double)g_arming_first_order);
   GlobalVariableSet(StateKey("arm_second_id"),(double)g_arming_second_order);
   GlobalVariablesFlush();
}

void LoadState()
{
   if(GlobalVariableCheck(StateKey("cycle")))
      g_cycle_id = (ulong)GlobalVariableGet(StateKey("cycle"));
   if(GlobalVariableCheck(StateKey("last_cycle")))
      g_last_cycle_id = (ulong)GlobalVariableGet(StateKey("last_cycle"));
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
   if(GlobalVariableCheck(StateKey("brake_order")))
      g_brake_order_ticket = (ulong)GlobalVariableGet(StateKey("brake_order"));
   if(GlobalVariableCheck(StateKey("arm_second")))
      g_arming_second_sent = (GlobalVariableGet(StateKey("arm_second")) > 0.5);
   if(GlobalVariableCheck(StateKey("arm_first_id")))
      g_arming_first_order = (ulong)GlobalVariableGet(StateKey("arm_first_id"));
   if(GlobalVariableCheck(StateKey("arm_second_id")))
      g_arming_second_order = (ulong)GlobalVariableGet(StateKey("arm_second_id"));
}

void ClearCycleState()
{
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

string IntentComment(const PositionRole role)
{
   return StringFormat("%s|%I64u|%s", EA_TAG, g_cycle_id, RoleCode(role));
}

PositionRole ParseIntentComment(const string comment, ulong &cycle_id)
{
   cycle_id = 0;
   if(StringFind(comment, EA_TAG + "|") != 0)
      return ROLE_UNKNOWN;

   const int first = StringLen(EA_TAG) + 1;
   const int separator = StringFind(comment, "|", first);
   if(separator < 0)
      return ROLE_UNKNOWN;

   const string cycle_text = StringSubstr(comment, first, separator - first);
   const string role_text = StringSubstr(comment, separator + 1);
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
      const PositionRole role = ParseIntentComment(PositionGetString(POSITION_COMMENT), observed_cycle);
      if(role == ROLE_UNKNOWN || !AdoptOrValidateCycle(observed_cycle))
         g_snapshot_invalid = true;

      PositionRecord record;
      record.ticket       = ticket;
      record.identifier   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      record.cycle_id     = observed_cycle;
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
      const PositionRole role = ParseIntentComment(OrderGetString(ORDER_COMMENT), observed_cycle);
      if(role != ROLE_BRAKE || !AdoptOrValidateCycle(observed_cycle))
         g_snapshot_invalid = true;

      OrderRecord record;
      record.ticket          = ticket;
      record.cycle_id        = observed_cycle;
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
      datetime earliest = TimeTradeServer();
      for(int index = 0; index < g_position_count; ++index)
         if(g_positions[index].open_time < earliest)
            earliest = g_positions[index].open_time;
      g_cycle_start = earliest;
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

bool RealizedCycleNet(double &realized, bool &tp_harvest_found)
{
   realized = 0.0;
   tp_harvest_found = false;
   if(g_cycle_id == 0)
      return true;

   datetime from_time = g_cycle_start;
   if(from_time <= 0)
      return false;
   from_time -= 60;

   if(!HistorySelect(from_time, TimeTradeServer() + 60))
      return false;

   ulong position_ids[];
   int position_id_count = 0;
   for(int index = 0; index < g_position_count; ++index)
      AddUniquePositionId(g_positions[index].identifier, position_ids, position_id_count);

   const string prefix = StringFormat("%s|%I64u|", EA_TAG, g_cycle_id);
   const int deal_total = HistoryDealsTotal();
   bool cycle_deal_found = false;
   for(int index = 0; index < deal_total; ++index)
   {
      const ulong deal = HistoryDealGetTicket(index);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      const string comment = HistoryDealGetString(deal, DEAL_COMMENT);
      if(StringFind(comment, prefix) == 0)
      {
         cycle_deal_found = true;
         AddUniquePositionId((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID), position_ids, position_id_count);
      }
   }

   if((g_position_count > 0 || g_order_count > 0) && !cycle_deal_found && position_id_count == 0)
      return false;

   for(int index = 0; index < deal_total; ++index)
   {
      const ulong deal = HistoryDealGetTicket(index);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;

      const ulong position_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(!PositionIdInArray(position_id, position_ids, position_id_count))
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
   return ORDER_FILLING_RETURN;
}

bool RetcodeAccepted(const uint retcode)
{
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_PLACED ||
           retcode == TRADE_RETCODE_DONE_PARTIAL ||
           retcode == TRADE_RETCODE_NO_CHANGES);
}

bool SubmitRequest(MqlTradeRequest &request, const string label, const bool check_request)
{
   MqlTradeResult result;
   ZeroMemory(result);

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

   ResetLastError();
   const bool sent = OrderSend(request, result);
   g_last_action_request_id = result.request_id;
   g_last_result_order = result.order;
   if(!sent || !RetcodeAccepted(result.retcode))
   {
      PrintFormat("%s rejected: sent=%s retcode=%u comment=%s error=%d",
                  label, (sent ? "true" : "false"), result.retcode, result.comment, GetLastError());
      return false;
   }

   PrintFormat("%s accepted: retcode=%u order=%I64u deal=%I64u request=%u",
               label, result.retcode, result.order, result.deal, result.request_id);
   return true;
}

bool SendMarketOpen(const ENUM_ORDER_TYPE type, const double volume, const PositionRole role)
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
   return SubmitRequest(request, "Market open " + RoleCode(role), true);
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
   const double raw_price = (need_buy ? tick.ask + effective_h * pip : tick.bid - effective_h * pip);
   const double stop_price = (need_buy ? NormalizePriceUp(raw_price) : NormalizePriceDown(raw_price));

   MqlTradeRequest request;
   ZeroMemory(request);
   request.action       = TRADE_ACTION_PENDING;
   request.magic        = (ulong)InpMagic;
   request.symbol       = _Symbol;
   request.volume       = anchor.volume;
   request.type         = (need_buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
   request.price        = stop_price;
   request.type_filling = ORDER_FILLING_RETURN;
   request.type_time    = ORDER_TIME_GTC;
   request.comment      = IntentComment(ROLE_BRAKE);
   request.sl           = NormalizePriceNearest(stop_price + (need_buy ? -1.0 : 1.0) * InpAnchorServerStopPips * pip);
   request.tp           = NormalizePriceNearest(stop_price + (need_buy ? 1.0 : -1.0) * InpTakeProfitPips * pip);

   const bool accepted = SubmitRequest(request, "Immutable brake stop", true);
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

   const double required = MathMax(0.0, anchor.volume - confirmed_opposite);
   if(required <= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP) * 0.25)
      return true;

   if(confirmed_opposite + required > InpLots + SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP) * 0.25)
      return false;

   const ENUM_ORDER_TYPE type = (anchor.type == POSITION_TYPE_SELL ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   return SendMarketOpen(type, required, ROLE_BRAKE);
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
   return SubmitRequest(request, label, false);
}

bool DeleteOrderTicket(const ulong ticket, const string label)
{
   MqlTradeRequest request;
   ZeroMemory(request);
   request.action = TRADE_ACTION_REMOVE;
   request.magic  = (ulong)InpMagic;
   request.symbol = _Symbol;
   request.order  = ticket;
   return SubmitRequest(request, label, false);
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
   return SubmitRequest(request, label, false);
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
   return SubmitRequest(request, "Close-by cycle pair", false);
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
   const int current_second = now_parts.hour * 3600 + now_parts.min * 60 + now_parts.sec;
   return (current_second >= FridaySessionCloseSecond() - (int)minutes_before_close * 60);
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
   if(order.type != expected_type || !VolumeEqual(order.volume_current, anchor.volume) || order.open_price <= 0.0)
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
   if(g_position_count > 2 || g_order_count > 1)
      return false;

   const int base_count = BasePositionCount();
   const int brake_count = BrakePositionCount();
   const int brake_orders = BrakeOrderCount();

   if(base_count + brake_count != g_position_count || brake_orders != g_order_count)
      return false;

   for(int index = 0; index < g_position_count; ++index)
      if(!VolumeEqual(g_positions[index].volume, InpLots))
         return false;
   for(int index = 0; index < g_order_count; ++index)
      if(!VolumeEqual(g_orders[index].volume_current, InpLots))
         return false;

   if(base_count == 2)
   {
      if(brake_count != 0 || brake_orders != 0)
         return false;
      if(g_positions[0].type == g_positions[1].type)
         return false;
      return true;
   }

   if(base_count == 1)
   {
      if(brake_count == 1)
      {
         const int anchor_index = FindAnchorIndex();
         const int brake_index = FindBrakePositionIndex();
         if(brake_orders != 0 || anchor_index < 0 || brake_index < 0)
            return false;
         if(g_positions[anchor_index].type == g_positions[brake_index].type)
            return false;
         return VolumeEqual(g_positions[anchor_index].volume, g_positions[brake_index].volume);
      }
      return (brake_count == 0 && brake_orders <= 1);
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

bool FlattenOneAction()
{
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

   // A one-sided anchor always has TP=0 before a pending or live brake exists.
   // This removes the stop-fill/anchor-TP race and strictly implies TP=0 while braked.
   if(anchor_index >= 0)
   {
      const ProtectionResult anchor_result = EnsurePositionProtection(g_positions[anchor_index], true);
      if(anchor_result != PROTECTION_UNCHANGED)
         return anchor_result;
   }

   if(brake_index >= 0)
   {
      const ProtectionResult brake_result = EnsurePositionProtection(g_positions[brake_index], false);
      if(brake_result != PROTECTION_UNCHANGED)
         return brake_result;
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

   if(base_count == 1 && brake_count == 1)
   {
      if(g_anchor_since == 0)
         g_anchor_since = TimeTradeServer();
      g_phase = PHASE_BRAKED;
      g_fallback_stage = FALLBACK_NONE;
      g_brake_order_ticket = 0;
      g_brake_cross_tick_msc = 0;
      g_brake_cross_local_msc = 0;
      return;
   }

   if(base_count == 1 && brake_orders == 1)
   {
      if(g_anchor_since == 0 && g_phase != PHASE_ARMING)
         g_anchor_since = TimeTradeServer();
      g_phase = PHASE_BRAKE_PENDING;
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
   if(g_phase != PHASE_ARMING || TimeTradeServer() - g_cycle_start < 5)
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

   g_arming_second_sent = true;
   PersistState();
   if(SendMarketOpen(missing_type, InpLots, missing_role))
   {
      g_arming_second_order = g_last_result_order;
      PersistState();
      return true;
   }

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
   const int brake_index = FindBrakePositionIndex();
   if(brake_index < 0)
      return false;

   if(BrakeSoftReleaseTriggered(g_positions[brake_index]))
      return ClosePositionTicket(g_positions[brake_index], "Brake one-pip soft release");
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

   if(FindBrakePositionIndex() >= 0)
   {
      g_fallback_stage = FALLBACK_NONE;
      return false;
   }

   if(g_fallback_stage == FALLBACK_CANCEL_REQUESTED)
   {
      if(order_index >= 0)
         return false;

      bool terminal_unfilled = false;
      bool filled = false;
      if(!HistoricalBrakeOrderOutcome(g_brake_order_ticket, terminal_unfilled, filled))
         return false;

      if(filled)
      {
         // Never overlap a market fallback with a stop that filled or partially filled.
         // Wait for its position/deal reconciliation; if it already closed, start a new
         // immutable brake instance rather than replaying the old hedge.
         g_fallback_stage = FALLBACK_NONE;
         g_brake_order_ticket = 0;
         PersistState();
         return false;
      }

      if(!terminal_unfilled)
         return false;

      // Final invariant #3: after a causally confirmed terminal non-fill,
      // calculate only the missing confirmed protective volume.
      g_fallback_stage = FALLBACK_MARKET_REQUESTED;
      PersistState();
      if(SendMarketBrake(anchor_index))
         return true;

      LatchResolution(RESOLVE_INVARIANT);
      return false;
   }

   if(g_fallback_stage == FALLBACK_MARKET_REQUESTED)
   {
      // A synchronous accepted market request is never replayed. It either
      // appears as confirmed inventory or the cycle is flattened conservatively.
      if(FindBrakePositionIndex() >= 0)
      {
         g_fallback_stage = FALLBACK_NONE;
         g_brake_order_ticket = 0;
         PersistState();
      }
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
   if(DeleteOrderTicket(order.ticket, "Crossed brake fallback cancel"))
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
   g_arming_failures = 0;
   g_arming_second_sent = false;
   g_arming_first_order = 0;
   g_arming_second_order = 0;
   PersistState();

   const bool buy_first = ((g_cycle_id % 2) == 0);
   const bool accepted = SendMarketOpen((buy_first ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), InpLots,
                                        (buy_first ? ROLE_INITIAL_BUY : ROLE_INITIAL_SELL));
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

   RefreshSnapshot();
   InferPhase();

   const bool active_cycle = (g_position_count > 0 || g_order_count > 0);

   if(g_position_count == 0 && g_order_count == 0 && g_cycle_id != 0 &&
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

   // P3: inventory and protection invariants.
   if(!InventoryShapeValid())
   {
      LatchResolution(RESOLVE_INVARIANT);
      FlattenOneAction();
      g_drive_busy = false;
      return;
   }
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
   if(g_phase != PHASE_ARMING && FindAnchorIndex() >= 0 &&
      BasePositionCount() == 1 && BrakePositionCount() == 0)
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
      InpBrakeOffsetPips <= 0.0 || InpBrakeSoftReleasePips <= 0.0 ||
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
   g_global_prefix = EA_TAG + "." + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "." +
                     _Symbol + "." + IntegerToString(InpMagic) + ".";
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
   if(!configuration_valid && g_position_count == 0 && g_order_count == 0)
      return INIT_FAILED;

   // If configuration became invalid while owned inventory exists, remain
   // loaded only to cancel/flatten that inventory; never open a new cycle.
   g_static_valid = true;
   if(!configuration_valid)
      LatchResolution(RESOLVE_RUNTIME_INVALID);

   if(g_position_count == 0 && g_order_count == 0 && g_cycle_id != 0 &&
      g_phase != PHASE_ARMING && g_resolve_reason == RESOLVE_NONE)
      ClearCycleState();
   else
   {
      InferPhase();
      PersistState();
   }

   EventSetMillisecondTimer((int)MathMax(10, (int)InpTimerPeriodMs));
   Drive();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PersistState();
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
   // The callback is only a wake-up signal. Broker inventory/history is the
   // authoritative state because transaction arrival order is not guaranteed.
   if(transaction.type == TRADE_TRANSACTION_DEAL_ADD ||
      transaction.type == TRADE_TRANSACTION_ORDER_ADD ||
      transaction.type == TRADE_TRANSACTION_ORDER_UPDATE ||
      transaction.type == TRADE_TRANSACTION_ORDER_DELETE ||
      transaction.type == TRADE_TRANSACTION_POSITION ||
      result.request_id == g_last_action_request_id ||
      request.magic == (ulong)InpMagic)
      Drive();
}
