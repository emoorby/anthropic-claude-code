//+------------------------------------------------------------------+
//|                                           BreakAndBounce_EA.mq5  |
//|  Break & Bounce: previous-day range -> 15m close breakout ->     |
//|  5m retest of the broken level with a hammer / engulfing candle. |
//|                                                                  |
//|  Multi-symbol: list symbols in InpSymbols (empty = chart symbol) |
//|  to backtest/optimise a whole basket in ONE tester pass.         |
//|  Gap handling, economic-news filter and earnings-day filter.     |
//|                                                                  |
//|  ALL TIMES ARE BROKER SERVER TIME. All basket symbols should     |
//|  share the same exchange session (run one basket per exchange).  |
//+------------------------------------------------------------------+
#property copyright "Break & Bounce EA"
#property version   "2.00"
// Sent to tester agents (must exist in MQL5\Files; create with BB_ExportCalendar.mq5 / by hand)
#property tester_file "BB_news.csv"
#property tester_file "BB_earnings.csv"

#include <Trade\Trade.mqh>
CTrade trade;

#define NEWS_FILE  "BB_news.csv"
#define EARN_FILE  "BB_earnings.csv"
#define STATS_FILE "BB_symbol_stats.csv"

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
enum ENUM_GAP_MODE    {GAP_ALLOW=0,        // Allow (original rules)
                       GAP_SKIP=1,         // Skip day if open is outside range
                       GAP_REBREAK=2};     // Need a close back inside range, then a fresh break
enum ENUM_NEWS_MODE   {NEWS_OFF=0,         // Off
                       NEWS_BLOCK=1,       // No entries around events
                       NEWS_SKIP_DAY=2,    // Skip day if event pre-open .. window end
                       NEWS_BOTH=3};       // Both

//--- inputs
input group "=== General / basket ==="
input string          InpSymbols           = "";            // Symbols, comma separated (empty = chart)
input ulong           InpMagic             = 240611;        // Magic number
input string          InpComment           = "BreakBounce"; // Trade comment
input bool            InpTradeLong         = true;          // Allow long setups
input bool            InpTradeShort        = true;          // Allow short setups
input int             InpMaxTradesPerDay   = 1;             // Max trades per symbol per day
input int             InpMaxTradesDayTotal = 0;             // Max trades per day, whole basket (0=off)
input int             InpMaxOpenTotal      = 0;             // Max open positions, whole basket (0=off)
input int             InpMaxSpreadPts      = 0;             // Max spread in points (0=off)
input bool            InpDrawLevels        = true;          // Draw previous-day box (chart symbol)

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
input int             InpATRPeriod         = 14;            // D1 ATR period (range / gap filters)
input double          InpMinRangeATR       = 0.0;           // Min prev range / ATR (0=off)
input double          InpMaxRangeATR       = 0.0;           // Max prev range / ATR (0=off)

input group "=== Gap opens ==="
input ENUM_GAP_MODE   InpGapMode           = GAP_REBREAK;   // Open outside previous range
input double          InpMaxGapATR         = 0.0;           // Skip day if |open - prev close| > x ATR (0=off)

input group "=== News & earnings ==="
input ENUM_NEWS_MODE  InpNewsMode          = NEWS_OFF;      // Economic news filter
input string          InpNewsCurrencies    = "USD";         // News currencies, comma separated
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Min importance
input int             InpNewsBeforeMins    = 30;            // Block entries x mins before event
input int             InpNewsAfterMins     = 30;            // Block entries x mins after event
input int             InpNewsPreOpenMins   = 120;           // Skip-day: look back x mins before open
input int             InpNewsFlattenMins   = 0;             // Close positions x mins before event (0=off)
input bool            InpUseEarnings       = false;         // Skip earnings-affected days (BB_earnings.csv)

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

//--- shared state
struct Trigger {bool active; int dir; double price; double sl; datetime expiry;};

datetime g_news[];                    // sorted high-impact event times
string   g_eTick[];                   // earnings file rows
datetime g_eDate[];
int      g_eTiming[];                 // 0 unknown, 1 before open, 2 after close
datetime g_day = 0, g_lastPass = 0;
int      g_tradesDay = 0, g_openTotal = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

// "#AAPL", "AAPL.US", "AAPL_CFD" -> "AAPL"  (matches earnings tickers to broker names)
string BaseTicker(string s)
{
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(s, i);
      bool an = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
      if(!an) { if(out != "") break; continue; }
      out += ShortToString(c);
   }
   StringToUpper(out);
   return out;
}

int ReadRow(int h, string &f[])
{
   ArrayResize(f, 0);
   while(!FileIsEnding(h))
   {
      int n = ArraySize(f);
      ArrayResize(f, n + 1);
      f[n] = Trim(FileReadString(h));
      if(FileIsLineEnding(h)) break;
   }
   return ArraySize(f);
}

bool IsDigitStart(string s) { return StringLen(s) > 0 && StringGetCharacter(s, 0) >= '0' && StringGetCharacter(s, 0) <= '9'; }

// true if any news event lies in [from, to] (binary search)
bool NewsIn(datetime from, datetime to)
{
   int n = ArraySize(g_news), a = 0, b = n;
   while(a < b) { int m = (a + b) >> 1; if(g_news[m] < from) a = m + 1; else b = m; }
   return a < n && g_news[a] <= to;
}

bool CurrencyWanted(string c)
{
   string list[];
   int n = StringSplit(InpNewsCurrencies, ',', list);
   for(int i = 0; i < n; i++) if(Trim(list[i]) == c) return true;
   return false;
}

// Tester: read BB_news.csv (time,currency,importance,name)
void LoadNewsFile()
{
   ArrayResize(g_news, 0);
   int h = FileOpen(NEWS_FILE, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("News file not found: ", NEWS_FILE, " - news filter inactive"); return; }
   string f[];
   while(!FileIsEnding(h))
   {
      if(ReadRow(h, f) < 3 || !IsDigitStart(f[0])) continue;
      if((int)StringToInteger(f[2]) < (int)InpNewsImportance || !CurrencyWanted(f[1])) continue;
      int n = ArraySize(g_news);
      ArrayResize(g_news, n + 1, 4096);
      g_news[n] = StringToTime(f[0]);
   }
   FileClose(h);
   ArraySort(g_news);
   PrintFormat("Loaded %d news events", ArraySize(g_news));
}

// Live: pull yesterday..+2 days from the built-in MT5 economic calendar
void RefreshLiveNews(datetime day)
{
   ArrayResize(g_news, 0);
   string list[];
   int nc = StringSplit(InpNewsCurrencies, ',', list);
   for(int c = 0; c < nc; c++)
   {
      MqlCalendarValue v[];
      int k = CalendarValueHistory(v, day - 86400, day + 2 * 86400, NULL, Trim(list[c]));
      for(int j = 0; j < k; j++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(v[j].event_id, ev) || ev.importance < InpNewsImportance) continue;
         int n = ArraySize(g_news);
         ArrayResize(g_news, n + 1, 64);
         g_news[n] = v[j].time;
      }
   }
   ArraySort(g_news);
}

// BB_earnings.csv (ticker,date[,BMO|AMC])
void LoadEarnings()
{
   int h = FileOpen(EARN_FILE, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("Earnings file not found: ", EARN_FILE); return; }
   string f[];
   while(!FileIsEnding(h))
   {
      if(ReadRow(h, f) < 2 || !IsDigitStart(f[1])) continue;
      StringReplace(f[1], "-", ".");
      int n = ArraySize(g_eTick);
      ArrayResize(g_eTick, n + 1, 1024); ArrayResize(g_eDate, n + 1, 1024); ArrayResize(g_eTiming, n + 1, 1024);
      g_eTick[n] = BaseTicker(f[0]);
      g_eDate[n] = StringToTime(f[1]);
      string t = (ArraySize(f) > 2) ? f[2] : "";
      StringToUpper(t);
      g_eTiming[n] = (t == "BMO") ? 1 : (t == "AMC") ? 2 : 0;
   }
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Per-symbol strategy state and logic                              |
//+------------------------------------------------------------------+
class CBB
{
public:
   string   sym;
   int      atr;
   datetime day, prevDay, sessStart, winEnd, exitTime;
   datetime breakFrom, lastBrkBar, lastBrkDone, lastSigBar, engDoneBar;
   double   hi, lo, prevClose, atrVal, unit;
   int      dir, tradesToday, openPos;
   bool     rangeOk, blocked, gapChecked, needReset;
   MqlRates p1;                       // last closed signal bar
   Trigger  trig;
   datetime earnDate[];
   int      earnTiming[];

            CBB() : atr(INVALID_HANDLE), day(0), openPos(0) { ZeroMemory(p1); trig.active = false; }

   bool Init(string s)
   {
      sym = s;
      if(InpMinRangeATR > 0 || InpMaxRangeATR > 0 || InpMaxGapATR > 0)
      {
         atr = iATR(sym, PERIOD_D1, InpATRPeriod);
         if(atr == INVALID_HANDLE) return false;
      }
      string base = BaseTicker(sym);
      for(int k = 0; k < ArraySize(g_eTick); k++)
         if(g_eTick[k] == base)
         {
            int n = ArraySize(earnDate);
            ArrayResize(earnDate, n + 1); ArrayResize(earnTiming, n + 1);
            earnDate[n] = g_eDate[k]; earnTiming[n] = g_eTiming[k];
         }
      return true;
   }

   void Release() { if(atr != INVALID_HANDLE) IndicatorRelease(atr); }

   void CheckDay(datetime now) { datetime d = now - now % 86400; if(d != day) NewDay(d); }

   //--- main per-tick work (cheap early exits)
   void Tick(datetime now)
   {
      if(!rangeOk || blocked || now < sessStart) return;

      datetime tb = iTime(sym, InpBreakTF, 0);
      if(tb != lastBrkBar) { lastBrkBar = tb; ScanBreakouts(); if(blocked) return; }

      datetime ts = iTime(sym, InpSignalTF, 0);
      bool newSig = (ts != lastSigBar);
      if(newSig)
      {
         MqlRates r[1];
         if(CopyRates(sym, InpSignalTF, 1, 1, r) == 1) { p1 = r[0]; lastSigBar = ts; }
         else newSig = false;
      }

      if(dir == 0) return;
      if(now >= winEnd || tradesToday >= InpMaxTradesPerDay || openPos > 0) { trig.active = false; return; }

      if(newSig) OnNewSignalBar();
      CheckIntrabar(now, ts);
   }

private:
   void NewDay(datetime d)
   {
      day = d;
      dir = 0; tradesToday = 0;
      trig.active = false;
      blocked = false; gapChecked = false; needReset = false;
      breakFrom = 0; lastBrkBar = 0; lastBrkDone = 0; engDoneBar = 0;
      sessStart = d + InpOpenHour * 3600 + InpOpenMin * 60;
      winEnd    = sessStart + InpEntryWindowMins * 60;
      exitTime  = d + InpExitHour * 3600 + InpExitMin * 60;
      rangeOk   = CalcRange(d);
      if(!rangeOk) return;

      unit = (InpUnits == UNITS_POINTS) ? SymbolInfoDouble(sym, SYMBOL_POINT) : (hi - lo) / 100.0;

      if((InpNewsMode == NEWS_SKIP_DAY || InpNewsMode == NEWS_BOTH) &&
         NewsIn(sessStart - InpNewsPreOpenMins * 60, winEnd)) blocked = true;
      if(InpUseEarnings && EarningsDay()) blocked = true;

      if(InpDrawLevels && sym == _Symbol && !MQLInfoInteger(MQL_OPTIMIZATION))
      {
         string name = "BB_" + TimeToString(d, TIME_DATE);
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, d, hi, exitTime, lo);
         ObjectSetInteger(0, name, OBJPROP_COLOR, blocked ? clrIndianRed : clrSteelBlue);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
      }
   }

   // Results land on/after the open of today (BMO today, AMC on the previous session)
   bool EarningsDay()
   {
      for(int i = ArraySize(earnDate) - 1; i >= 0; i--)
      {
         if(earnDate[i] == day && earnTiming[i] != 2) return true;
         if(earnDate[i] == prevDay && earnTiming[i] != 1) return true;
      }
      return false;
   }

   bool CalcRange(datetime d)
   {
      int s = iBarShift(sym, PERIOD_D1, d - 1, false);   // last D1 bar before today
      if(s < 0) return false;
      MqlDateTime dt;
      TimeToStruct(iTime(sym, PERIOD_D1, s), dt);
      if(InpSkipSundayBar && dt.day_of_week == 0) s++;
      prevDay = iTime(sym, PERIOD_D1, s);
      if(prevDay == 0) return false;

      if(InpRangeSource == RANGE_D1)
      {
         hi = iHigh(sym, PERIOD_D1, s);
         lo = iLow(sym, PERIOD_D1, s);
         prevClose = iClose(sym, PERIOD_D1, s);
      }
      else
      {
         datetime from = prevDay + InpRangeStartHour * 3600 + InpRangeStartMin * 60;
         datetime to   = prevDay + InpRangeEndHour * 3600 + InpRangeEndMin * 60 - 1;
         MqlRates r[];
         int n = CopyRates(sym, PERIOD_M5, from, to, r);
         if(n <= 0) return false;
         hi = r[0].high; lo = r[0].low;
         for(int i = 1; i < n; i++) { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); }
         prevClose = r[n - 1].close;
      }
      if(hi <= lo) return false;

      atrVal = 0;
      if(atr != INVALID_HANDLE)
      {
         double a[1];
         if(CopyBuffer(atr, 0, s, 1, a) != 1 || a[0] <= 0) return false;
         atrVal = a[0];
         double ratio = (hi - lo) / atrVal;
         if(InpMinRangeATR > 0 && ratio < InpMinRangeATR) return false;
         if(InpMaxRangeATR > 0 && ratio > InpMaxRangeATR) return false;
      }
      return true;
   }

   // false = skip the day
   bool CheckGap(double open)
   {
      if(InpMaxGapATR > 0 && atrVal > 0 && MathAbs(open - prevClose) > InpMaxGapATR * atrVal) return false;
      if(open <= hi && open >= lo) return true;
      if(InpGapMode == GAP_SKIP) return false;
      needReset = (InpGapMode == GAP_REBREAK);
      return true;
   }

   //--- Step 2: every breakout-TF candle closed since the open
   void ScanBreakouts()
   {
      int sec = PeriodSeconds(InpBreakTF);
      int first = iBarShift(sym, InpBreakTF, sessStart, false);
      for(int sh = first; sh >= 1; sh--)
      {
         datetime bt = iTime(sym, InpBreakTF, sh);
         if(bt < sessStart || bt <= lastBrkDone) continue;
         lastBrkDone = bt;

         if(!gapChecked)
         {
            gapChecked = true;
            if(!CheckGap(iOpen(sym, InpBreakTF, sh))) { blocked = true; return; }
         }
         if(InpBreakoutInWindow && bt + sec > winEnd) return;
         if(dir != 0 && !InpAllowFlip) return;

         double c = iClose(sym, InpBreakTF, sh);
         if(needReset) { if(c <= hi && c >= lo) needReset = false; continue; }   // gap: back inside first

         int d = 0;
         if(c > hi + InpBreakBuffer * unit)      d = 1;
         else if(c < lo - InpBreakBuffer * unit) d = -1;
         if(d == 0 || d == dir) continue;
         if((d > 0 && !InpTradeLong) || (d < 0 && !InpTradeShort)) continue;

         dir = d;
         breakFrom = bt + sec;         // retest must come after the breakout candle closed
         trig.active = false;
      }
   }

   //--- Step 3: candle-close signals
   void OnNewSignalBar()
   {
      if(p1.time < breakFrom) return;

      int need = MathMax(2, InpPriorMoveBars + 1);
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(sym, InpSignalTF, 1, need, r) < need) return;   // r[0] = last closed bar

      double lvl = (dir > 0) ? hi : lo;
      if(!IsRetest(r[0].low, r[0].high, r[0].close, lvl, InpRequireCloseBeyond)) return;

      if(InpUseHammer && IsHammer(r[0]) && PriorMoveOk(r))
      {
         double sl = CalcSL(r[0].low, r[0].high, lvl);
         if(InpHammerEntry == HAM_AT_CLOSE) { Enter(sl, "hammer"); return; }

         trig.active = true;
         trig.dir    = dir;
         trig.price  = (dir > 0) ? r[0].high + InpEntryBuffer * unit : r[0].low - InpEntryBuffer * unit;
         trig.sl     = sl;
         trig.expiry = r[0].time + (1 + InpHamBreakBars) * PeriodSeconds(InpSignalTF);
         return;
      }

      if(InpUseEngulf && InpEngulfMode != ENG_INTRABAR && IsEngulf(r[0], r[1]))
         Enter(CalcSL(r[0].low, r[0].high, lvl), "engulf");
   }

   //--- tick-level entries: hammer break trigger, intrabar engulfing
   void CheckIntrabar(datetime now, datetime barTime)
   {
      MqlTick tk;
      if(!SymbolInfoTick(sym, tk)) return;

      if(trig.active)
      {
         if(now >= trig.expiry ||
            (trig.dir > 0 && tk.bid <= trig.sl) || (trig.dir < 0 && tk.ask >= trig.sl))
            trig.active = false;
         else if((trig.dir > 0 && tk.ask >= trig.price) || (trig.dir < 0 && tk.bid <= trig.price))
         {
            trig.active = false;
            Enter(trig.sl, "hammer");
            return;
         }
      }

      if(!InpUseEngulf || InpEngulfMode != ENG_INTRABAR) return;
      if(barTime < breakFrom || barTime == engDoneBar || p1.time == 0) return;
      if(InpEngPrevOpposite && ((dir > 0) ? p1.close >= p1.open : p1.close <= p1.open)) return;

      double lvl = (dir > 0) ? hi : lo;
      double hi0 = iHigh(sym, InpSignalTF, 0), lo0 = iLow(sym, InpSignalTF, 0);
      if(dir > 0)
      {
         double trg = p1.high + InpEntryBuffer * unit;
         if(lo0 >= p1.low || trg <= lvl || tk.ask < trg) return;       // need lower low, then take prev high
      }
      else
      {
         double trg = p1.low - InpEntryBuffer * unit;
         if(hi0 <= p1.high || trg >= lvl || tk.bid > trg) return;
      }
      if(!IsRetest(lo0, hi0, 0, lvl, false)) return;

      engDoneBar = barTime;            // one attempt per bar
      Enter(CalcSL(lo0, hi0, lvl), "engulf");
   }

   bool IsRetest(double l, double h, double close, double lvl, bool needClose)
   {
      double tol = InpRetestTol * unit, pen = InpMaxPenetration * unit;
      if(dir > 0)
         return l <= lvl + tol && (pen <= 0 || l >= lvl - pen) && (!needClose || close > lvl);
      return h >= lvl - tol && (pen <= 0 || h <= lvl + pen) && (!needClose || close < lvl);
   }

   bool IsHammer(const MqlRates &b)
   {
      double body  = MathAbs(b.close - b.open);
      double upper = b.high - MathMax(b.open, b.close);
      double lower = MathMin(b.open, b.close) - b.low;
      if(dir > 0) return lower > body * InpHamWickBody && upper < body * InpHamOppWickBody;
      return upper > body * InpHamWickBody && lower < body * InpHamOppWickBody;
   }

   // "A hammer must come after a clear negative movement" (mirror for shorts)
   bool PriorMoveOk(const MqlRates &r[])
   {
      int n = InpPriorMoveBars;
      if(n <= 0) return true;
      if(dir > 0)
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
      if(InpEngPrevOpposite && !((dir > 0) ? p.close < p.open : p.close > p.open)) return false;
      if(InpEngulfMode == ENG_PRT_STRICT)
         return (dir > 0) ? (b.close > b.open && b.close > p.high && b.open < p.low)
                          : (b.close < b.open && b.close < p.low && b.open > p.high);
      return (dir > 0) ? (b.close > b.open && b.high > p.high && b.low < p.low)
                       : (b.close < b.open && b.low < p.low && b.high > p.high);
   }

   double CalcSL(double cLo, double cHi, double lvl)
   {
      double buf = InpSLBuffer * unit;
      switch(InpSLMode)
      {
         case SL_CANDLE: return (dir > 0) ? cLo - buf : cHi + buf;
         case SL_LEVEL:  return (dir > 0) ? lvl - buf : lvl + buf;
         default:        return (dir > 0) ? lvl - (cHi - cLo) * InpSLRangeFactor
                                          : lvl + (cHi - cLo) * InpSLRangeFactor;
      }
   }

   bool Enter(double sl, string tag)
   {
      datetime now = TimeCurrent();
      if(InpMaxTradesDayTotal > 0 && g_tradesDay >= InpMaxTradesDayTotal) return false;
      if(InpMaxOpenTotal > 0 && g_openTotal >= InpMaxOpenTotal) return false;
      if((InpNewsMode == NEWS_BLOCK || InpNewsMode == NEWS_BOTH) &&
         NewsIn(now - InpNewsAfterMins * 60, now + InpNewsBeforeMins * 60)) return false;

      MqlTick tk;
      if(!SymbolInfoTick(sym, tk)) return false;
      double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(InpMaxSpreadPts > 0 && (tk.ask - tk.bid) / pt > InpMaxSpreadPts) return false;

      double price = (dir > 0) ? tk.ask : tk.bid;
      double risk  = (dir > 0) ? price - sl : sl - price;
      double minD  = MathMax(InpMinSL * unit, (SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) + 1) * pt);
      if(risk < minD) risk = minD;                                  // widen tiny stops
      if(InpMaxSL > 0 && risk > InpMaxSL * unit) return false;

      double lots = CalcLots(risk);
      if(lots <= 0) return false;

      sl = NormalizeDouble((dir > 0) ? price - risk : price + risk, dg);
      double tp = NormalizeDouble((dir > 0) ? price + risk * InpRR : price - risk * InpRR, dg);
      string cmt = InpComment + " " + tag;

      trade.SetTypeFillingBySymbol(sym);
      bool ok = (dir > 0) ? trade.Buy(lots, sym, 0, sl, tp, cmt) : trade.Sell(lots, sym, 0, sl, tp, cmt);
      if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         tradesToday++; g_tradesDay++; g_openTotal++; openPos++;
         return true;
      }
      PrintFormat("%s entry failed (%s): %u %s", sym, tag, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   double CalcLots(double risk)
   {
      double vMin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double vMax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double lots = InpLots;

      if(InpLotMode == LOT_RISK_PCT)
      {
         double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
         double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         if(tv <= 0 || ts <= 0) return 0;
         lots = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0 / (risk / ts * tv);
      }
      lots = MathFloor(lots / step) * step;
      if(lots < vMin) return 0;                    // can't trade within risk budget
      return MathMin(lots, vMax);
   }
};

CBB g_s[];

int FindSym(string s)
{
   for(int i = ArraySize(g_s) - 1; i >= 0; i--) if(g_s[i].sym == s) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| One pass over all open positions: EOD / stale / pre-news exits,  |
//| breakeven, and per-symbol + basket position counts.              |
//+------------------------------------------------------------------+
void ManageAll(datetime now)
{
   for(int i = ArraySize(g_s) - 1; i >= 0; i--) g_s[i].openPos = 0;
   g_openTotal = 0;
   bool newsSoon = InpNewsFlattenMins > 0 && NewsIn(now, now + InpNewsFlattenMins * 60);

   for(int k = PositionsTotal() - 1; k >= 0; k--)
   {
      ulong tkt = PositionGetTicket(k);
      if(tkt == 0 || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int i = FindSym(sym);
      if(i < 0) continue;

      if(newsSoon || now >= g_s[i].exitTime || (datetime)PositionGetInteger(POSITION_TIME) < g_s[i].day)
      {
         if(trade.PositionClose(tkt)) continue;
      }
      g_s[i].openPos++; g_openTotal++;

      if(InpBreakevenR <= 0) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      bool   buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double risk = buy ? op - sl : sl - op;
      if(sl == 0 || risk <= 0) continue;                         // already at/after breakeven
      double cur = buy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      if((buy ? cur - op : op - cur) >= risk * InpBreakevenR)
         trade.PositionModify(tkt, NormalizeDouble(op, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)), tp);
   }
}

// Throttled to once per server second - plenty for 5m logic, cheap for large baskets.
void Pass()
{
   datetime now = TimeCurrent();
   if(now == g_lastPass) return;
   g_lastPass = now;

   datetime day = now - now % 86400;
   if(day != g_day)
   {
      g_day = day; g_tradesDay = 0;
      if(InpNewsMode != NEWS_OFF || InpNewsFlattenMins > 0)
         if(!MQLInfoInteger(MQL_TESTER)) RefreshLiveNews(day);
   }
   int n = ArraySize(g_s);
   for(int i = 0; i < n; i++) g_s[i].CheckDay(now);
   ManageAll(now);
   for(int i = 0; i < n; i++) g_s[i].Tick(now);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(PeriodSeconds(InpSignalTF) >= PeriodSeconds(InpBreakTF))
   {
      Print("Signal timeframe must be lower than breakout timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(MQLInfoInteger(MQL_TESTER) && (InpNewsMode != NEWS_OFF || InpNewsFlattenMins > 0)) LoadNewsFile();
   if(InpUseEarnings) LoadEarnings();

   string list[];
   int n = (Trim(InpSymbols) == "") ? 0 : StringSplit(InpSymbols, ',', list);
   if(n == 0) { ArrayResize(list, 1); list[0] = _Symbol; n = 1; }

   for(int i = 0; i < n; i++)
   {
      string s = Trim(list[i]);
      if(s == "" || FindSym(s) >= 0) continue;
      if(!SymbolSelect(s, true)) { Print("Symbol not available: ", s); continue; }
      int k = ArraySize(g_s);
      ArrayResize(g_s, k + 1);
      if(!g_s[k].Init(s)) return INIT_FAILED;
   }
   if(ArraySize(g_s) == 0) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   if(ArraySize(g_s) > 1) EventSetTimer(1);   // other symbols may tick when the chart symbol doesn't
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   WriteSymbolStats();
   for(int i = ArraySize(g_s) - 1; i >= 0; i--) g_s[i].Release();
   ObjectsDeleteAll(0, "BB_");
}

void OnTick()  { Pass(); }
void OnTimer() { Pass(); }

//+------------------------------------------------------------------+
//| Per-symbol results -> journal + BB_symbol_stats.csv, to see      |
//| which basket members carry the edge.                             |
//+------------------------------------------------------------------+
void WriteSymbolStats()
{
   if(MQLInfoInteger(MQL_OPTIMIZATION) || !HistorySelect(0, TimeCurrent())) return;
   int n = ArraySize(g_s);
   int    tr[], wn[];
   double gp[], gl[];
   ArrayResize(tr, n); ArrayResize(wn, n); ArrayResize(gp, n); ArrayResize(gl, n);
   ArrayInitialize(tr, 0); ArrayInitialize(wn, 0); ArrayInitialize(gp, 0); ArrayInitialize(gl, 0);

   for(int k = HistoryDealsTotal() - 1; k >= 0; k--)
   {
      ulong d = HistoryDealGetTicket(k);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic) continue;
      int i = FindSym(HistoryDealGetString(d, DEAL_SYMBOL));
      if(i < 0) continue;
      double pl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                  HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) { tr[i]++; if(pl > 0) wn[i]++; }
      if(pl > 0) gp[i] += pl; else gl[i] -= pl;
   }

   int h = FileOpen(STATS_FILE, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h != INVALID_HANDLE) FileWrite(h, "symbol", "trades", "winrate", "net", "pf");
   for(int i = 0; i < n; i++)
   {
      double wr = tr[i] > 0 ? 100.0 * wn[i] / tr[i] : 0;
      double pf = gl[i] > 0 ? gp[i] / gl[i] : 0;
      PrintFormat("%-12s trades %4d  win %5.1f%%  net %10.2f  PF %5.2f", g_s[i].sym, tr[i], wr, gp[i] - gl[i], pf);
      if(h != INVALID_HANDLE) FileWrite(h, g_s[i].sym, tr[i], DoubleToString(wr, 1), DoubleToString(gp[i] - gl[i], 2), DoubleToString(pf, 2));
   }
   if(h != INVALID_HANDLE) FileClose(h);
}

//+------------------------------------------------------------------+
//| Custom optimisation criterion: PF x sqrt(trades)                 |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(trades < InpMinTradesOpt || pf <= 0) return 0;
   return pf * MathSqrt(trades);
}
//+------------------------------------------------------------------+
