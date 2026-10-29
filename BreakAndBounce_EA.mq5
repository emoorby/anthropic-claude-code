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
#property version   "2.30"
// Sent to tester agents (must exist in MQL5\Files; create with BB_ExportCalendar.mq5 / by hand)
#property tester_file "BB_news.csv"
#property tester_file "BB_earnings.csv"
#property tester_file "BB_symbols.txt"

#include <Trade\Trade.mqh>
CTrade trade;

#define NEWS_FILE  "BB_news.csv"
#define EARN_FILE  "BB_earnings.csv"
#define STATS_FILE "BB_symbol_stats.csv"   // single test  -> Terminal\Common\Files
#define DIAG_FILE  "BB_optim_diag.csv"     // optimisation -> Terminal\Common\Files

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
enum ENUM_RISK_BASE   {RISK_EQUITY=0,      // Current equity (compounds)
                       RISK_START_BALANCE=1}; // Starting balance (same $ risk every trade)
enum ENUM_LOT_MODE    {LOT_FIXED=0,        // Fixed lots
                       LOT_RISK_PCT=1};    // % of equity at risk
enum ENUM_GAP_MODE    {GAP_ALLOW=0,        // Allow (original rules)
                       GAP_SKIP=1,         // Skip day if open is outside range
                       GAP_REBREAK=2};     // Need a close back inside range, then a fresh break
enum ENUM_TREND_MODE  {TREND_OFF=0,        // Off
                       TREND_MA=1,         // Symbol's daily close vs its moving average
                       TREND_INDEX=2,      // Index vs its previous close at the breakout
                       TREND_BOTH=3};      // Both must agree
enum ENUM_NEWS_MODE   {NEWS_OFF=0,         // Off
                       NEWS_BLOCK=1,       // No entries around events
                       NEWS_SKIP_DAY=2,    // Skip day if event pre-open .. window end
                       NEWS_BOTH=3};       // Both

//--- inputs
input group "=== General / basket ==="
input string          InpSymbols           = "";            // Symbols, comma separated (empty = chart)
input bool            InpSymbolsFromFile   = false;         // Read symbols from BB_symbols.txt instead
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
input int             InpMaxRangeAgeDays   = 5;             // Skip day if prev bar is older than x days (data gap)
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

input group "=== Trend filter (breakouts only with the trend) ==="
input ENUM_TREND_MODE InpTrendMode         = TREND_OFF;     // Trend filter
input int             InpTrendMAPeriod     = 20;            // Daily MA period
input string          InpTrendIndex        = "US500";       // Index symbol for TREND_INDEX

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
input double          InpPartialR          = 0.0;           // Close part of the trade at x R, SL to entry (0=off)
input double          InpPartialPct        = 50;            // Partial: % of position closed
input int             InpMaxHoldMins       = 0;             // Close trade after x minutes (0=off)
input ENUM_LOT_MODE   InpLotMode           = LOT_RISK_PCT;  // Lot sizing
input double          InpLots              = 0.1;           // Fixed lots
input double          InpRiskPct           = 0.5;           // Risk % per trade
input ENUM_RISK_BASE  InpRiskBase          = RISK_EQUITY;   // Risk % of (use starting balance for tests)

input group "=== Optimisation ==="
input int             InpMinTradesOpt      = 30;            // OnTester: min trades for a score

//--- shared state
struct Trigger {bool active; int dir; double price; double sl; datetime expiry;};

// Diagnostic counters: why a symbol did or didn't trade
enum ENUM_DIAG {D_DAYS, D_NODATA, D_STALE, D_RANGEFILT, D_GAP, D_NEWS, D_EARN, D_BREAKOUT,
                D_SETUP, D_ENTRY, D_F_SPREAD, D_F_NEWS, D_F_LOTS, D_F_MAXSL, D_F_CAPS, D_F_TRADE, D_TREND};
#define D_COUNT 17
string DG_NAMES[] = {"days", "no_data", "stale_range", "range_filter", "gap_skip", "news_skip",
                            "earnings_skip", "breakouts", "setups", "entries", "f_spread", "f_news",
                            "f_lots", "f_max_sl", "f_caps", "f_trade", "trend_skip"};
// Results per pattern & direction (bucket = engulf*2 + short)
string BK_NAMES[] = {"hammer_long", "hammer_short", "engulf_long", "engulf_short"};
// Packed stats layout (FrameAdd payload / CSV row)
#define PK_TRADES 0
#define PK_WINS   1
#define PK_NET    2
#define PK_GP     3
#define PK_GL     4
#define PK_DIAG   5
#define PK_RET    (PK_DIAG + D_COUNT)
#define PK_MODE   (PK_RET + 1)
#define PK_SUMR   (PK_MODE + 1)               // sum of R-multiples
#define PK_BK     (PK_SUMR + 1)               // 4 buckets x {trades, wins, gp, gl, sumR}
#define PK_BKW    5
#define PK_SIZE   (PK_BK + 4 * PK_BKW)

datetime g_news[];                    // sorted high-impact event times
string   g_eTick[];                   // earnings file rows
datetime g_eDate[];
int      g_eTiming[];                 // 0 unknown, 1 before open, 2 after close
datetime g_day = 0, g_lastPass = 0;
double   g_startBalance = 0;
long     g_rPid[];                    // position id -> money at risk at entry (for R-multiples)
double   g_rRisk[];
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

string TradeModeName(long m)
{
   switch((int)m)
   {
      case SYMBOL_TRADE_MODE_DISABLED:  return "disabled";
      case SYMBOL_TRADE_MODE_LONGONLY:  return "long_only";
      case SYMBOL_TRADE_MODE_SHORTONLY: return "short_only";
      case SYMBOL_TRADE_MODE_CLOSEONLY: return "close_only";
      case SYMBOL_TRADE_MODE_FULL:      return "full";
   }
   return "unknown";
}

// Position ids are opening-order tickets, so they arrive in ascending order
void RecordRisk(long pid, double money)
{
   int n = ArraySize(g_rPid);
   ArrayResize(g_rPid, n + 1, 1024); ArrayResize(g_rRisk, n + 1, 1024);
   g_rPid[n] = pid; g_rRisk[n] = money;
}

double RiskOf(long pid)
{
   int a = 0, b = ArraySize(g_rPid);
   while(a < b) { int m = (a + b) >> 1; if(g_rPid[m] < pid) a = m + 1; else b = m; }
   return (a < ArraySize(g_rPid) && g_rPid[a] == pid) ? g_rRisk[a] : 0;
}

// Input files: the agent's own MQL5\Files (filled via #property tester_file), else
// Terminal\Common\Files - local tester agents can always read the Common folder.
int OpenInputFile(string name, int flags)
{
   int h = FileOpen(name, flags, ',');
   if(h == INVALID_HANDLE) h = FileOpen(name, flags | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
      PrintFormat("%s not found in %s\\MQL5\\Files nor in Common\\Files", name, TerminalInfoString(TERMINAL_DATA_PATH));
   return h;
}

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
   int h = OpenInputFile(NEWS_FILE, FILE_READ | FILE_CSV | FILE_ANSI);
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
   int h = OpenInputFile(EARN_FILE, FILE_READ | FILE_CSV | FILE_ANSI);
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

// +1 if the index is above its previous daily close at time t, -1 below, 0 unknown
int IndexBias(datetime t)
{
   int sh = iBarShift(InpTrendIndex, PERIOD_M1, t, false);
   if(sh < 0) return 0;
   double px = iClose(InpTrendIndex, PERIOD_M1, sh);
   datetime d = t - t % 86400;
   int s = iBarShift(InpTrendIndex, PERIOD_D1, d - 1, false);
   if(s < 0) return 0;
   MqlDateTime dt;
   TimeToStruct(iTime(InpTrendIndex, PERIOD_D1, s), dt);
   if(InpSkipSundayBar && dt.day_of_week == 0) s++;
   double pc = iClose(InpTrendIndex, PERIOD_D1, s);
   return (px > pc) ? 1 : (px < pc) ? -1 : 0;
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
   bool     rangeOk, rangePending, weekday, blocked, gapChecked, needReset, trendSkipped;
   int      trendMA;                  // +1 / -1 / 0 from the daily MA
   datetime lastRangeTry;
   MqlRates p1;                       // last closed signal bar
   Trigger  trig;
   datetime earnDate[];
   int      earnTiming[];
   int      dg[D_COUNT];              // diagnostics
   uint     lastRet;                  // last rejected trade retcode
   long     tradeMode;

            CBB() : atr(INVALID_HANDLE), day(0), openPos(0), lastRet(0), rangeOk(false), rangePending(false), weekday(false)
            { ZeroMemory(p1); trig.active = false; ArrayInitialize(dg, 0); }

   bool Init(string s)
   {
      sym = s;
      datetime t0 = TimeCurrent();
      day = t0 - t0 % 86400 - 86400;   // so missing days from the test start are counted too
      tradeMode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
      if(tradeMode != SYMBOL_TRADE_MODE_FULL)
         PrintFormat("%s: trade mode is not FULL (%s) - entries may be rejected", sym, TradeModeName(tradeMode));
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

   // Weekdays with no ticks at all never reach NewDay (common with patchy stock CFD
   // history), so count the skipped ones here as no-data days.
   void CheckDay(datetime now)
   {
      datetime d = now - now % 86400;
      if(d == day) return;
      for(datetime x = day + 86400; day > 0 && x < d; x += 86400)
      {
         MqlDateTime t;
         TimeToStruct(x, t);
         if(t.day_of_week >= 1 && t.day_of_week <= 5) { dg[D_DAYS]++; dg[D_NODATA]++; }
      }
      NewDay(d);
   }

   //--- main per-tick work (cheap early exits)
   void Tick(datetime now)
   {
      if(rangePending) TryRange(now);
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
      if(rangePending && weekday) dg[D_NODATA]++;   // previous day never got its range
      day = d;
      dir = 0; tradesToday = 0;
      trig.active = false;
      blocked = false; gapChecked = false; needReset = false; trendSkipped = false;
      breakFrom = 0; lastBrkBar = 0; lastBrkDone = 0; engDoneBar = 0;
      sessStart = d + InpOpenHour * 3600 + InpOpenMin * 60;
      winEnd    = sessStart + InpEntryWindowMins * 60;
      exitTime  = d + InpExitHour * 3600 + InpExitMin * 60;
      MqlDateTime t;
      TimeToStruct(d, t);
      weekday = (t.day_of_week >= 1 && t.day_of_week <= 5);
      if(weekday) dg[D_DAYS]++;
      rangeOk = false; rangePending = true; lastRangeTry = 0;
      TryRange(TimeCurrent());
   }

   // Builds the day's box. If history isn't loaded yet it retries (once a minute)
   // until the entry window closes instead of silently losing the whole day.
   void TryRange(datetime now)
   {
      if(now - lastRangeTry < 60) return;
      lastRangeTry = now;

      int rc = CalcRange(day);
      if(rc < 0)
      {
         if(now < winEnd) return;
         rangePending = false;
         if(weekday) dg[D_NODATA]++;
         return;
      }
      rangePending = false;
      if(rc == 0) return;
      rangeOk = true;

      unit = (InpUnits == UNITS_POINTS) ? SymbolInfoDouble(sym, SYMBOL_POINT) : (hi - lo) / 100.0;

      if((InpNewsMode == NEWS_SKIP_DAY || InpNewsMode == NEWS_BOTH) &&
         NewsIn(sessStart - InpNewsPreOpenMins * 60, winEnd)) { blocked = true; if(weekday) dg[D_NEWS]++; }
      if(!blocked && InpUseEarnings && EarningsDay())           { blocked = true; if(weekday) dg[D_EARN]++; }

      if(InpDrawLevels && sym == _Symbol && !MQLInfoInteger(MQL_OPTIMIZATION))
      {
         string name = "BB_" + TimeToString(day, TIME_DATE);
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, day, hi, exitTime, lo);
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

   // 1 = ok, 0 = day filtered out, -1 = history not available (yet)
   int CalcRange(datetime d)
   {
      int s = iBarShift(sym, PERIOD_D1, d - 1, false);   // last D1 bar before today
      if(s < 0) return -1;
      MqlDateTime dt;
      TimeToStruct(iTime(sym, PERIOD_D1, s), dt);
      if(InpSkipSundayBar && dt.day_of_week == 0) s++;
      prevDay = iTime(sym, PERIOD_D1, s);
      if(prevDay == 0) return -1;
      // A "previous day" weeks old means a hole in the history - its levels are meaningless
      if(InpMaxRangeAgeDays > 0 && prevDay < d - InpMaxRangeAgeDays * 86400)
      {
         if(weekday) dg[D_STALE]++;
         return 0;
      }

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
         if(n <= 0) return -1;
         hi = r[0].high; lo = r[0].low;
         for(int i = 1; i < n; i++) { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); }
         prevClose = r[n - 1].close;
      }
      if(hi <= lo) return -1;

      atrVal = 0;
      if(atr != INVALID_HANDLE)
      {
         double a[1];
         if(CopyBuffer(atr, 0, s, 1, a) != 1 || a[0] <= 0) return -1;
         atrVal = a[0];
         double ratio = (hi - lo) / atrVal;
         if((InpMinRangeATR > 0 && ratio < InpMinRangeATR) || (InpMaxRangeATR > 0 && ratio > InpMaxRangeATR))
         {
            if(weekday) dg[D_RANGEFILT]++;
            return 0;
         }
      }
      trendMA = 0;
      if(InpTrendMode == TREND_MA || InpTrendMode == TREND_BOTH)
      {
         double c[];
         if(CopyClose(sym, PERIOD_D1, s, InpTrendMAPeriod, c) != InpTrendMAPeriod) return -1;
         double ma = 0;
         for(int i = 0; i < InpTrendMAPeriod; i++) ma += c[i];
         ma /= InpTrendMAPeriod;
         double last = c[InpTrendMAPeriod - 1];               // close of the range day
         trendMA = (last > ma) ? 1 : (last < ma) ? -1 : 0;
      }
      return 1;
   }

   bool TrendOk(int d, datetime t)
   {
      if((InpTrendMode == TREND_MA || InpTrendMode == TREND_BOTH) && trendMA != d) return false;
      if((InpTrendMode == TREND_INDEX || InpTrendMode == TREND_BOTH) && IndexBias(t) != d) return false;
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
            if(!CheckGap(iOpen(sym, InpBreakTF, sh))) { blocked = true; dg[D_GAP]++; return; }
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
         if(InpTrendMode != TREND_OFF && !TrendOk(d, bt + sec - 1))
         {
            if(!trendSkipped) { trendSkipped = true; dg[D_TREND]++; }
            continue;
         }

         dir = d;
         dg[D_BREAKOUT]++;
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
      dg[D_SETUP]++;
      if((InpMaxTradesDayTotal > 0 && g_tradesDay >= InpMaxTradesDayTotal) ||
         (InpMaxOpenTotal > 0 && g_openTotal >= InpMaxOpenTotal)) { dg[D_F_CAPS]++; return false; }
      if((InpNewsMode == NEWS_BLOCK || InpNewsMode == NEWS_BOTH) &&
         NewsIn(now - InpNewsAfterMins * 60, now + InpNewsBeforeMins * 60)) { dg[D_F_NEWS]++; return false; }

      MqlTick tk;
      if(!SymbolInfoTick(sym, tk)) { dg[D_F_SPREAD]++; return false; }
      double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(InpMaxSpreadPts > 0 && (tk.ask - tk.bid) / pt > InpMaxSpreadPts) { dg[D_F_SPREAD]++; return false; }

      double price = (dir > 0) ? tk.ask : tk.bid;
      double risk  = (dir > 0) ? price - sl : sl - price;
      // SL is checked against the opposite price, so the broker minimum must include the spread
      double minD  = MathMax(InpMinSL * unit,
                             (SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) + 1) * pt + (tk.ask - tk.bid));
      if(risk < minD) risk = minD;                                  // widen tiny stops
      if(InpMaxSL > 0 && risk > InpMaxSL * unit) { dg[D_F_MAXSL]++; return false; }

      double lots = CalcLots(risk);
      if(lots <= 0) { dg[D_F_LOTS]++; return false; }

      sl = NormalizeDouble((dir > 0) ? price - risk : price + risk, digits);
      double tp = NormalizeDouble((dir > 0) ? price + risk * InpRR : price - risk * InpRR, digits);
      string cmt = InpComment + " " + tag;

      trade.SetTypeFillingBySymbol(sym);
      bool ok = (dir > 0) ? trade.Buy(lots, sym, 0, sl, tp, cmt) : trade.Sell(lots, sym, 0, sl, tp, cmt);
      if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         tradesToday++; g_tradesDay++; g_openTotal++; openPos++;
         double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS), ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
         if(ts > 0) RecordRisk((long)trade.ResultOrder(), risk / ts * tv * lots);
         dg[D_ENTRY]++;
         return true;
      }
      dg[D_F_TRADE]++;
      lastRet = trade.ResultRetcode();
      PrintFormat("%s entry failed (%s): %u %s", sym, tag, lastRet, trade.ResultRetcodeDescription());
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
         double base = (InpRiskBase == RISK_START_BALANCE) ? g_startBalance : AccountInfoDouble(ACCOUNT_EQUITY);
         lots = base * InpRiskPct / 100.0 / (risk / ts * tv);
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

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(newsSoon || now >= g_s[i].exitTime || opened < g_s[i].day ||
         (InpMaxHoldMins > 0 && now - opened >= InpMaxHoldMins * 60))
      {
         if(trade.PositionClose(tkt)) continue;
      }
      g_s[i].openPos++; g_openTotal++;

      if(InpBreakevenR <= 0 && InpPartialR <= 0) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      bool   buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double risk = buy ? op - sl : sl - op;
      if(sl == 0 || risk <= 0) continue;                         // already at/after breakeven
      double cur  = buy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double gain = buy ? cur - op : op - cur;
      double beSL = NormalizeDouble(op, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));

      if(InpPartialR > 0 && gain >= risk * InpPartialR)
      {
         double vol  = PositionGetDouble(POSITION_VOLUME);
         double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         double part = MathFloor(vol * InpPartialPct / 100.0 / step) * step;
         if(part >= SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN) && part < vol) trade.PositionClosePartial(tkt, part);
         trade.PositionModify(tkt, beSL, tp);
      }
      else if(InpBreakevenR > 0 && gain >= risk * InpBreakevenR)
         trade.PositionModify(tkt, beSL, tp);
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

   string syms = InpSymbols;
   if(InpSymbolsFromFile)
   {
      int fh = OpenInputFile("BB_symbols.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(fh == INVALID_HANDLE) return INIT_FAILED;
      syms = "";
      while(!FileIsEnding(fh)) syms += FileReadString(fh) + ",";
      FileClose(fh);
   }
   string list[];
   int n = (Trim(syms) == "") ? 0 : StringSplit(syms, ',', list);
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

   if((InpTrendMode == TREND_INDEX || InpTrendMode == TREND_BOTH) && !SymbolSelect(InpTrendIndex, true))
   {
      Print("Trend index symbol not available: ", InpTrendIndex);
      return INIT_PARAMETERS_INCORRECT;
   }

   g_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   ArrayResize(g_rPid, 0); ArrayResize(g_rRisk, 0);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   if(ArraySize(g_s) > 1) EventSetTimer(1);   // other symbols may tick when the chart symbol doesn't
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(!MQLInfoInteger(MQL_OPTIMIZATION) && ArraySize(g_s) > 0) WriteStats();
   for(int i = ArraySize(g_s) - 1; i >= 0; i--) g_s[i].Release();
   ObjectsDeleteAll(0, "BB_");
}

void OnTick()  { Pass(); }
void OnTimer() { Pass(); }

//+------------------------------------------------------------------+
//| Per-symbol results + diagnostics (why a symbol did or didn't     |
//| trade). Single test: BB_symbol_stats.csv; optimisation (incl.    |
//| "All symbols selected in Market Watch"): one row per pass in     |
//| BB_optim_diag.csv. Both in Terminal\Common\Files.                |
//+------------------------------------------------------------------+
// Positions are aggregated from their deals (partial closes count once). Opening deal
// comment gives the pattern, its type the direction. Block n (after the symbols) = TOTAL.
int FindKey(const long &keys[], int n, long pid)
{
   int a = 0, b = n;
   while(a < b) { int m = (a + b) >> 1; if(keys[m] < pid * 4) a = m + 1; else b = m; }
   return (a < n && keys[a] / 4 == pid) ? a : -1;
}

void AddPos(double &pk[], int t, int w, int gp, int gl, double v)
{
   pk[t]++;
   if(v > 0) { pk[w]++; pk[gp] += v; } else pk[gl] -= v;
}

void PackStats(double &pk[])
{
   int n = ArraySize(g_s);
   ArrayResize(pk, (n + 1) * PK_SIZE);
   ArrayInitialize(pk, 0);
   for(int i = 0; i < n; i++)
   {
      for(int k = 0; k < D_COUNT; k++) pk[i * PK_SIZE + PK_DIAG + k] = g_s[i].dg[k];
      pk[i * PK_SIZE + PK_RET]  = g_s[i].lastRet;
      pk[i * PK_SIZE + PK_MODE] = (double)g_s[i].tradeMode;
   }

   if(HistorySelect(0, TimeCurrent()))
   {
      int nd = HistoryDealsTotal(), nk = 0;
      long keys[];
      ArrayResize(keys, nd);
      for(int k = 0; k < nd; k++)
      {
         ulong d = HistoryDealGetTicket(k);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         int bk = (StringFind(HistoryDealGetString(d, DEAL_COMMENT), "engulf") >= 0 ? 2 : 0) +
                  (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_SELL ? 1 : 0);
         keys[nk++] = HistoryDealGetInteger(d, DEAL_POSITION_ID) * 4 + bk;
      }
      ArrayResize(keys, nk);
      ArraySort(keys);

      double net[];
      int    psym[];
      int    closed[];
      ArrayResize(net, nk); ArrayResize(psym, nk); ArrayResize(closed, nk);
      ArrayInitialize(net, 0); ArrayInitialize(psym, -1); ArrayInitialize(closed, 0);
      for(int k = 0; k < nd; k++)
      {
         ulong d = HistoryDealGetTicket(k);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic) continue;
         int j = FindKey(keys, nk, HistoryDealGetInteger(d, DEAL_POSITION_ID));
         if(j < 0) continue;
         net[j] += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                   HistoryDealGetDouble(d, DEAL_COMMISSION);
         if(psym[j] < 0) psym[j] = FindSym(HistoryDealGetString(d, DEAL_SYMBOL));
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) closed[j] = 1;
      }
      for(int j = 0; j < nk; j++)
      {
         if(closed[j] == 0 || psym[j] < 0) continue;
         int b = psym[j] * PK_SIZE, o = b + PK_BK + (int)(keys[j] % 4) * PK_BKW;
         double rk = RiskOf(keys[j] / 4), r = (rk > 0) ? net[j] / rk : 0;
         AddPos(pk, b + PK_TRADES, b + PK_WINS, b + PK_GP, b + PK_GL, net[j]);
         AddPos(pk, o, o + 1, o + 2, o + 3, net[j]);
         pk[b + PK_SUMR] += r;
         pk[o + 4]       += r;
      }
   }

   int t = n * PK_SIZE;                                 // TOTAL block
   for(int i = 0; i < n; i++)
   {
      int b = i * PK_SIZE;
      pk[b + PK_NET] = pk[b + PK_GP] - pk[b + PK_GL];
      for(int k = 0; k < PK_SIZE; k++) if(k != PK_RET && k != PK_MODE) pk[t + k] += pk[b + k];
   }
   pk[t + PK_MODE] = (double)SYMBOL_TRADE_MODE_FULL;
}

string DiagHeader()
{
   string h = "pass,symbol,verdict,trade_mode,trades,winrate,net,pf,sum_R,exp_R";
   for(int k = 0; k < D_COUNT; k++) h += "," + DG_NAMES[k];
   h += ",last_retcode";
   for(int q = 0; q < 4; q++)
      h += "," + BK_NAMES[q] + "_trades," + BK_NAMES[q] + "_win," + BK_NAMES[q] + "_net," + BK_NAMES[q] + "_pf," + BK_NAMES[q] + "_expR";
   return h;
}

// Main reason a symbol did (not) trade - for screening large symbol lists
string Verdict(const double &p[], int b)
{
   double days = p[b + PK_DIAG + D_DAYS];
   if(p[b + PK_TRADES] > 0)                                               return "traded";
   if(days == 0)                                                          return "no_days";
   if(p[b + PK_DIAG + D_NODATA] + p[b + PK_DIAG + D_STALE] >= 0.5 * days) return "NO_DATA";
   if(p[b + PK_DIAG + D_F_TRADE] > 0)                                     return "TRADE_REJECTED";
   if(p[b + PK_DIAG + D_F_LOTS] > 0)                                      return "LOT_TOO_BIG";
   if(p[b + PK_DIAG + D_BREAKOUT] == 0)                                   return "no_breakouts";
   if(p[b + PK_DIAG + D_SETUP] == 0)                                      return "no_setups";
   return "filtered";
}

string DiagRow(long pass, string sym, const double &p[], int b)
{
   double tr = p[b + PK_TRADES];
   string r = StringFormat("%s,%s,%s,%s,%d,%.1f,%.2f,%.2f", pass < 0 ? "" : IntegerToString(pass), sym,
                           Verdict(p, b), TradeModeName((long)p[b + PK_MODE]), (int)tr,
                           tr > 0 ? 100.0 * p[b + PK_WINS] / tr : 0.0, p[b + PK_NET],
                           p[b + PK_GL] > 0 ? p[b + PK_GP] / p[b + PK_GL] : 0.0);
   r += StringFormat(",%.2f,%.3f", p[b + PK_SUMR], tr > 0 ? p[b + PK_SUMR] / tr : 0.0);
   for(int k = 0; k < D_COUNT; k++) r += "," + IntegerToString((long)p[b + PK_DIAG + k]);
   r += "," + IntegerToString((long)p[b + PK_RET]);
   for(int q = 0; q < 4; q++)
   {
      int o = b + PK_BK + q * PK_BKW;
      r += StringFormat(",%d,%.1f,%.2f,%.2f,%.3f", (int)p[o], p[o] > 0 ? 100.0 * p[o + 1] / p[o] : 0.0,
                        p[o + 2] - p[o + 3], p[o + 3] > 0 ? p[o + 2] / p[o + 3] : 0.0,
                        p[o] > 0 ? p[o + 4] / p[o] : 0.0);
   }
   return r;
}

void WriteStats()
{
   double pk[];
   PackStats(pk);
   int n = ArraySize(g_s);
   int h = FileOpen(STATS_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   Print(DiagHeader());
   if(h != INVALID_HANDLE) FileWriteString(h, DiagHeader() + "\r\n");
   for(int i = 0; i <= n; i++)
   {
      if(i == n && n == 1) break;                       // TOTAL only for baskets
      string row = DiagRow(-1, i < n ? g_s[i].sym : "TOTAL", pk, i * PK_SIZE);
      Print(row);
      if(h != INVALID_HANDLE) FileWriteString(h, row + "\r\n");
   }
   if(h != INVALID_HANDLE) { FileClose(h); Print("Per-symbol stats: Terminal\\Common\\Files\\", STATS_FILE); }
}

//+------------------------------------------------------------------+
//| Optimisation: each pass sends its per-symbol stats as frames,    |
//| collected here on the terminal side into one CSV.                |
//+------------------------------------------------------------------+
int g_diagFile = INVALID_HANDLE;

void OnTesterInit()
{
   g_diagFile = FileOpen(DIAG_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(g_diagFile != INVALID_HANDLE) FileWriteString(g_diagFile, DiagHeader() + "\r\n");
}

void OnTesterPass()
{
   ulong pass; string name; long id; double value; double data[];
   while(FrameNext(pass, name, id, value, data))
      if(g_diagFile != INVALID_HANDLE && ArraySize(data) == PK_SIZE)
         FileWriteString(g_diagFile, DiagRow((long)pass, name, data, 0) + "\r\n");
}

void OnTesterDeinit()
{
   OnTesterPass();
   if(g_diagFile == INVALID_HANDLE) return;
   FileClose(g_diagFile);
   Print("Optimisation diagnostics: Terminal\\Common\\Files\\", DIAG_FILE);
}

//+------------------------------------------------------------------+
//| Custom optimisation criterion: PF x sqrt(trades)                 |
//+------------------------------------------------------------------+
double OnTester()
{
   if(MQLInfoInteger(MQL_OPTIMIZATION))
   {
      double pk[], one[];
      PackStats(pk);
      int n = ArraySize(g_s);
      for(int i = 0; i <= n; i++)
      {
         if(i == n && n == 1) break;
         ArrayCopy(one, pk, 0, i * PK_SIZE, PK_SIZE);
         FrameAdd(i < n ? g_s[i].sym : "TOTAL", 1, pk[i * PK_SIZE + PK_TRADES], one);
      }
   }
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(trades < InpMinTradesOpt || pf <= 0) return 0;
   return pf * MathSqrt(trades);
}
//+------------------------------------------------------------------+
