//+------------------------------------------------------------------+
//|                                              NQ_Portfolio_EA.mq5 |
//|  Four intraday Nasdaq-100 strategies for USTEC (MT5, hedging):   |
//|    S1 Vault Break            (M30, long)                         |
//|    S2 VWAP Pullback + ADX    (M1,  long)                         |
//|    S3 Overnight Bias ORB     (M15, long/short)                   |
//|    S4 Drift VWAP Pullback    (M15 trend + M5 trigger, long/short)|
//|  Built from EA_Strategy_Spec_v1.md (v1.1)                         |
//|                                                                  |
//|  All rule times are entered in US Central Time (HHMM) and are    |
//|  converted to broker server time with InpServerMinusCT.          |
//+------------------------------------------------------------------+
#property copyright "Built from user-approved spec v1.1"
#property version   "1.10"
#property description "USTEC intraday portfolio: 4 strategies, prop floor/target guard, CSV trade log"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_PROFILE
  {
   PROFILE_PROP     = 0, // PROP: static floor + profit target, halts
   PROFILE_LIVE     = 1, // LIVE: optional floor, no target
   PROFILE_RESEARCH = 2  // RESEARCH: no guards (backtests for trade lists)
  };

enum ENUM_SIZING
  {
   SIZE_RISK_PCT   = 0, // Risk % of balance per trade
   SIZE_FIXED_LOTS = 1  // Fixed lots per strategy
  };

enum ENUM_MINLOT_RULE
  {
   MINLOT_SKIP        = 0, // Skip trade if size < min lot
   MINLOT_USE_IF_CAP  = 1  // Use min lot if its risk <= cap
  };

enum ENUM_ADR_MODE
  {
   ADR_SMA_OF_ATR = 0, // 15-day SMA of ATR(14)  (spec default)
   ADR_SMA_OF_TR  = 1  // 15-day SMA of daily True Range
  };

enum ENUM_S2_TP_MODE
  {
   S2TP_FIXED    = 0, // TP = N-bar high at signal, fixed (default)
   S2TP_RECALC   = 1, // TP recalculated every bar
   S2TP_PRETOUCH = 2, // TP = N-bar high ending at the VWAP-touch bar
   S2TP_SWING    = 3  // TP = highest high from arming to the touch
  };

enum ENUM_S4_LOSS_RULE
  {
   S4LOSS_TOTAL       = 0, // Max losses per day (total)
   S4LOSS_CONSECUTIVE = 1  // Max consecutive losses per day
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input int          InpServerMinusCT   = 8;      // Server time minus US Central (hours)
input bool         InpSkipHolidays    = true;   // Skip US holidays + early-close days
input bool         InpVerbose         = true;   // Print signals / skips to journal
input string       InpFilePrefix      = "NQPortfolio"; // CSV file prefix (Common\Files)
input string       InpRunTag          = "";     // Optional tag added to CSV file names

input group "=== Account & risk ==="
input ENUM_PROFILE     InpProfile          = PROFILE_PROP; // Account profile (PROP / LIVE / RESEARCH)
input double           InpInitialBalance   = 0;     // Initial balance (0 = balance at first attach)
input double           InpPropFloorPct     = 5.0;   // PROP static floor (% below initial)
input double           InpPropTargetPct    = 7.0;   // PROP profit target (%), 0 = off
input double           InpLiveFloorPct     = 0.0;   // LIVE static floor (% below initial), 0 = off
input double           InpLiveTrailDDPct   = 20.0;  // LIVE: halt if equity falls this % from its high (0 = off)
input double           InpFloorBufferPct   = 0.5;   // Safety buffer above floor (% of initial)
input bool             InpResetHalt        = false; // Clear a previous halt on start
input ENUM_SIZING      InpSizing           = SIZE_RISK_PCT; // Position sizing mode
input ENUM_MINLOT_RULE InpMinLotRule       = MINLOT_SKIP; // If size is below the minimum lot
input double           InpMinLotRiskCapPct = 1.0;   // Max risk % allowed when forcing min lot
input double           InpMaxLots          = 50.0;  // Hard cap on lots per trade
input int              InpDeviationPts     = 50;    // Max deviation (points) for market orders
input double           InpMinSizingPts     = 10.0;  // Size as if SL were at least this far (index pts)
input int              InpSessionEndBufMin = 5;     // Close all this many minutes before the broker session ends

input group "=== Shared calculations ==="
input ENUM_ADR_MODE InpADRMode   = ADR_SMA_OF_ATR; // Daily range (ADR) formula
input int           InpADRDays   = 15;   // Days in average daily range
input int           InpATRPeriod = 14;   // ATR period (ADR_SMA_OF_ATR mode)
input bool          InpADRUseSession = false; // Build daily bars from a session (not broker D1)
input int           InpADRSessionStartCT = 0; // Session start (HHMM CT); session ends 16:00 CT
input int           InpADXPeriod = 14;   // ADX period (Wilder)

input group "=== S1 Vault Break (M30, long) ==="
input bool   InpS1_Enable        = true; // S1: Enable strategy
input long   InpS1_Magic         = 26001; // S1: Magic number (must be unique)
input double InpS1_RiskPct       = 0.25; // S1: Risk % per trade (risk-% sizing)
input double InpS1_FixedLots     = 0.1; // S1: Lots per trade (fixed-lots sizing)
input int    InpS1_AnchorCT      = 0;     // S1: Session open + VWAP anchor (HHMM CT; 2300 = prev evening)
input double InpS1_NoiseFrac     = 0.30;  // S1: Noise level = open + frac x ADR
input int    InpS1_WindowStartCT = 1000;  // S1: Signal-bar close from (HHMM CT)  [test 1030]
input int    InpS1_WindowEndCT   = 1430;  // S1: Signal-bar close before (HHMM CT)
input int    InpS1_ExitCT        = 1430;  // S1: Time exit (HHMM CT)
input int    InpS1_MaxEntries    = 3;     // S1: Max entries per day
input int    InpS1_MaxLosses     = 1;     // S1: Stop for the day after this many losses (0 = off)
input double InpS1_TPPts         = 40;    // S1: Take profit (index points)
input double InpS1_SLPts         = 75;    // S1: Stop loss (index points)
input bool   InpS1_ScaleWithADR  = false; // S1: Scale TP/SL by ADR / RefADR
input double InpS1_RefADR        = 324;   // S1: Reference ADR for scaling (2022-26 median)
input double InpS1_MaxSpreadPts  = 4.0;   // S1: Max spread to enter (index points)

input group "=== S2 VWAP Pullback + ADX (M1, long) ==="
input bool            InpS2_Enable       = false; // S2: Enable strategy
input long            InpS2_Magic        = 26002; // S2: Magic number (must be unique)
input double          InpS2_RiskPct      = 0.25; // S2: Risk % per trade (risk-% sizing)
input double          InpS2_FixedLots    = 0.1; // S2: Lots per trade (fixed-lots sizing)
input int             InpS2_ORStartCT    = 830;   // S2: Opening range start (HHMM CT)
input int             InpS2_OREndCT      = 900;   // S2: Opening range end (HHMM CT)
input int             InpS2_VWAPAnchorCT = 830;   // S2: VWAP anchor (HHMM CT) [test 0]
input double          InpS2_ADXMin       = 20; // S2: Minimum ADX
input int             InpS2_CutoffCT     = 1430;  // S2: No new entries from (HHMM CT)
input int             InpS2_ExitCT       = 1455;  // S2: Time exit (HHMM CT) [test 1555]
input int             InpS2_MaxTrades    = 1;     // S2: Max trades per day [test 2]
input int             InpS2_TPBars       = 5;     // S2: TP = highest high of N bars
input int             InpS2_SLBars       = 20;    // S2: SL = lowest low of N bars
input ENUM_S2_TP_MODE InpS2_TPMode       = S2TP_FIXED; // S2: Take-profit placement
input double          InpS2_MinTPPts     = 1.0;   // S2: Skip if TP is closer than this above entry
input double          InpS2_MaxSpreadPts = 3.0; // S2: Max spread to enter (index points)

input group "=== S3 Overnight Bias ORB (M15, long/short) ==="
input bool   InpS3_Enable       = true; // S3: Enable strategy
input long   InpS3_Magic        = 26003; // S3: Magic number (must be unique)
input double InpS3_RiskPct      = 0.50; // S3: Risk % per trade (risk-% sizing)
input double InpS3_FixedLots    = 0.1; // S3: Lots per trade (fixed-lots sizing)
input int    InpS3_ONStartCT    = 0;     // S3: Overnight range start (HHMM CT) [test 2300]
input int    InpS3_OpenCT       = 830;   // S3: Cash open / bias bar (HHMM CT)
input double InpS3_ADXMin       = 20; // S3: Minimum ADX
input int    InpS3_CutoffCT     = 1400;  // S3: No new entries from (HHMM CT) [test 1430]
input int    InpS3_ExitCT       = 1430;  // S3: Time exit (HHMM CT)
input double InpS3_SLFrac       = 0.40;  // S3: SL = frac x ADR
input double InpS3_TPMult       = 3.0;   // S3: TP = mult x SL
input bool   InpS3_AllowLong    = true; // S3: Allow long trades
input bool   InpS3_AllowShort   = true; // S3: Allow short trades
input double InpS3_MaxSpreadPts = 4.0; // S3: Max spread to enter (index points)

input group "=== S4 Drift VWAP Pullback / Golden Ticket (M15 + M5) ==="
input bool              InpS4_Enable       = false; // S4: Enable strategy
input long              InpS4_Magic        = 26004; // S4: Magic number (must be unique)
input double            InpS4_RiskPct      = 0.25; // S4: Risk % per trade (risk-% sizing)
input double            InpS4_FixedLots    = 0.1; // S4: Lots per trade (fixed-lots sizing)
input int               InpS4_VWAPAnchorCT = 830;   // S4: VWAP anchor on M15 (HHMM CT)
input int               InpS4_TradeStartCT = 930;   // S4: First signal-bar close (HHMM CT)
input int               InpS4_CutoffCT     = 1430;  // S4: No new entries from (HHMM CT)
input int               InpS4_ExitCT       = 1455;  // S4: Close all (HHMM CT)
input double            InpS4_MinMovePct   = 0.10;  // S4: Min 1-hour move (%)
input int               InpS4_LookbackBars = 4;     // S4: M15 bars for the move (4 = 1 hour)
input double            InpS4_LongTPPts    = 40; // S4: Long take profit (index points)
input double            InpS4_LongSLPts    = 80; // S4: Long stop loss (index points)
input double            InpS4_ShortTPPts   = 50; // S4: Short take profit (index points)
input double            InpS4_ShortSLPts   = 80; // S4: Short stop loss (index points)
input bool              InpS4_ScaleWithADR = false; // S4: Scale TP/SL by ADR / RefADR
input double            InpS4_RefADR       = 324;   // S4: Reference ADR (2022-26 median)
input int               InpS4_MaxTrades    = 4; // S4: Max trades per day
input int               InpS4_MaxLosses    = 2; // S4: Stop for the day after this many losses
input ENUM_S4_LOSS_RULE InpS4_LossRule     = S4LOSS_TOTAL; // S4: Loss limit counts total or consecutive losses
input bool              InpS4_AllowLong    = true; // S4: Allow long trades
input bool              InpS4_AllowShort   = true; // S4: Allow short trades
input double            InpS4_MaxSpreadPts = 3.0; // S4: Max spread to enter (index points)

//+------------------------------------------------------------------+
//| Structures                                                       |
//+------------------------------------------------------------------+
struct StratState
  {
   string   name;
   long     magic;
   datetime day;
   int      trades;
   int      losses;
   int      consecLosses;
   long     trackedPosId;
  };

struct VWAPAcc
  {
   double pv;
   double v;
   double last;
   double prev;
   int    cnt;
  };

struct S1State
  {
   datetime day;
   bool     haveOpen;
   double   sessOpen;
   VWAPAcc  vw;
  };

struct S2State
  {
   datetime day;
   bool     orInit;
   double   orH;
   double   orL;
   bool     armed;
   bool     touched;
   double   swingHigh;   // highest high from arming up to the touch
   datetime touchTime;   // bar time of the VWAP touch
   VWAPAcc  vw;
  };

struct S3State
  {
   datetime day;
   bool     onInit;
   double   onH;
   double   onL;
   bool     orDone;
   double   orH;
   double   orL;
   int      bias;
  };

struct S4State
  {
   datetime day;
   VWAPAcc  vw;
   int      trend;       // +1 long, -1 short, 0 none
   datetime trendClose;  // close time of the M15 bar that set the trend
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
#define NSTRAT 4
#define K_S1 0
#define K_S2 1
#define K_S3 2
#define K_S4 3

CTrade     g_trade;
StratState g_st[NSTRAT];
S1State    g_s1;
S2State    g_s2;
S3State    g_s3;
S4State    g_s4;

int      g_hADX_M1  = INVALID_HANDLE;
int      g_hADX_M15 = INVALID_HANDLE;

double   g_initBal = 0;
double   g_hwm     = 0;      // LIVE: highest equity seen (trailing drawdown)
bool     g_halted  = false;
string   g_gv      = "";

datetime g_cur30 = 0, g_cur1 = 0, g_cur15s3 = 0, g_cur15s4 = 0, g_cur5 = 0;

datetime g_adrDay = 0;
double   g_adrVal = 0;
datetime g_adrLogDay[];
double   g_adrLogVal[];

datetime g_blkDay = 0;
bool     g_blkVal = false;

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
int MinOfDay(datetime t)      { return (int)(((long)t % 86400) / 60); }
datetime DayStart(datetime t) { return (datetime)((long)t - ((long)t % 86400)); }

// HHMM in US Central -> minute of the server day
int SrvMin(int hhmmCT)
  {
   int m = (hhmmCT / 100) * 60 + (hhmmCT % 100) + InpServerMinusCT * 60;
   m %= 1440;
   if(m < 0)
      m += 1440;
   return m;
  }

bool ValidHHMM(int v) { return (v >= 0 && v / 100 < 24 && v % 100 < 60); }

datetime MkDate(int y, int m, int d)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = y;
   s.mon  = m;
   s.day  = d;
   return StructToTime(s);
  }

int DOW(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;
  }

// Weekend-observed date of a fixed holiday (0 if not observed)
datetime Observed(datetime h, bool allowFridayBefore)
  {
   int w = DOW(h);
   if(w == 6)
      return allowFridayBefore ? h - 86400 : 0;
   if(w == 0)
      return h + 86400;
   return h;
  }

datetime NthWeekday(int y, int m, int dow, int n)
  {
   datetime t = MkDate(y, m, 1);
   int add = (dow - DOW(t) + 7) % 7;
   return t + (add + 7 * (n - 1)) * 86400;
  }

datetime LastWeekday(int y, int m, int dow)
  {
   int ny = y, nm = m + 1;
   if(nm == 13)
     {
      nm = 1;
      ny++;
     }
   datetime t = MkDate(ny, nm, 1) - 86400;
   int sub = (DOW(t) - dow + 7) % 7;
   return t - sub * 86400;
  }

datetime EasterSunday(int y)
  {
   int a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4;
   int f = (b + 8) / 25, g = (b - f + 1) / 3;
   int h = (19 * a + b - d - g + 15) % 30;
   int i = c / 4, k = c % 4;
   int l = (32 + 2 * e + 2 * i - h - k) % 7;
   int m = (a + 11 * h + 22 * l) / 451;
   int mon = (h + l - 7 * m + 114) / 31;
   int dd  = ((h + l - 7 * m + 114) % 31) + 1;
   return MkDate(y, mon, dd);
  }

// US (NYSE) full holidays and early-close days
bool IsUSHolidayOrEarlyClose(datetime t)
  {
   datetime d = DayStart(t);
   MqlDateTime s;
   TimeToStruct(d, s);
   int y = s.year;

   if(d == Observed(MkDate(y, 1, 1), false))
      return true;                                   // New Year
   if(d == NthWeekday(y, 1, 1, 3))
      return true;                                   // MLK
   if(d == NthWeekday(y, 2, 1, 3))
      return true;                                   // Presidents
   if(d == EasterSunday(y) - 2 * 86400)
      return true;                                   // Good Friday
   if(d == LastWeekday(y, 5, 1))
      return true;                                   // Memorial
   if(y >= 2022 && d == Observed(MkDate(y, 6, 19), true))
      return true;                                   // Juneteenth
   if(d == Observed(MkDate(y, 7, 4), true))
      return true;                                   // Independence
   if(d == NthWeekday(y, 9, 1, 1))
      return true;                                   // Labor
   datetime tg = NthWeekday(y, 11, 4, 4);
   if(d == tg)
      return true;                                   // Thanksgiving
   if(d == Observed(MkDate(y, 12, 25), true))
      return true;                                   // Christmas
   // early closes
   if(d == tg + 86400)
      return true;                                   // Day after Thanksgiving
   datetime j3 = MkDate(y, 7, 3);
   int w = DOW(j3);
   if(d == j3 && w >= 1 && w <= 4)
      return true;
   datetime c24 = MkDate(y, 12, 24);
   w = DOW(c24);
   if(d == c24 && w >= 1 && w <= 4)
      return true;
   return false;
  }

bool DayBlocked(datetime d)
  {
   if(!InpSkipHolidays)
      return false;
   datetime ds = DayStart(d);
   if(ds != g_blkDay)
     {
      g_blkDay = ds;
      g_blkVal = IsUSHolidayOrEarlyClose(ds);
     }
   return g_blkVal;
  }

//+------------------------------------------------------------------+
//| Symbol / price helpers                                           |
//+------------------------------------------------------------------+
double TickSize()
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (ts > 0) ? ts : _Point;
  }

double NormPrice(double p)
  {
   double ts = TickSize();
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

double StopsLevelPrice()
  {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
  }

// Account-currency value of a 1.0 price move for 1.0 lot
double ValuePerPointPerLot()
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0 || tv <= 0)
      return 0;
   return tv / ts;
  }

bool StopsOK(bool isLong, double sl, double tp)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lvl = StopsLevelPrice();
   if(isLong)
      return (sl < bid - lvl && tp > bid + lvl);
   return (sl > ask + lvl && tp < ask - lvl);
  }

void Log(int k, string msg)
  {
   if(InpVerbose)
      Print(g_st[k].name, " | ", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), " | ", msg);
  }

//+------------------------------------------------------------------+
//| VWAP accumulator                                                 |
//+------------------------------------------------------------------+
void VWReset(VWAPAcc &a)
  {
   a.pv = 0;
   a.v = 0;
   a.last = 0;
   a.prev = 0;
   a.cnt = 0;
  }

void VWAdd(VWAPAcc &a, const MqlRates &b)
  {
   double tp  = (b.high + b.low + b.close) / 3.0;
   double vol = (double)b.tick_volume;
   if(vol <= 0)
      vol = 1;
   a.pv += tp * vol;
   a.v  += vol;
   a.prev = a.last;
   a.last = a.pv / a.v;
   a.cnt++;
  }

//+------------------------------------------------------------------+
//| Session daily bars: H/L/C of M30 bars from the session start to  |
//| the end of each server day (16:00 CT), completed days only       |
//+------------------------------------------------------------------+
int BuildSessionDays(datetime today, double &dh[], double &dl[], double &dc[])
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, PERIOD_M30, today - 80 * 86400, today - 1, r);
   if(n <= 0)
      return 0;
   int sMin = SrvMin(InpADRSessionStartCT);
   int cnt = 0;
   datetime cur = 0;
   ArrayResize(dh, 0);
   ArrayResize(dl, 0);
   ArrayResize(dc, 0);
   for(int i = 0; i < n; i++)
     {
      if(MinOfDay(r[i].time) < sMin)
         continue;
      datetime day = DayStart(r[i].time);
      if(day != cur)
        {
         cur = day;
         cnt++;
         ArrayResize(dh, cnt);
         ArrayResize(dl, cnt);
         ArrayResize(dc, cnt);
         dh[cnt - 1] = r[i].high;
         dl[cnt - 1] = r[i].low;
        }
      else
        {
         dh[cnt - 1] = MathMax(dh[cnt - 1], r[i].high);
         dl[cnt - 1] = MathMin(dl[cnt - 1], r[i].low);
        }
      dc[cnt - 1] = r[i].close;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Average daily range (completed days only)                        |
//+------------------------------------------------------------------+
double GetADR(datetime anyTimeToday)
  {
   datetime d = DayStart(anyTimeToday);
   if(d == g_adrDay && g_adrVal > 0)
      return g_adrVal;

   int need = (InpADRMode == ADR_SMA_OF_ATR) ? InpADRDays + InpATRPeriod + 1 : InpADRDays + 1;
   double dh[], dl[], dc[];
   int n = 0;
   if(InpADRUseSession)
      n = BuildSessionDays(d, dh, dl, dc);
   else
     {
      MqlRates r[];
      ArraySetAsSeries(r, false);
      n = CopyRates(_Symbol, PERIOD_D1, d - 1, need, r);   // ends with yesterday's bar
      if(n > 0)
        {
         ArrayResize(dh, n);
         ArrayResize(dl, n);
         ArrayResize(dc, n);
         for(int i = 0; i < n; i++)
           {
            dh[i] = r[i].high;
            dl[i] = r[i].low;
            dc[i] = r[i].close;
           }
        }
     }
   if(n < need)
      return 0;

   double tr[];
   ArrayResize(tr, n);
   tr[0] = dh[0] - dl[0];
   for(int i = 1; i < n; i++)
     {
      double pc = dc[i - 1];
      tr[i] = MathMax(dh[i], pc) - MathMin(dl[i], pc);
     }

   double adr = 0;
   if(InpADRMode == ADR_SMA_OF_TR)
     {
      for(int j = n - InpADRDays; j < n; j++)
         adr += tr[j];
      adr /= InpADRDays;
     }
   else
     {
      for(int j = n - InpADRDays; j < n; j++)
        {
         double a = 0;
         for(int k = j - InpATRPeriod + 1; k <= j; k++)
            a += tr[k];
         adr += a / InpATRPeriod;
        }
      adr /= InpADRDays;
     }

   if(adr > 0)
     {
      g_adrDay = d;
      g_adrVal = adr;
      int m = ArraySize(g_adrLogDay);
      ArrayResize(g_adrLogDay, m + 1);
      ArrayResize(g_adrLogVal, m + 1);
      g_adrLogDay[m] = d;
      g_adrLogVal[m] = adr;
     }
   return adr;
  }

//+------------------------------------------------------------------+
//| ADX (Wilder) value of a given bar and the bar before it          |
//+------------------------------------------------------------------+
bool GetADX(int handle, datetime barTime, double &adx, double &adxPrev)
  {
   if(handle == INVALID_HANDLE)
      return false;
   double b[];
   ArraySetAsSeries(b, false);
   if(CopyBuffer(handle, 0, barTime, 2, b) != 2)
      return false;
   adx = b[1];
   adxPrev = b[0];
   return (adx != EMPTY_VALUE && adxPrev != EMPTY_VALUE);
  }

//+------------------------------------------------------------------+
//| Positions                                                        |
//+------------------------------------------------------------------+
// Returns the ticket of this strategy's open position (and selects it), 0 if none
ulong PosTicket(long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      return t;
     }
   return 0;
  }

bool IsOurMagic(long magic)
  {
   for(int k = 0; k < NSTRAT; k++)
      if(g_st[k].magic == magic)
         return true;
   return false;
  }

string TagOfMagic(long magic)
  {
   for(int k = 0; k < NSTRAT; k++)
      if(g_st[k].magic == magic)
         return g_st[k].name;
   return "";
  }

void CloseAllOurs(string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         continue;
      if(!g_trade.PositionClose(t))
         Print("CloseAll (", why, ") failed for ", t, " rc=", g_trade.ResultRetcode());
     }
  }

// Money at risk to stop on all open positions in this symbol
double OpenRiskAmount()
  {
   double vpp = ValuePerPointPerLot();
   double sum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      double sl  = PositionGetDouble(POSITION_SL);
      double cur = PositionGetDouble(POSITION_PRICE_CURRENT);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(sl <= 0)
         continue;
      double dist = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? cur - sl : sl - cur;
      if(dist > 0)
         sum += dist * vol * vpp;
     }
   return sum;
  }

//+------------------------------------------------------------------+
//| Daily counters                                                   |
//+------------------------------------------------------------------+
// Rebuild today's trade/loss counters from history (robust to restarts)
void EnsureDay(int k, datetime anyTime)
  {
   datetime d = DayStart(anyTime);
   if(g_st[k].day == d)
      return;
   g_st[k].day = d;
   g_st[k].trades = 0;
   g_st[k].losses = 0;
   g_st[k].consecLosses = 0;
   if(!HistorySelect(d, d + 86400))
      return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != g_st[k].magic)
         continue;
      long e = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(e == DEAL_ENTRY_IN)
         g_st[k].trades++;
      else
         if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
           {
            double pl = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) +
                        HistoryDealGetDouble(t, DEAL_COMMISSION);
            if(pl < 0)
              {
               g_st[k].losses++;
               g_st[k].consecLosses++;
              }
            else
               g_st[k].consecLosses = 0;
           }
     }
  }

// Detect that the tracked position has closed and record win/loss
void CheckClosed(int k)
  {
   if(g_st[k].trackedPosId == 0)
      return;
   if(PosTicket(g_st[k].magic) != 0)
      return;
   if(!HistorySelectByPosition(g_st[k].trackedPosId))
      return;
   double pl = 0;
   int outs = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      pl += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) +
            HistoryDealGetDouble(t, DEAL_COMMISSION);
      long e = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
         outs++;
     }
   if(outs == 0)
      return;
   if(pl < 0)
     {
      g_st[k].losses++;
      g_st[k].consecLosses++;
     }
   else
      g_st[k].consecLosses = 0;
   Log(k, StringFormat("closed P/L %.2f  (losses today %d, consecutive %d)", pl, g_st[k].losses, g_st[k].consecLosses));
   g_st[k].trackedPosId = 0;
  }

//+------------------------------------------------------------------+
//| Account guards (floor / target)                                  |
//+------------------------------------------------------------------+
double FloorLevel()
  {
   if(InpProfile == PROFILE_RESEARCH)
      return -1;
   double pct = (InpProfile == PROFILE_PROP) ? InpPropFloorPct : InpLiveFloorPct;
   double fl = (pct > 0) ? g_initBal * (1.0 - pct / 100.0) : -1;
   // LIVE: trailing floor below the equity high-water mark
   if(InpProfile == PROFILE_LIVE && InpLiveTrailDDPct > 0 && g_hwm > 0)
      fl = MathMax(fl, g_hwm * (1.0 - InpLiveTrailDDPct / 100.0));
   return fl;
  }

// LIVE: track the equity high-water mark (persisted across restarts)
void UpdateHWM()
  {
   if(InpProfile != PROFILE_LIVE || InpLiveTrailDDPct <= 0)
      return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_hwm)
     {
      g_hwm = eq;
      GlobalVariableSet(g_gv + "hwm", g_hwm);
     }
  }

double BufferAmount() { return g_initBal * InpFloorBufferPct / 100.0; }

double TargetLevel()
  {
   if(InpProfile != PROFILE_PROP || InpPropTargetPct <= 0)
      return -1;
   return g_initBal * (1.0 + InpPropTargetPct / 100.0);
  }

void SetHalt(string why)
  {
   g_halted = true;
   GlobalVariableSet(g_gv + "halt", 1);
   Print("*** EA HALTED: ", why, " ***  (set InpResetHalt=true to clear)");
  }

void CheckGuards()
  {
   if(InpProfile == PROFILE_RESEARCH)
      return;
   if(g_halted)
     {
      CloseAllOurs("halted");
      return;
     }
   UpdateHWM();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double fl = FloorLevel();
   if(fl > 0 && eq <= fl + BufferAmount())
     {
      CloseAllOurs("floor");
      SetHalt(StringFormat("equity %.2f reached floor+buffer %.2f", eq, fl + BufferAmount()));
      return;
     }
   double tg = TargetLevel();
   if(tg > 0 && eq >= tg)
     {
      CloseAllOurs("target");
      SetHalt(StringFormat("profit target reached, equity %.2f >= %.2f", eq, tg));
     }
  }

// Pre-trade: would the floor survive if every open position + this one hit its stop?
bool FloorAllows(double newRisk)
  {
   double fl = FloorLevel();
   if(fl <= 0)
      return true;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (eq - OpenRiskAmount() - newRisk >= fl + BufferAmount());
  }

//+------------------------------------------------------------------+
//| Position sizing                                                  |
//+------------------------------------------------------------------+
double CalcLots(double riskPts, double riskPct, double fixedLots, string &why)
  {
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maxL = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLots);
   if(step <= 0)
      step = minL;
   double vpp = ValuePerPointPerLot();
   // size as if the stop were at least InpMinSizingPts away (stops a very tight
   // S2 stop from producing an oversized position)
   double perLot = MathMax(riskPts, InpMinSizingPts) * vpp;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double lots;

   if(InpSizing == SIZE_FIXED_LOTS)
      lots = fixedLots;
   else
     {
      if(perLot <= 0 || bal <= 0)
        {
         why = "cannot value risk";
         return 0;
        }
      lots = (bal * riskPct / 100.0) / perLot;
     }

   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minL - 1e-9)
     {
      if(InpSizing == SIZE_FIXED_LOTS || InpMinLotRule == MINLOT_SKIP)
        {
         why = StringFormat("size below min lot (risk at min lot = %.2f%%)", (bal > 0 ? minL * perLot / bal * 100.0 : 0));
         return 0;
        }
      double riskAtMin = (bal > 0) ? minL * perLot / bal * 100.0 : 1e9;
      if(riskAtMin > InpMinLotRiskCapPct)
        {
         why = StringFormat("min lot risk %.2f%% > cap %.2f%%", riskAtMin, InpMinLotRiskCapPct);
         return 0;
        }
      lots = minL;
     }
   if(lots > maxL)
      lots = MathFloor(maxL / step + 1e-9) * step;
   int digits = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(lots, digits);
  }

//+------------------------------------------------------------------+
//| Order entry                                                      |
//|  absolute=true : slArg/tpArg are price levels                    |
//|  absolute=false: slArg/tpArg are distances from the fill price   |
//+------------------------------------------------------------------+
bool OpenTrade(int k, bool isLong, bool absolute, double slArg, double tpArg,
               double riskPct, double fixedLots, double maxSpread)
  {
   if(g_halted)
      return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return false;
   double spread = ask - bid;
   if(maxSpread > 0 && spread > maxSpread)
     {
      Log(k, StringFormat("SKIP: spread %.2f > max %.2f", spread, maxSpread));
      return false;
     }

   double price = isLong ? ask : bid;
   double sl, tp, slDist, tpDist;
   if(absolute)
     {
      sl = slArg;
      tp = tpArg;
      slDist = isLong ? price - sl : sl - price;
      tpDist = isLong ? tp - price : price - tp;
     }
   else
     {
      slDist = slArg;
      tpDist = tpArg;
      sl = isLong ? price - slDist : price + slDist;
      tp = isLong ? price + tpDist : price - tpDist;
     }
   sl = NormPrice(sl);
   tp = NormPrice(tp);
   if(slDist <= 0 || tpDist <= 0)
     {
      Log(k, StringFormat("SKIP: invalid distances SL %.2f TP %.2f", slDist, tpDist));
      return false;
     }
   if(!StopsOK(isLong, sl, tp))
     {
      Log(k, StringFormat("SKIP: stops too close (SL %.2f TP %.2f, stops level %.2f)", sl, tp, StopsLevelPrice()));
      return false;
     }

   string why = "";
   double lots = CalcLots(slDist, riskPct, fixedLots, why);
   if(lots <= 0)
     {
      Log(k, "SKIP: " + why);
      return false;
     }
   double newRisk = slDist * lots * ValuePerPointPerLot();
   if(!FloorAllows(newRisk))
     {
      Log(k, StringFormat("SKIP: floor check (equity %.2f, open risk %.2f, new risk %.2f, floor+buffer %.2f)",
                          AccountInfoDouble(ACCOUNT_EQUITY), OpenRiskAmount(), newRisk, FloorLevel() + BufferAmount()));
      return false;
     }

   string cmt = StringFormat("%s R%.2f", g_st[k].name, slDist);
   g_trade.SetExpertMagicNumber((ulong)g_st[k].magic);
   bool ok = isLong ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt)
                    : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);
   uint rc = g_trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      Log(k, StringFormat("ORDER FAILED rc=%u %s", rc, g_trade.ResultRetcodeDescription()));
      return false;
     }
   g_st[k].trades++;

   // position id from the deal (robust), fallback to position lookup
   long pid = 0;
   ulong deal = g_trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      pid = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   ulong pt = PosTicket(g_st[k].magic);
   if(pt > 0)
     {
      if(pid == 0)
         pid = PositionGetInteger(POSITION_IDENTIFIER);
      if(!absolute)
        {
         // re-anchor SL/TP to the actual fill price
         double fp  = PositionGetDouble(POSITION_PRICE_OPEN);
         double nsl = NormPrice(isLong ? fp - slDist : fp + slDist);
         double ntp = NormPrice(isLong ? fp + tpDist : fp - tpDist);
         double ts  = TickSize();
         if((MathAbs(nsl - sl) > ts / 2 || MathAbs(ntp - tp) > ts / 2) && StopsOK(isLong, nsl, ntp))
            g_trade.PositionModify(pt, nsl, ntp);
        }
     }
   g_st[k].trackedPosId = pid;
   Log(k, StringFormat("ENTRY %s %.2f lots @%.2f  SL %.2f (%.1f pts)  TP %.2f (%.1f pts)  spread %.2f  trade #%d today",
                       isLong ? "LONG" : "SHORT", lots, price, sl, slDist, tp, tpDist, spread, g_st[k].trades));
   return true;
  }

//+------------------------------------------------------------------+
//| Time exits                                                       |
//+------------------------------------------------------------------+
// Minute of the server day at which the broker's last trading session for today ends
datetime g_sessDay = 0;
int      g_sessEnd = 1440;
int SessionEndMin(datetime now)
  {
   datetime d = DayStart(now);
   if(d == g_sessDay)
      return g_sessEnd;
   g_sessDay = d;
   int endMin = -1;
   datetime from, to;
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)DOW(now);
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(_Symbol, dow, i, from, to))
         break;
      int e = (int)(((long)to) / 60);
      if(e <= 0 || e > 1440)
         e = 1440;
      if(e > endMin)
         endMin = e;
     }
   g_sessEnd = (endMin > 0) ? endMin : 1440;
   return g_sessEnd;
  }

void TimeExit(int k, int exitCT, datetime now)
  {
   ulong t = PosTicket(g_st[k].magic);
   if(t == 0)
      return;
   datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
   bool stale = (DayStart(opened) < DayStart(now));
   // safety net: never hold into the broker's session close (e.g. Friday, short sessions)
   bool sessEnd = (MinOfDay(now) >= SessionEndMin(now) - InpSessionEndBufMin);
   if(stale || sessEnd || MinOfDay(now) >= SrvMin(exitCT))
     {
      if(g_trade.PositionClose(t))
         Log(k, stale ? "EXIT: position from previous day" : "EXIT: time exit");
      else
         Log(k, StringFormat("time exit close failed rc=%u", g_trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Closed-bar feed: returns all bars closed since the cursor        |
//+------------------------------------------------------------------+
int GetNewBars(ENUM_TIMEFRAMES tf, datetime &cursor, MqlRates &out[])
  {
   datetime lastClosed = iTime(_Symbol, tf, 1);
   if(lastClosed == 0)
      return 0;
   if(cursor == 0)
      cursor = DayStart(TimeCurrent()) - 1;      // replay today's bars on first run
   if(lastClosed <= cursor)
      return 0;
   ArraySetAsSeries(out, false);
   int n = CopyRates(_Symbol, tf, cursor + 1, lastClosed, out);
   if(n <= 0)
      return 0;
   cursor = lastClosed;
   return n;
  }

// Only the most recent closed bar may trade, and only if we are still inside the next bar
bool IsFresh(const MqlRates &b, ENUM_TIMEFRAMES tf)
  {
   return (TimeCurrent() < b.time + 2 * PeriodSeconds(tf));
  }

//+------------------------------------------------------------------+
//| S1  Vault Break                                                  |
//+------------------------------------------------------------------+
void S1_OnBar(const MqlRates &b, bool latest)
  {
   datetime d = DayStart(b.time);
   EnsureDay(K_S1, b.time);
   if(g_s1.day != d)
     {
      g_s1.day = d;
      g_s1.haveOpen = false;
      g_s1.sessOpen = 0;
      VWReset(g_s1.vw);
     }
   int om = MinOfDay(b.time);
   if(!g_s1.haveOpen)
     {
      if(om < SrvMin(InpS1_AnchorCT))
         return;
      g_s1.haveOpen = true;
      g_s1.sessOpen = b.open;
      GetADR(b.time);   // compute once a day (also feeds the ADR log)
     }
   VWAdd(g_s1.vw, b);
   if(!latest)
      return;

   int cm = om + PeriodSeconds(PERIOD_M30) / 60;
   if(cm < SrvMin(InpS1_WindowStartCT) || cm >= SrvMin(InpS1_WindowEndCT))
      return;
   if(DayBlocked(d))
      return;
   if(PosTicket(g_st[K_S1].magic) != 0)
      return;
   if(g_st[K_S1].trades >= InpS1_MaxEntries)
      return;
   if(InpS1_MaxLosses > 0 && g_st[K_S1].losses >= InpS1_MaxLosses)
      return;
   double adr = GetADR(b.time);
   if(adr <= 0)
     {
      Log(K_S1, "SKIP: ADR unavailable");
      return;
     }
   double noise = g_s1.sessOpen + InpS1_NoiseFrac * adr;
   double vwap  = g_s1.vw.last;
   if(!(b.close > noise && b.close > vwap))
      return;

   double tpPts = InpS1_TPPts, slPts = InpS1_SLPts;
   if(InpS1_ScaleWithADR && InpS1_RefADR > 0)
     {
      double f = adr / InpS1_RefADR;
      tpPts *= f;
      slPts *= f;
     }
   Log(K_S1, StringFormat("SIGNAL close %.2f > noise %.2f (open %.2f + %.2f x ADR %.1f) and > VWAP %.2f",
                          b.close, noise, g_s1.sessOpen, InpS1_NoiseFrac, adr, vwap));
   OpenTrade(K_S1, true, false, slPts, tpPts, InpS1_RiskPct, InpS1_FixedLots, InpS1_MaxSpreadPts);
  }

//+------------------------------------------------------------------+
//| S2  VWAP Pullback + ADX                                          |
//+------------------------------------------------------------------+
void S2_OnBar(const MqlRates &b, bool latest)
  {
   datetime d = DayStart(b.time);
   EnsureDay(K_S2, b.time);
   if(g_s2.day != d)
     {
      g_s2.day = d;
      g_s2.orInit = false;
      g_s2.orH = 0;
      g_s2.orL = 0;
      g_s2.armed = false;
      g_s2.touched = false;
      g_s2.swingHigh = 0;
      g_s2.touchTime = 0;
      VWReset(g_s2.vw);
     }
   int om  = MinOfDay(b.time);
   int orS = SrvMin(InpS2_ORStartCT), orE = SrvMin(InpS2_OREndCT);
   if(om >= SrvMin(InpS2_VWAPAnchorCT))
      VWAdd(g_s2.vw, b);

   if(om >= orS && om < orE)
     {
      if(!g_s2.orInit)
        {
         g_s2.orH = b.high;
         g_s2.orL = b.low;
         g_s2.orInit = true;
        }
      else
        {
         g_s2.orH = MathMax(g_s2.orH, b.high);
         g_s2.orL = MathMin(g_s2.orL, b.low);
        }
      return;
     }
   if(om < orE || !g_s2.orInit || g_s2.vw.cnt == 0)
      return;

   double vwap = g_s2.vw.last;
   if(!g_s2.armed && b.close > g_s2.orH)
     {
      g_s2.armed = true;
      if(latest)
         Log(K_S2, StringFormat("ARMED: close %.2f > OR high %.2f", b.close, g_s2.orH));
     }
   if(g_s2.armed && !g_s2.touched)
      g_s2.swingHigh = MathMax(g_s2.swingHigh, b.high);
   if(g_s2.armed && !g_s2.touched && b.low <= vwap)
     {
      g_s2.touched = true;
      g_s2.touchTime = b.time;
      if(latest)
         Log(K_S2, StringFormat("TOUCH: low %.2f <= VWAP %.2f", b.low, vwap));
     }
   if(!(g_s2.touched && b.close > vwap))
      return;
   if(!latest)
      return;

   int cm = om + 1;
   if(cm >= SrvMin(InpS2_CutoffCT))
      return;
   if(DayBlocked(d))
      return;
   if(PosTicket(g_st[K_S2].magic) != 0)
      return;
   if(g_st[K_S2].trades >= InpS2_MaxTrades)
      return;

   double adx, adxPrev;
   if(!GetADX(g_hADX_M1, b.time, adx, adxPrev))
      return;
   if(!(adx > InpS2_ADXMin && adx <= adxPrev))
      return;   // keep waiting: ADX must be > min and not rising

   int need = (int)MathMax(InpS2_TPBars, InpS2_SLBars);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, PERIOD_M1, b.time, need, r) != need)
      return;
   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = need - InpS2_TPBars; i < need; i++)
      hh = MathMax(hh, r[i].high);
   for(int i = need - InpS2_SLBars; i < need; i++)
      ll = MathMin(ll, r[i].low);

   if(InpS2_TPMode == S2TP_PRETOUCH)
     {
      MqlRates t[];
      ArraySetAsSeries(t, false);
      if(CopyRates(_Symbol, PERIOD_M1, g_s2.touchTime, InpS2_TPBars, t) != InpS2_TPBars)
         return;
      hh = -DBL_MAX;
      for(int i = 0; i < InpS2_TPBars; i++)
         hh = MathMax(hh, t[i].high);
     }
   else
      if(InpS2_TPMode == S2TP_SWING)
         hh = g_s2.swingHigh;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(hh - ask < InpS2_MinTPPts)
     {
      Log(K_S2, StringFormat("SKIP: 5-bar high %.2f not above entry %.2f by %.1f", hh, ask, InpS2_MinTPPts));
      return;
     }
   Log(K_S2, StringFormat("SIGNAL close %.2f > VWAP %.2f, ADX %.1f <= prev %.1f; TP %.2f SL %.2f",
                          b.close, vwap, adx, adxPrev, hh, ll));
   if(OpenTrade(K_S2, true, true, ll, hh, InpS2_RiskPct, InpS2_FixedLots, InpS2_MaxSpreadPts))
     {
      g_s2.touched = false;   // a further trade (if allowed) needs a fresh VWAP touch
      g_s2.swingHigh = 0;
     }
  }

// Mode B: recalculate TP to the highest high of the last N bars every bar
void S2_ManageTP(const MqlRates &b)
  {
   if(InpS2_TPMode != S2TP_RECALC)
      return;
   ulong t = PosTicket(g_st[K_S2].magic);
   if(t == 0)
      return;
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, PERIOD_M1, b.time, InpS2_TPBars, r) != InpS2_TPBars)
      return;
   double hh = -DBL_MAX;
   for(int i = 0; i < InpS2_TPBars; i++)
      hh = MathMax(hh, r[i].high);
   hh = NormPrice(hh);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(hh <= bid + StopsLevelPrice())
     {
      // a sell limit at/below the market would fill immediately
      if(g_trade.PositionClose(t))
         Log(K_S2, StringFormat("EXIT: recalculated TP %.2f at/below bid %.2f", hh, bid));
      return;
     }
   if(MathAbs(hh - tp) >= TickSize())
      g_trade.PositionModify(t, sl, hh);
  }

//+------------------------------------------------------------------+
//| S3  Overnight Bias ORB                                           |
//+------------------------------------------------------------------+
void S3_OnBar(const MqlRates &b, bool latest)
  {
   datetime d = DayStart(b.time);
   EnsureDay(K_S3, b.time);
   if(g_s3.day != d)
     {
      g_s3.day = d;
      g_s3.onInit = false;
      g_s3.onH = 0;
      g_s3.onL = 0;
      g_s3.orDone = false;
      g_s3.bias = 0;
     }
   int om  = MinOfDay(b.time);
   int onS = SrvMin(InpS3_ONStartCT), op = SrvMin(InpS3_OpenCT);

   if(om >= onS && om < op)
     {
      if(!g_s3.onInit)
        {
         g_s3.onH = b.high;
         g_s3.onL = b.low;
         g_s3.onInit = true;
        }
      else
        {
         g_s3.onH = MathMax(g_s3.onH, b.high);
         g_s3.onL = MathMin(g_s3.onL, b.low);
        }
      return;
     }
   if(!g_s3.orDone)
     {
      if(om < op)
         return;
      // first bar at/after the cash open: bias + opening range
      g_s3.orDone = true;
      g_s3.orH = b.high;
      g_s3.orL = b.low;
      g_s3.bias = 0;
      double p = -1;
      if(g_s3.onInit && g_s3.onH > g_s3.onL)
        {
         p = (b.open - g_s3.onL) / (g_s3.onH - g_s3.onL);
         if(p > 2.0 / 3.0)
            g_s3.bias = 1;
         else
            if(p < 1.0 / 3.0)
               g_s3.bias = -1;
        }
      if(latest)
         Log(K_S3, StringFormat("BIAS %s: open %.2f in overnight range %.2f-%.2f (p=%.2f); OR %.2f-%.2f",
                                g_s3.bias == 1 ? "LONG" : (g_s3.bias == -1 ? "SHORT" : "NONE"),
                                b.open, g_s3.onL, g_s3.onH, p, g_s3.orL, g_s3.orH));
      return;
     }
   if(g_s3.bias == 0 || !latest)
      return;

   int cm = om + PeriodSeconds(PERIOD_M15) / 60;
   if(cm >= SrvMin(InpS3_CutoffCT))
      return;
   if(DayBlocked(d))
      return;
   if(g_st[K_S3].trades >= 1)
      return;
   if(PosTicket(g_st[K_S3].magic) != 0)
      return;

   bool longSig  = (g_s3.bias == 1 && InpS3_AllowLong && b.close > g_s3.orH);
   bool shortSig = (g_s3.bias == -1 && InpS3_AllowShort && b.close < g_s3.orL);
   if(!longSig && !shortSig)
      return;

   double adx, adxPrev;
   if(!GetADX(g_hADX_M15, b.time, adx, adxPrev))
      return;
   if(adx <= InpS3_ADXMin)
      return;
   double adr = GetADR(b.time);
   if(adr <= 0)
     {
      Log(K_S3, "SKIP: ADR unavailable");
      return;
     }
   double slPts = InpS3_SLFrac * adr;
   double tpPts = InpS3_TPMult * slPts;
   Log(K_S3, StringFormat("SIGNAL %s close %.2f beyond OR (%.2f-%.2f), ADX %.1f, ADR %.1f",
                          longSig ? "LONG" : "SHORT", b.close, g_s3.orL, g_s3.orH, adx, adr));
   OpenTrade(K_S3, longSig, false, slPts, tpPts, InpS3_RiskPct, InpS3_FixedLots, InpS3_MaxSpreadPts);
  }

//+------------------------------------------------------------------+
//| S4  Drift VWAP Pullback (Golden Ticket)                          |
//+------------------------------------------------------------------+
void S4_DayCheck(datetime t)
  {
   datetime d = DayStart(t);
   EnsureDay(K_S4, t);
   if(g_s4.day != d)
     {
      g_s4.day = d;
      VWReset(g_s4.vw);
      g_s4.trend = 0;
      g_s4.trendClose = 0;
     }
  }

// Trend state, evaluated at every M15 close
void S4_On15(const MqlRates &b)
  {
   S4_DayCheck(b.time);
   int om = MinOfDay(b.time);
   if(om < SrvMin(InpS4_VWAPAnchorCT))
     {
      g_s4.trend = 0;
      return;
     }
   VWAdd(g_s4.vw, b);
   g_s4.trend = 0;
   g_s4.trendClose = b.time + PeriodSeconds(PERIOD_M15);
   if(g_s4.vw.cnt < 2)
      return;

   int lb = InpS4_LookbackBars;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, PERIOD_M15, b.time, lb + 1, r) != lb + 1)
      return;
   if(r[0].close <= 0)
      return;
   double chg = (r[lb].close / r[0].close - 1.0) * 100.0;
   double vw = g_s4.vw.last, vwPrev = g_s4.vw.prev;

   if(b.close > vw && vw > vwPrev && chg >= InpS4_MinMovePct)
      g_s4.trend = 1;
   else
      if(b.close < vw && vw < vwPrev && chg <= -InpS4_MinMovePct)
         g_s4.trend = -1;
  }

// Trigger on M5 closes
void S4_On5(const MqlRates &b, bool latest)
  {
   S4_DayCheck(b.time);
   if(!latest)
      return;
   int om = MinOfDay(b.time);
   int cm = om + PeriodSeconds(PERIOD_M5) / 60;
   if(cm < SrvMin(InpS4_TradeStartCT) || cm >= SrvMin(InpS4_CutoffCT))
      return;
   datetime barClose = b.time + PeriodSeconds(PERIOD_M5);
   // trend must come from the latest M15 close at or before this M5 close
   if(g_s4.trend == 0 || !(g_s4.trendClose <= barClose && barClose < g_s4.trendClose + PeriodSeconds(PERIOD_M15)))
      return;
   if(DayBlocked(b.time))
      return;
   if(PosTicket(g_st[K_S4].magic) != 0)
      return;
   if(g_st[K_S4].trades >= InpS4_MaxTrades)
      return;
   if(InpS4_LossRule == S4LOSS_TOTAL && g_st[K_S4].losses >= InpS4_MaxLosses)
      return;
   if(InpS4_LossRule == S4LOSS_CONSECUTIVE && g_st[K_S4].consecLosses >= InpS4_MaxLosses)
      return;

   bool longSig  = (g_s4.trend == 1 && InpS4_AllowLong && b.close < b.open);   // first red candle
   bool shortSig = (g_s4.trend == -1 && InpS4_AllowShort && b.close > b.open); // first green candle
   if(!longSig && !shortSig)
      return;

   double f = 1.0;
   if(InpS4_ScaleWithADR && InpS4_RefADR > 0)
     {
      double adr = GetADR(b.time);
      if(adr <= 0)
        {
         Log(K_S4, "SKIP: ADR unavailable");
         return;
        }
      f = adr / InpS4_RefADR;
     }
   Log(K_S4, StringFormat("SIGNAL %s: trend %d, M15 VWAP %.2f, pullback candle O %.2f C %.2f, exit scale %.2f",
                          longSig ? "LONG" : "SHORT", g_s4.trend, g_s4.vw.last, b.open, b.close, f));
   if(longSig)
      OpenTrade(K_S4, true, false, InpS4_LongSLPts * f, InpS4_LongTPPts * f, InpS4_RiskPct, InpS4_FixedLots, InpS4_MaxSpreadPts);
   else
      OpenTrade(K_S4, false, false, InpS4_ShortSLPts * f, InpS4_ShortTPPts * f, InpS4_RiskPct, InpS4_FixedLots, InpS4_MaxSpreadPts);
  }

//+------------------------------------------------------------------+
//| CSV export                                                       |
//+------------------------------------------------------------------+
string FileName(string kind)
  {
   string tag = (InpRunTag != "") ? "_" + InpRunTag : "";
   return InpFilePrefix + tag + "_" + kind + ".csv";
  }

double ParseRisk(string c)
  {
   int p = StringFind(c, " R");
   if(p < 0)
      return 0;
   return StringToDouble(StringSubstr(c, p + 2));
  }

string ReasonStr(long r)
  {
   if(r == DEAL_REASON_SL)
      return "SL";
   if(r == DEAL_REASON_TP)
      return "TP";
   if(r == DEAL_REASON_EXPERT)
      return "EA";
   if(r == DEAL_REASON_SO)
      return "STOPOUT";
   if(r == DEAL_REASON_CLIENT || r == DEAL_REASON_MOBILE || r == DEAL_REASON_WEB)
      return "MANUAL";
   return "OTHER";
  }

void WriteTradeLog()
  {
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return;
   int total = HistoryDealsTotal();
   long  inPid[];
   ulong inTk[];
   ArrayResize(inPid, total);
   ArrayResize(inTk, total);
   int nin = 0;
   for(int i = 0; i < total; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      inPid[nin] = HistoryDealGetInteger(t, DEAL_POSITION_ID);
      inTk[nin]  = t;
      nin++;
     }

   string fn = FileName("trades");
   int fh = FileOpen(fn, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE)
     {
      Print("Cannot open ", fn, " err=", GetLastError());
      return;
     }
   FileWrite(fh, "strategy", "direction", "open_time", "close_time", "open_time_ct", "volume",
             "entry_price", "exit_price", "points", "risk_points", "r_multiple", "profit", "exit_reason");
   int rows = 0;
   for(int i = 0; i < total; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      long e = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol)
         continue;
      long pid = HistoryDealGetInteger(t, DEAL_POSITION_ID);
      ulong it = 0;
      for(int j = 0; j < nin; j++)
         if(inPid[j] == pid)
           {
            it = inTk[j];
            break;
           }
      if(it == 0)
         continue;
      string tag = TagOfMagic(HistoryDealGetInteger(it, DEAL_MAGIC));
      if(tag == "")
         continue;
      bool isLong = (HistoryDealGetInteger(it, DEAL_TYPE) == DEAL_TYPE_BUY);
      double ep = HistoryDealGetDouble(it, DEAL_PRICE);
      double xp = HistoryDealGetDouble(t, DEAL_PRICE);
      double pts = isLong ? xp - ep : ep - xp;
      double risk = ParseRisk(HistoryDealGetString(it, DEAL_COMMENT));
      double rm = (risk > 0) ? pts / risk : 0;
      double pl = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) +
                  HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(it, DEAL_COMMISSION);
      datetime ot = (datetime)HistoryDealGetInteger(it, DEAL_TIME);
      datetime ct = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      FileWrite(fh, tag, isLong ? "long" : "short",
                TimeToString(ot, TIME_DATE | TIME_SECONDS),
                TimeToString(ct, TIME_DATE | TIME_SECONDS),
                TimeToString(ot - InpServerMinusCT * 3600, TIME_DATE | TIME_SECONDS),
                DoubleToString(HistoryDealGetDouble(t, DEAL_VOLUME), 2),
                DoubleToString(ep, _Digits), DoubleToString(xp, _Digits),
                DoubleToString(pts, 2), DoubleToString(risk, 2), DoubleToString(rm, 4),
                DoubleToString(pl, 2), ReasonStr(HistoryDealGetInteger(t, DEAL_REASON)));
      rows++;
     }
   FileClose(fh);
   Print("Trade log: ", rows, " trades -> Common\\Files\\", fn);
  }

void WriteADRLog()
  {
   int n = ArraySize(g_adrLogDay);
   if(n == 0)
      return;
   string fn = FileName("adr");
   int fh = FileOpen(fn, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE)
      return;
   FileWrite(fh, "date", "adr");
   for(int i = 0; i < n; i++)
      FileWrite(fh, TimeToString(g_adrLogDay[i], TIME_DATE), DoubleToString(g_adrLogVal[i], 2));
   FileClose(fh);
  }

//+------------------------------------------------------------------+
//| Init / deinit                                                    |
//+------------------------------------------------------------------+
void InitStrat(int k, string name, long magic)
  {
   g_st[k].name = name;
   g_st[k].magic = magic;
   g_st[k].day = 0;
   g_st[k].trades = 0;
   g_st[k].losses = 0;
   g_st[k].consecLosses = 0;
   g_st[k].trackedPosId = 0;
   ulong t = PosTicket(magic);          // re-track an open position after a restart
   if(t > 0)
      g_st[k].trackedPosId = PositionGetInteger(POSITION_IDENTIFIER);
  }

bool CheckTime(int v, string name)
  {
   if(ValidHHMM(v))
      return true;
   Print("Invalid HHMM input ", name, " = ", v);
   return false;
  }

// Same-day times must fall before 16:00 CT (the server-day boundary)
bool CheckSameDay(int v, string name)
  {
   if(!CheckTime(v, name))
      return false;
   if(v >= 1600)
     {
      Print(name, " must be before 16:00 CT (server day boundary)");
      return false;
     }
   return true;
  }

int OnInit()
  {
   if(!CheckTime(InpS1_AnchorCT, "S1 Anchor") || !CheckSameDay(InpS1_WindowStartCT, "S1 WindowStart") ||
      !CheckSameDay(InpS1_WindowEndCT, "S1 WindowEnd") || !CheckSameDay(InpS1_ExitCT, "S1 Exit") ||
      !CheckSameDay(InpS2_ORStartCT, "S2 ORStart") || !CheckSameDay(InpS2_OREndCT, "S2 OREnd") ||
      !CheckTime(InpS2_VWAPAnchorCT, "S2 VWAPAnchor") || !CheckSameDay(InpS2_CutoffCT, "S2 Cutoff") ||
      !CheckSameDay(InpS2_ExitCT, "S2 Exit") || !CheckTime(InpS3_ONStartCT, "S3 ONStart") ||
      !CheckSameDay(InpS3_OpenCT, "S3 Open") || !CheckSameDay(InpS3_CutoffCT, "S3 Cutoff") ||
      !CheckSameDay(InpS3_ExitCT, "S3 Exit") || !CheckTime(InpS4_VWAPAnchorCT, "S4 VWAPAnchor") ||
      !CheckSameDay(InpS4_TradeStartCT, "S4 TradeStart") || !CheckSameDay(InpS4_CutoffCT, "S4 Cutoff") ||
      !CheckSameDay(InpS4_ExitCT, "S4 Exit"))
      return INIT_PARAMETERS_INCORRECT;
   if(InpS2_TPBars < 1 || InpS2_SLBars < 1 || InpS4_LookbackBars < 1 || InpADRDays < 1 || InpATRPeriod < 1)
      return INIT_PARAMETERS_INCORRECT;

   if(InpS1_Magic == InpS2_Magic || InpS1_Magic == InpS3_Magic || InpS1_Magic == InpS4_Magic ||
      InpS2_Magic == InpS3_Magic || InpS2_Magic == InpS4_Magic || InpS3_Magic == InpS4_Magic)
     {
      Print("Magic numbers must be unique");
      return INIT_PARAMETERS_INCORRECT;
     }

   InitStrat(K_S1, "S1", InpS1_Magic);
   InitStrat(K_S2, "S2", InpS2_Magic);
   InitStrat(K_S3, "S3", InpS3_Magic);
   InitStrat(K_S4, "S4", InpS4_Magic);
   g_s1.day = 0;
   g_s2.day = 0;
   g_s3.day = 0;
   g_s4.day = 0;

   if(InpS2_Enable)
     {
      g_hADX_M1 = iADXWilder(_Symbol, PERIOD_M1, InpADXPeriod);
      if(g_hADX_M1 == INVALID_HANDLE)
        {
         Print("Failed to create M1 ADX");
         return INIT_FAILED;
        }
     }
   if(InpS3_Enable)
     {
      g_hADX_M15 = iADXWilder(_Symbol, PERIOD_M15, InpADXPeriod);
      if(g_hADX_M15 == INVALID_HANDLE)
        {
         Print("Failed to create M15 ADX");
         return INIT_FAILED;
        }
     }

   g_trade.SetDeviationInPoints(InpDeviationPts);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   // persistent state (initial balance, halt flag)
   g_gv = InpFilePrefix + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_";
   if(InpInitialBalance > 0)
      g_initBal = InpInitialBalance;
   else
      if(GlobalVariableCheck(g_gv + "initbal"))
         g_initBal = GlobalVariableGet(g_gv + "initbal");
      else
        {
         g_initBal = AccountInfoDouble(ACCOUNT_BALANCE);
         GlobalVariableSet(g_gv + "initbal", g_initBal);
        }
   if(InpResetHalt)
     {
      GlobalVariableDel(g_gv + "halt");
      GlobalVariableDel(g_gv + "hwm");   // restart the trailing drawdown from current equity
     }
   if(InpProfile == PROFILE_LIVE && InpLiveTrailDDPct > 0)
     {
      if(GlobalVariableCheck(g_gv + "hwm"))
         g_hwm = GlobalVariableGet(g_gv + "hwm");
      g_hwm = MathMax(g_hwm, AccountInfoDouble(ACCOUNT_EQUITY));
      GlobalVariableSet(g_gv + "hwm", g_hwm);
     }
   g_halted = (InpProfile != PROFILE_RESEARCH && GlobalVariableCheck(g_gv + "halt"));

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: account is not a hedging account; strategies may net against each other.");

   PrintFormat("NQ Portfolio EA on %s | profile %s | initial balance %.2f | floor %.2f | target %.2f | equity high %.2f | halted=%s",
               _Symbol, EnumToString(InpProfile), g_initBal, FloorLevel(), TargetLevel(), g_hwm, g_halted ? "YES" : "no");
   PrintFormat("Time map (server = CT + %d h): 00:00 CT=%02d:%02d, 08:30 CT=%02d:%02d, 14:30 CT=%02d:%02d",
               InpServerMinusCT, SrvMin(0) / 60, SrvMin(0) % 60, SrvMin(830) / 60, SrvMin(830) % 60,
               SrvMin(1430) / 60, SrvMin(1430) % 60);
   PrintFormat("Symbol: value per point per lot %.4f %s, min lot %.2f, step %.2f, stops level %.2f",
               ValuePerPointPerLot(), AccountInfoString(ACCOUNT_CURRENCY),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               StopsLevelPrice());
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   WriteTradeLog();
   WriteADRLog();
   if(g_hADX_M1 != INVALID_HANDLE)
      IndicatorRelease(g_hADX_M1);
   if(g_hADX_M15 != INVALID_HANDLE)
      IndicatorRelease(g_hADX_M15);
  }

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   for(int k = 0; k < NSTRAT; k++)
      CheckClosed(k);

   CheckGuards();
   if(g_halted)
      return;

   if(InpS1_Enable)
      TimeExit(K_S1, InpS1_ExitCT, now);
   if(InpS2_Enable)
      TimeExit(K_S2, InpS2_ExitCT, now);
   if(InpS3_Enable)
      TimeExit(K_S3, InpS3_ExitCT, now);
   if(InpS4_Enable)
      TimeExit(K_S4, InpS4_ExitCT, now);

   MqlRates r[];
   int n;

   if(InpS1_Enable)
     {
      n = GetNewBars(PERIOD_M30, g_cur30, r);
      for(int i = 0; i < n; i++)
         S1_OnBar(r[i], i == n - 1 && IsFresh(r[i], PERIOD_M30));
     }

   if(InpS2_Enable)
     {
      n = GetNewBars(PERIOD_M1, g_cur1, r);
      for(int i = 0; i < n; i++)
         S2_OnBar(r[i], i == n - 1 && IsFresh(r[i], PERIOD_M1));
      if(n > 0)
         S2_ManageTP(r[n - 1]);
     }

   if(InpS3_Enable)
     {
      n = GetNewBars(PERIOD_M15, g_cur15s3, r);
      for(int i = 0; i < n; i++)
         S3_OnBar(r[i], i == n - 1 && IsFresh(r[i], PERIOD_M15));
     }

   if(InpS4_Enable)
     {
      // M15 trend first, so an M5 bar closing at the same moment sees the fresh state
      n = GetNewBars(PERIOD_M15, g_cur15s4, r);
      for(int i = 0; i < n; i++)
         S4_On15(r[i]);
      n = GetNewBars(PERIOD_M5, g_cur5, r);
      for(int i = 0; i < n; i++)
         S4_On5(r[i], i == n - 1 && IsFresh(r[i], PERIOD_M5));
     }
  }
//+------------------------------------------------------------------+
