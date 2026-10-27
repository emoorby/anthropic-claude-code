//+------------------------------------------------------------------+
//|                                           BreakAndBounce_EA.mq5  |
//|  Break & Bounce: previous-day range -> 15m close breakout ->     |
//|  5m retest of the broken level with a hammer / engulfing candle. |
//|  Converted from ProRealTime and extended with the rules from the |
//|  strategy video (prior-move filter, break-of-candle entries,     |
//|  intrabar engulfing entry, one setup per day, EOD exit).         |
//|                                                                  |
//|  Attach to any chart of the symbol (timeframe-independent).      |
//|  ALL TIMES ARE BROKER SERVER TIME.                               |
//+------------------------------------------------------------------+
#property copyright "Break & Bounce EA"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- enums
enum ENUM_RANGE_SRC   {RANGE_D1=0,         // Broker D1 bar (incl. overnight on CFDs)
                       RANGE_SESSION=1};   // Custom session window (e.g. cash hours)
enum ENUM_UNITS       {UNITS_POINTS=0,     // Points
                       UNITS_RANGE_PCT=1}; // % of previous-day range
enum ENUM_SL_MODE     {SL_CANDLE=0,        // Signal candle extreme +/- buffer (video)
                       SL_LEVEL=1,         // Breakout level +/- buffer (live demo)
                       SL_PRT=2};          // Level -/+ candle range x factor (PRT code)
enum ENUM_HAM_ENTRY   {HAM_AT_CLOSE=0,     // Market at hammer close (live demo / PRT)
                       HAM_BREAK=1};       // Stop entry at break of hammer high/low (video)
enum ENUM_ENG_MODE    {ENG_INTRABAR=0,     // Enter as price takes prev candle high/low (video)
                       ENG_ON_CLOSE=1,     // Wait for close; high/low range engulf
                       ENG_PRT_STRICT=2};  // Wait for close; body beyond prev range (PRT)
enum ENUM_LOT_MODE    {LOT_FIXED=0,        // Fixed lots
                       LOT_RISK_PCT=1};    // % of equity at risk

//--- inputs
input group "=== General ==="
input ulong           InpMagic             = 240611;        // Magic number
input string          InpComment           = "BreakBounce"; // Trade comment
input bool            InpTradeLong         = true;          // Allow long setups
input bool            InpTradeShort        = true;          // Allow short setups
input int             InpMaxTradesPerDay   = 1;             // Max trades per day
input int             InpMaxSpreadPts      = 0;             // Max spread in points (0=off)
input bool            InpDrawLevels        = true;          // Draw previous-day box

input group "=== Session (server time) ==="
input int             InpOpenHour          = 16;            // Market open hour (e.g. US 9:30 ET)
input int             InpOpenMin           = 30;            // Market open minute
input int             InpEntryWindowMins   = 150;           // Entry window after open (mins)
input bool            InpBreakoutInWindow  = true;          // Breakout must also close inside window
input int             InpExitHour          = 22;            // Flat-by hour (market close)
input int             InpExitMin           = 55;            // Flat-by minute

input group "=== Step 1: Previous-day range ==="
input ENUM_RANGE_SRC  InpRangeSource       = RANGE_D1;      // Range source
input int             InpRangeStartHour    = 16;            // Session range start hour
input int             InpRangeStartMin     = 30;            // Session range start minute
input int             InpRangeEndHour      = 23;            // Session range end hour
input int             InpRangeEndMin       = 0;             // Session range end minute
input bool            InpSkipSundayBar     = true;          // D1: skip Sunday stub bar
input int             InpATRPeriod         = 14;            // D1 ATR period (range filter)
input double          InpMinRangeATR       = 0.0;           // Min prev range / ATR (0=off)
input double          InpMaxRangeATR       = 0.0;           // Max prev range / ATR (0=off)
input bool            InpSkipGapOutside    = false;         // Skip day if session opens outside range

input group "=== Step 2: Breakout ==="
input ENUM_TIMEFRAMES InpBreakTF           = PERIOD_M15;    // Breakout timeframe
input bool            InpAllowFlip         = false;         // Opposite breakout replaces first one

input group "=== Step 3: Retest & candle ==="
input ENUM_TIMEFRAMES InpSignalTF          = PERIOD_M5;     // Signal timeframe
input bool            InpRequireCloseBeyond= true;          // Signal candle must close beyond level
input bool            InpUseHammer         = true;          // Use hammer / inverted hammer
input double          InpHamWickBody       = 2.0;           // Hammer: rejection wick >= x body
input double          InpHamOppWickBody    = 1.0;           // Hammer: opposite wick < x body
input int             InpPriorMoveBars     = 3;             // Hammer: bars of prior counter-move (0=off)
input ENUM_HAM_ENTRY  InpHammerEntry       = HAM_BREAK;     // Hammer entry type
input int             InpHamBreakBars      = 2;             // Hammer break: bars the stop entry stays valid
input bool            InpUseEngulf         = true;          // Use engulfing
input ENUM_ENG_MODE   InpEngulfMode        = ENG_INTRABAR;  // Engulfing mode
input bool            InpEngPrevOpposite   = true;          // Engulfed candle must be opposite colour

input group "=== Distances (units below) ==="
input ENUM_UNITS      InpUnits             = UNITS_RANGE_PCT; // Units for distance inputs
input double          InpBreakBuffer       = 0.0;           // Breakout: close beyond level by
input double          InpRetestTol         = 5.0;           // Retest: wick within this of level
input double          InpMaxPenetration    = 25.0;          // Retest: max wick back inside range (0=off)
input double          InpEntryBuffer       = 0.0;           // Stop-entry buffer beyond trigger
input double          InpSLBuffer          = 2.0;           // SL buffer
input double          InpMinSL             = 5.0;           // Min SL distance (widen to this, 0=off)
input double          InpMaxSL             = 0.0;           // Max SL distance (skip trade, 0=off)

input group "=== Risk & exits ==="
input ENUM_SL_MODE    InpSLMode            = SL_CANDLE;     // Stop-loss placement
input double          InpSLRangeFactor     = 0.2;           // SL_PRT: candle range factor
input double          InpRR                = 3.0;           // Target as multiple of risk
input double          InpBreakevenR        = 0.0;           // Move SL to entry at x R (0=off)
input ENUM_LOT_MODE   InpLotMode           = LOT_RISK_PCT;  // Lot sizing
input double          InpLots              = 0.1;           // Fixed lots
input double          InpRiskPct           = 0.5;           // Risk % of equity per trade

input group "=== Optimisation ==="
input int             InpMinTradesOpt      = 30;            // OnTester: min trades for a score

//--- state
struct Trigger {bool active; int dir; double price; double sl; datetime expiry;};

datetime g_day = 0, g_sessStart, g_winEnd, g_exitTime;
datetime g_breakFrom, g_lastBrkBar, g_lastBrkDone, g_lastSigBar, g_engDoneBar;
double   g_hi, g_lo, g_unit;
int      g_dir, g_tradesToday;
bool     g_rangeOk, g_dayBlocked, g_gapChecked;
MqlRates g_p1;                       // last closed signal bar
Trigger  g_trig;
int      g_atr = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   if(PeriodSeconds(InpSignalTF) >= PeriodSeconds(InpBreakTF))
   {
      Print("Signal timeframe must be lower than breakout timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMinRangeATR > 0 || InpMaxRangeATR > 0)
   {
      g_atr = iATR(_Symbol, PERIOD_D1, InpATRPeriod);
      if(g_atr == INVALID_HANDLE) return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atr != INVALID_HANDLE) IndicatorRelease(g_atr);
   ObjectsDeleteAll(0, "BB_");
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   datetime day = now - now % 86400;
   if(day != g_day) NewDay(day);

   int open = ManagePositions(now);

   if(!g_rangeOk || g_dayBlocked || now < g_sessStart) return;

   //--- Step 2: look for a closed breakout-TF candle beyond the range
   datetime tb = iTime(_Symbol, InpBreakTF, 0);
   if(tb != g_lastBrkBar) { g_lastBrkBar = tb; ScanBreakouts(); if(g_dayBlocked) return; }

   //--- cache last closed signal bar
   datetime ts = iTime(_Symbol, InpSignalTF, 0);
   bool newSig = (ts != g_lastSigBar);
   if(newSig)
   {
      MqlRates r[1];
      if(CopyRates(_Symbol, InpSignalTF, 1, 1, r) == 1) { g_p1 = r[0]; g_lastSigBar = ts; }
      else newSig = false;
   }

   if(g_dir == 0) return;
   if(now >= g_winEnd || g_tradesToday >= InpMaxTradesPerDay || open > 0) { g_trig.active = false; return; }

   //--- Step 3
   if(newSig) OnNewSignalBar();
   CheckIntrabar(now, ts);
}

//+------------------------------------------------------------------+
//| Reset daily state and build yesterday's box                      |
//+------------------------------------------------------------------+
void NewDay(datetime day)
{
   g_day = day;
   g_dir = 0; g_tradesToday = 0;
   g_trig.active = false;
   g_dayBlocked = false; g_gapChecked = false;
   g_breakFrom = 0; g_lastBrkBar = 0; g_lastBrkDone = 0; g_engDoneBar = 0;
   g_sessStart = day + InpOpenHour * 3600 + InpOpenMin * 60;
   g_winEnd    = g_sessStart + InpEntryWindowMins * 60;
   g_exitTime  = day + InpExitHour * 3600 + InpExitMin * 60;
   g_rangeOk   = CalcRange(day);
   if(!g_rangeOk) return;

   g_unit = (InpUnits == UNITS_POINTS) ? _Point : (g_hi - g_lo) / 100.0;

   if(InpDrawLevels && !MQLInfoInteger(MQL_OPTIMIZATION))
   {
      string name = "BB_" + TimeToString(day, TIME_DATE);
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, day, g_hi, g_exitTime, g_lo);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrSteelBlue);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
}

bool CalcRange(datetime day)
{
   int s = iBarShift(_Symbol, PERIOD_D1, day - 1, false);   // last D1 bar before today
   if(s < 0) return false;
   MqlDateTime dt;
   TimeToStruct(iTime(_Symbol, PERIOD_D1, s), dt);
   if(InpSkipSundayBar && dt.day_of_week == 0) s++;
   datetime prev = iTime(_Symbol, PERIOD_D1, s);
   if(prev == 0) return false;

   if(InpRangeSource == RANGE_D1)
   {
      g_hi = iHigh(_Symbol, PERIOD_D1, s);
      g_lo = iLow(_Symbol, PERIOD_D1, s);
   }
   else
   {
      datetime from = prev + InpRangeStartHour * 3600 + InpRangeStartMin * 60;
      datetime to   = prev + InpRangeEndHour * 3600 + InpRangeEndMin * 60 - 1;
      double h[], l[];
      int n = CopyHigh(_Symbol, PERIOD_M5, from, to, h);
      if(n <= 0 || CopyLow(_Symbol, PERIOD_M5, from, to, l) != n) return false;
      g_hi = h[ArrayMaximum(h)];
      g_lo = l[ArrayMinimum(l)];
   }
   if(g_hi <= g_lo) return false;

   if(g_atr != INVALID_HANDLE)
   {
      double a[1];
      if(CopyBuffer(g_atr, 0, s, 1, a) != 1 || a[0] <= 0) return false;
      double ratio = (g_hi - g_lo) / a[0];
      if(InpMinRangeATR > 0 && ratio < InpMinRangeATR) return false;
      if(InpMaxRangeATR > 0 && ratio > InpMaxRangeATR) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Process every breakout-TF candle closed since session open       |
//+------------------------------------------------------------------+
void ScanBreakouts()
{
   int sec = PeriodSeconds(InpBreakTF);
   int first = iBarShift(_Symbol, InpBreakTF, g_sessStart, false);
   for(int sh = first; sh >= 1; sh--)
   {
      datetime bt = iTime(_Symbol, InpBreakTF, sh);
      if(bt < g_sessStart || bt <= g_lastBrkDone) continue;
      g_lastBrkDone = bt;

      if(!g_gapChecked)
      {
         g_gapChecked = true;
         double o = iOpen(_Symbol, InpBreakTF, sh);
         if(InpSkipGapOutside && (o > g_hi || o < g_lo)) { g_dayBlocked = true; return; }
      }
      if(InpBreakoutInWindow && bt + sec > g_winEnd) return;
      if(g_dir != 0 && !InpAllowFlip) return;

      double c = iClose(_Symbol, InpBreakTF, sh);
      int d = 0;
      if(c > g_hi + InpBreakBuffer * g_unit)      d = 1;
      else if(c < g_lo - InpBreakBuffer * g_unit) d = -1;
      if(d == 0 || d == g_dir) continue;
      if((d > 0 && !InpTradeLong) || (d < 0 && !InpTradeShort)) continue;

      g_dir = d;
      g_breakFrom = bt + sec;        // retest must come after the breakout candle closed
      g_trig.active = false;
   }
}

//+------------------------------------------------------------------+
//| Candle-close signals on the signal TF                            |
//+------------------------------------------------------------------+
void OnNewSignalBar()
{
   if(g_p1.time < g_breakFrom) return;

   int need = MathMax(2, InpPriorMoveBars + 1);
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpSignalTF, 1, need, r) < need) return;   // r[0] = last closed bar

   double lvl = (g_dir > 0) ? g_hi : g_lo;
   if(!IsRetest(r[0].low, r[0].high, r[0].close, lvl, InpRequireCloseBeyond)) return;

   //--- hammer / inverted hammer
   if(InpUseHammer && IsHammer(r[0]) && PriorMoveOk(r))
   {
      double sl = CalcSL(r[0].low, r[0].high, lvl);
      if(InpHammerEntry == HAM_AT_CLOSE) { Enter(sl, "hammer"); return; }

      g_trig.active = true;
      g_trig.dir    = g_dir;
      g_trig.price  = (g_dir > 0) ? r[0].high + InpEntryBuffer * g_unit : r[0].low - InpEntryBuffer * g_unit;
      g_trig.sl     = sl;
      g_trig.expiry = r[0].time + (1 + InpHamBreakBars) * PeriodSeconds(InpSignalTF);
      return;
   }

   //--- engulfing evaluated on close
   if(InpUseEngulf && InpEngulfMode != ENG_INTRABAR && IsEngulf(r[0], r[1]))
      Enter(CalcSL(r[0].low, r[0].high, lvl), "engulf");
}

//+------------------------------------------------------------------+
//| Tick-level entries: hammer break trigger, intrabar engulfing     |
//+------------------------------------------------------------------+
void CheckIntrabar(datetime now, datetime barTime)
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return;

   if(g_trig.active)
   {
      if(now >= g_trig.expiry ||
         (g_trig.dir > 0 && tk.bid <= g_trig.sl) || (g_trig.dir < 0 && tk.ask >= g_trig.sl))
         g_trig.active = false;
      else if((g_trig.dir > 0 && tk.ask >= g_trig.price) || (g_trig.dir < 0 && tk.bid <= g_trig.price))
      {
         g_trig.active = false;
         Enter(g_trig.sl, "hammer");
         return;
      }
   }

   if(!InpUseEngulf || InpEngulfMode != ENG_INTRABAR) return;
   if(barTime < g_breakFrom || barTime == g_engDoneBar || g_p1.time == 0) return;
   if(InpEngPrevOpposite && ((g_dir > 0) ? g_p1.close >= g_p1.open : g_p1.close <= g_p1.open)) return;

   double lvl = (g_dir > 0) ? g_hi : g_lo;
   double hi0 = iHigh(_Symbol, InpSignalTF, 0), lo0 = iLow(_Symbol, InpSignalTF, 0);
   if(g_dir > 0)
   {
      double trg = g_p1.high + InpEntryBuffer * g_unit;
      if(lo0 >= g_p1.low || trg <= lvl || tk.ask < trg) return;      // need lower low, then take prev high
   }
   else
   {
      double trg = g_p1.low - InpEntryBuffer * g_unit;
      if(hi0 <= g_p1.high || trg >= lvl || tk.bid > trg) return;
   }
   if(!IsRetest(lo0, hi0, 0, lvl, false)) return;

   g_engDoneBar = barTime;            // one attempt per bar
   Enter(CalcSL(lo0, hi0, lvl), "engulf");
}

//+------------------------------------------------------------------+
//| Pattern helpers (direction taken from g_dir)                     |
//+------------------------------------------------------------------+
bool IsRetest(double lo, double hi, double close, double lvl, bool needClose)
{
   double tol = InpRetestTol * g_unit, pen = InpMaxPenetration * g_unit;
   if(g_dir > 0)
      return lo <= lvl + tol && (pen <= 0 || lo >= lvl - pen) && (!needClose || close > lvl);
   return hi >= lvl - tol && (pen <= 0 || hi <= lvl + pen) && (!needClose || close < lvl);
}

bool IsHammer(const MqlRates &b)
{
   double body  = MathAbs(b.close - b.open);
   double upper = b.high - MathMax(b.open, b.close);
   double lower = MathMin(b.open, b.close) - b.low;
   if(g_dir > 0) return lower > body * InpHamWickBody && upper < body * InpHamOppWickBody;
   return upper > body * InpHamWickBody && lower < body * InpHamOppWickBody;
}

// "A hammer must come after a clear negative movement" (mirror for shorts):
// net move against the breakout over the prior N bars, and the hammer marks the extreme.
bool PriorMoveOk(const MqlRates &r[])
{
   int n = InpPriorMoveBars;
   if(n <= 0) return true;
   if(g_dir > 0)
   {
      if(r[1].close >= r[n].open) return false;
      for(int i = 1; i <= n; i++) if(r[i].low < r[0].low) return false;
   }
   else
   {
      if(r[1].close <= r[n].open) return false;
      for(int i = 1; i <= n; i++) if(r[i].high > r[0].high) return false;
   }
   return true;
}

bool IsEngulf(const MqlRates &b, const MqlRates &p)
{
   bool prevOk = !InpEngPrevOpposite || ((g_dir > 0) ? p.close < p.open : p.close > p.open);
   if(!prevOk) return false;
   if(InpEngulfMode == ENG_PRT_STRICT)
      return (g_dir > 0) ? (b.close > b.open && b.close > p.high && b.open < p.low)
                         : (b.close < b.open && b.close < p.low && b.open > p.high);
   return (g_dir > 0) ? (b.close > b.open && b.high > p.high && b.low < p.low)
                      : (b.close < b.open && b.low < p.low && b.high > p.high);
}

double CalcSL(double cLo, double cHi, double lvl)
{
   double buf = InpSLBuffer * g_unit;
   switch(InpSLMode)
   {
      case SL_CANDLE: return (g_dir > 0) ? cLo - buf : cHi + buf;
      case SL_LEVEL:  return (g_dir > 0) ? lvl - buf : lvl + buf;
      default:        return (g_dir > 0) ? lvl - (cHi - cLo) * InpSLRangeFactor
                                         : lvl + (cHi - cLo) * InpSLRangeFactor;
   }
}

//+------------------------------------------------------------------+
//| Order execution                                                  |
//+------------------------------------------------------------------+
bool Enter(double sl, string tag)
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk)) return false;
   if(InpMaxSpreadPts > 0 && (tk.ask - tk.bid) / _Point > InpMaxSpreadPts) return false;

   double price = (g_dir > 0) ? tk.ask : tk.bid;
   double risk  = (g_dir > 0) ? price - sl : sl - price;
   double minD  = MathMax(InpMinSL * g_unit,
                          (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point);
   if(risk < minD) risk = minD;                                   // widen tiny stops
   if(InpMaxSL > 0 && risk > InpMaxSL * g_unit) return false;

   double lots = CalcLots(risk);
   if(lots <= 0) return false;

   sl = NormalizeDouble((g_dir > 0) ? price - risk : price + risk, _Digits);
   double tp = NormalizeDouble((g_dir > 0) ? price + risk * InpRR : price - risk * InpRR, _Digits);
   string cmt = InpComment + " " + tag;

   bool ok = (g_dir > 0) ? trade.Buy(lots, _Symbol, 0, sl, tp, cmt)
                         : trade.Sell(lots, _Symbol, 0, sl, tp, cmt);
   if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE) { g_tradesToday++; return true; }
   PrintFormat("Entry failed (%s): %u %s", tag, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return false;
}

double CalcLots(double risk)
{
   double vMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = InpLots;

   if(InpLotMode == LOT_RISK_PCT)
   {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0 || ts <= 0) return 0;
      lots = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0 / (risk / ts * tv);
   }
   lots = MathFloor(lots / step) * step;
   if(lots < vMin) return 0;                    // can't trade within risk budget
   return MathMin(lots, vMax);
}

// Returns number of open positions; handles EOD exit, stale positions, breakeven.
int ManagePositions(datetime now)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tkt = PositionGetTicket(i);
      if(tkt == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      if(now >= g_exitTime || (datetime)PositionGetInteger(POSITION_TIME) < g_day)
      {
         if(trade.PositionClose(tkt)) continue;
      }
      count++;

      if(InpBreakevenR <= 0) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      bool   buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double risk = buy ? op - sl : sl - op;
      if(sl == 0 || risk <= 0) continue;                        // already at/after breakeven
      double cur = buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if((buy ? cur - op : op - cur) >= risk * InpBreakevenR)
         trade.PositionModify(tkt, NormalizeDouble(op, _Digits), tp);
   }
   return count;
}

//+------------------------------------------------------------------+
//| Custom optimisation criterion: PF x sqrt(trades), penalising     |
//| small samples (setups are rare: ~2-3 per month per symbol).      |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(trades < InpMinTradesOpt || pf <= 0) return 0;
   return pf * MathSqrt(trades);
}
//+------------------------------------------------------------------+
