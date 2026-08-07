//+------------------------------------------------------------------+
//| OrderFlow_VWAP_EA.mq5                                            |
//| Order Flow + VWAP + Volume Profile Strategy                       |
//+------------------------------------------------------------------+
#property copyright "Order Flow VWAP Strategy"
#property version   "2.51"
#property description "Volume Profile with HVN/LVN/POC, VWAP, Delta Volume"
#property description "v2.51: Day-of-week and blocked-hour filters"

#include <Trade\Trade.mqh>

enum ENUM_DELTA_METHOD
{
   DELTA_AUTO,       // Auto-detect
   DELTA_TICK_FLAGS, // Tick flags (exchange)
   DELTA_TICK_RULE   // Tick rule (CFD/Forex)
};

enum ENUM_SL_MODE
{
   SL_COMPOSITE,     // Furthest of: next LVN, VA boundary, prior POC
   SL_BEYOND_LVN,    // Beyond next LVN (opposite direction)
   SL_BEYOND_VA,     // Beyond Value Area boundary
   SL_PRIOR_POC,     // Beyond prior session POC
   SL_FIXED          // Fixed distance (price units)
};

enum ENUM_TP_MODE
{
   TP_FIXED,         // Fixed points
   TP_NEXT_LVN,      // Next LVN in trade direction
   TP_NEXT_HVN,      // Next HVN in trade direction
   TP_MULTI_TARGET   // TP1 at LVN (partial), TP2 at next HVN/POC
};

//--- Inputs
input group "=== General ==="
input ulong          InpMagic            = 100001;      // Magic Number
input string         InpComment          = "OF_VWAP";   // Trade Comment

input group "=== Session (Server Time) ==="
input int            InpSessionStartHour = 15;          // Session Start Hour
input int            InpSessionStartMin  = 30;          // Session Start Minute
input int            InpSessionEndHour   = 22;          // Session End Hour
input int            InpSessionEndMin    = 0;           // Session End Minute

input group "=== Volume Profile ==="
input double         InpPriceStep        = 1.0;         // Price Step per Level (price units)
input int            InpSmoothPeriod     = 3;           // Smoothing Window (levels)
input int            InpPeakLookback     = 3;           // Peak/Valley Lookback (levels)
input int            InpDaysBack         = 5;           // Prior Days to Analyze
input int            InpValueAreaPct     = 70;          // Value Area %
input ENUM_DELTA_METHOD InpDeltaMethod   = DELTA_AUTO;  // Delta Classification

input group "=== Visualization ==="
input bool           InpDrawProfiles     = true;        // Draw Profiles on Chart
input bool           InpDrawCurrentLive  = true;        // Live-update Current Session
input double         InpProfileWidthPct  = 25.0;        // Max Profile Width (% of session width)
input color          InpHVNColor         = clrDodgerBlue; // HVN Color
input color          InpLVNColor         = clrOrangeRed;   // LVN Color
input color          InpPOCColor         = clrGold;        // POC Color
input color          InpVAColor          = clrSlateGray;   // Value Area Fill Color
input color          InpNormalColor      = clrDarkGray;    // Normal Level Color
input color          InpVWAPColor        = clrMagenta;     // VWAP Color
input int            InpVWAPWidth        = 2;              // VWAP Line Width
input color          InpPOCLineColor     = clrGoldenrod;   // Prior POC Extension Color
input ENUM_LINE_STYLE InpPOCLineStyle    = STYLE_DASH;    // Prior POC Line Style

input group "=== CSV Export ==="
input bool           InpExportCSV        = true;        // Export Profiles to CSV
input string         InpCSVFolder        = "OrderFlow"; // CSV Subfolder

input group "=== Trading ==="
input bool           InpEnableTrading    = false;       // Enable Auto Trading
input double         InpLotSize          = 0.1;         // Lot Size (fixed)
input double         InpRiskPercent      = 0.0;         // Risk % (0=fixed lot)
input int            InpMaxTradesPerDay  = 3;           // Max Trades Per Session

input group "=== Confluence Scoring ==="
input int            InpMinScore         = 4;           // Min Score to Enter (max ~6)
input int            InpPriorPOCWeight   = 2;           // Prior POC Score Weight (0-2)
input bool           InpVwapPrereq       = true;        // VWAP Alignment Required (not scored)
input bool           InpDeltaRocPrereq   = true;        // Delta ROC Required (not scored)
input bool           InpPriorHvnPrereq   = true;        // Prior HVN Required (not scored)
input double         InpProximitySteps   = 10.0;        // Proximity for Prior Levels (price steps)
input int            InpDeltaRocSeconds  = 30;          // Delta ROC Lookback (seconds)
input double         InpDeltaRocMin      = 5.0;         // Min Delta ROC for +1 Score
input double         InpMinBarVolRatio   = 1.2;         // Min Volume Ratio vs Average

input group "=== Active Trading Window ==="
input int            InpActiveStartHour  = 16;          // Active Window Start Hour
input int            InpActiveStartMin   = 30;          // Active Window Start Minute
input int            InpActiveEndHour    = 19;          // Active Window End Hour
input int            InpActiveEndMin     = 0;           // Active Window End Minute

input group "=== Day & Time Filters ==="
input string         InpBlockedDays      = "1";         // Blocked Days (0=Sun,1=Mon..6=Sat, comma-sep)
input int            InpBlockedHourStart = 15;           // Blocked Hour Start (-1 = off)
input int            InpBlockedHourEnd   = 15;           // Blocked Hour End (inclusive, same = single hour)

input group "=== Stop Loss ==="
input ENUM_SL_MODE   InpSLMode           = SL_COMPOSITE; // SL Placement Mode
input double         InpSLFallback       = 30.0;        // Fallback SL (price units, if no level)
input double         InpSLPadding        = 2.0;         // SL Padding Beyond Level (price units)
input double         InpMaxSL            = 80.0;        // Max SL Distance (price units)
input double         InpMinSL            = 10.0;        // Min SL Distance (price units)

input group "=== Take Profit ==="
input ENUM_TP_MODE   InpTPMode           = TP_MULTI_TARGET; // TP Mode
input double         InpTPFallback       = 40.0;        // Fallback TP (price units, if no level)
input double         InpMinTP            = 15.0;        // Min TP Distance (price units)
input double         InpMinRR            = 1.0;         // Min Reward:Risk Ratio
input double         InpPartialClosePct  = 50.0;        // % to Close at TP1

input group "=== Trailing Stop ==="
input bool           InpUseTrailing      = true;        // Trail Stop to Cleared HVNs
input double         InpTrailPadding     = 5.0;         // Trail Padding Beyond HVN (price units)
input double         InpTrailMinPct      = 50.0;        // Min Trail Dist (% of SL) Before TP1

input group "=== Breakeven ==="
input bool           InpUseBE            = true;        // Enable ATR Breakeven
input int            InpBE_ATR_Period    = 10;          // ATR Period
input double         InpBE_ATR_Multi     = 1.0;         // ATR Multiplier (move BE when price travels this x ATR)
input double         InpBE_Offset        = 1.0;         // BE Offset (price units, 0 = exact entry)

input group "=== Signal Log ==="
input bool           InpSignalLog        = true;        // Log Signals to CSV
input bool           InpLogTradesOnly    = true;        // Log Only Executed Trades (vs all evals)
input string         InpSignalLogFolder  = "OrderFlow"; // Signal Log Subfolder

input group "=== Cooldown ==="
input int            InpCooldownSeconds  = 600;         // Seconds Before Re-entry at Same Zone
input double         InpCooldownZoneSize = 3.0;         // Zone Size (price steps)
input int            InpGlobalCooldown   = 600;         // Min Seconds Between Any Two Trades

//--- Structures
struct PriceLevel
{
   double price;
   double totalVol;
   double buyVol;
   double sellVol;
   double smoothedVol;
   bool   isHVN;
   bool   isLVN;
   bool   isPOC;
   bool   inVA;
};

struct DailyProfile
{
   datetime sessionDate;
   datetime sessionStart;
   datetime sessionEnd;
   PriceLevel levels[];
   int        levelCount;
   int        pocIndex;
   double     pocPrice;
   double     vahPrice;
   double     valPrice;
   double     vwap;
   double     totalVolume;
   double     totalDelta;
   bool       isValid;
};

struct TradedZone
{
   double price;
   datetime time;
};

struct DeltaSnapshot
{
   double delta;
   datetime time;
};

//--- Globals
CTrade         g_trade;
DailyProfile   g_priorProfiles[];
DailyProfile   g_currentProfile;
double         g_vwap;
double         g_cumPV;
double         g_cumVol;
double         g_cumDelta;
datetime       g_todaySessionStart;
datetime       g_todaySessionEnd;
datetime       g_lastCalcTime;
bool           g_useTickFlags;
string         g_objPrefix;

// Confluence & filter state
DeltaSnapshot  g_deltaSnaps[200];
int            g_deltaSnapCount;
int            g_deltaSnapIdx;
TradedZone     g_tradedZones[50];
int            g_tradedZoneCount;
int            g_tradesToday;
datetime       g_lastTradeDay;

// Position management
ulong          g_managedTicket;
int            g_managedDir;       // 1=long, -1=short
double         g_tp2Price;
bool           g_tp1Hit;
double         g_lastTrailPrice;
bool           g_beApplied;
datetime       g_lastTradeTime;

// Entry details for win/loss logging
double         g_entryPrice;
double         g_entrySL;
double         g_currentSL;
double         g_entryTP1;
double         g_entryTP2;
int            g_entryScore;
int            g_entryVwap, g_entryHvn, g_entryPPoc, g_entryPVa, g_entryPHvn;
int            g_entryDelta, g_entryRoc, g_entryVol;

// ATR handle
int            g_atrHandle;

// Signal log
int            g_signalLogHandle;
bool           g_signalLogHeaderWritten;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_objPrefix = "OFVWAP_";
   g_lastCalcTime = 0;

   if(InpPriceStep <= 0)
   {
      Print("Price step must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_useTickFlags = ShouldUseTickFlags();

   GetSessionTimes(TimeCurrent(), g_todaySessionStart, g_todaySessionEnd);

   ArrayResize(g_priorProfiles, InpDaysBack);
   BuildPriorProfiles();

   if(InpDrawProfiles)
      DrawAllPriorProfiles();

   if(InpExportCSV)
      ExportAllProfiles();

   // Initialize filter state
   g_deltaSnapCount = 0;
   g_deltaSnapIdx   = 0;
   g_tradedZoneCount = 0;
   g_tradesToday    = 0;
   g_lastTradeDay   = 0;
   g_managedTicket  = 0;
   g_managedDir     = 0;
   g_tp2Price       = 0;
   g_tp1Hit         = false;
   g_lastTrailPrice = 0;
   g_beApplied      = false;
   g_lastTradeTime  = 0;
   g_entryPrice     = 0;
   g_currentSL      = 0;

   // ATR indicator
   g_atrHandle = INVALID_HANDLE;
   if(InpUseBE)
   {
      g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpBE_ATR_Period);
      if(g_atrHandle == INVALID_HANDLE)
         Print("Warning: failed to create ATR indicator");
   }

   // Signal log file
   g_signalLogHandle = INVALID_HANDLE;
   g_signalLogHeaderWritten = false;
   if(InpSignalLog)
      OpenSignalLog();

   EventSetMillisecondTimer(3000);

   Print("OrderFlow VWAP EA v2.51 initialized. Delta method: ",
         g_useTickFlags ? "Tick Flags" : "Tick Rule",
         " | Min score: ", InpMinScore,
         " | Prereqs: VWAP=", InpVwapPrereq,
         " ROC=", InpDeltaRocPrereq,
         " HVN=", InpPriorHvnPrereq,
         " | BlockedDays=", InpBlockedDays,
         " BlockedHour=", InpBlockedHourStart < 0 ? "off" :
            IntegerToString(InpBlockedHourStart) + "-" + IntegerToString(InpBlockedHourEnd));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   RemoveAllObjects();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_signalLogHandle != INVALID_HANDLE)
      FileClose(g_signalLogHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!InpEnableTrading) return;

   datetime now = TimeCurrent();
   if(now < g_todaySessionStart || now > g_todaySessionEnd) return;

   if(!g_currentProfile.isValid) return;

   // Detect position close for win/loss logging
   if(g_managedTicket > 0 && !PositionSelectByTicket(g_managedTicket))
   {
      if(InpSignalLog)
         LogTradeClose(g_managedTicket);
      g_managedTicket = 0;
      g_managedDir    = 0;
      g_tp1Hit        = false;
   }

   if(InpUseBE && g_managedTicket > 0 && !g_beApplied)
      CheckBreakeven();

   if(InpUseTrailing && g_managedTicket > 0)
      ManageTrailingStop();

   if(InpTPMode == TP_MULTI_TARGET && g_managedTicket > 0 && !g_tp1Hit)
      CheckTP1PartialClose();

   CheckSignals();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeCurrent();

   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);
   datetime todayStart, todayEnd;
   GetSessionTimes(now, todayStart, todayEnd);

   if(todayStart != g_todaySessionStart)
   {
      g_todaySessionStart = todayStart;
      g_todaySessionEnd   = todayEnd;
      g_tradedZoneCount   = 0;
      g_tradesToday       = 0;
      g_deltaSnapCount    = 0;
      g_deltaSnapIdx      = 0;
      BuildPriorProfiles();
      if(InpDrawProfiles) DrawAllPriorProfiles();
      if(InpExportCSV) ExportAllProfiles();
   }

   if(now >= g_todaySessionStart && now <= g_todaySessionEnd)
   {
      if(now - g_lastCalcTime >= 3)
      {
         BuildProfileFromTicks(g_todaySessionStart, now, g_currentProfile);
         if(g_currentProfile.isValid)
         {
            CalculateVWAP(g_todaySessionStart, now);
            g_currentProfile.vwap = g_vwap;

            RecordDeltaSnapshot(g_cumDelta, now);

            if(InpDrawCurrentLive)
            {
               RemoveObjectsWithPrefix(g_objPrefix + "CUR_");
               DrawSingleProfile(g_currentProfile, "CUR_");
               DrawVWAPLine();
            }

            if(InpExportCSV)
               ExportSingleProfile(g_currentProfile, "LIVE");
         }
         g_lastCalcTime = now;
      }
   }
}

//+------------------------------------------------------------------+
//| Session time helpers                                              |
//+------------------------------------------------------------------+
void GetSessionTimes(datetime refTime, datetime &start, datetime &end)
{
   MqlDateTime dt;
   TimeToStruct(refTime, dt);
   dt.hour = InpSessionStartHour;
   dt.min  = InpSessionStartMin;
   dt.sec  = 0;
   start = StructToTime(dt);
   dt.hour = InpSessionEndHour;
   dt.min  = InpSessionEndMin;
   end = StructToTime(dt);
}

datetime GetTradingDay(datetime from, int daysBack)
{
   datetime result = from;
   int count = 0;
   while(count < daysBack)
   {
      result -= 86400;
      MqlDateTime dt;
      TimeToStruct(result, dt);
      if(dt.day_of_week >= 1 && dt.day_of_week <= 5)
         count++;
   }
   return result;
}

//+------------------------------------------------------------------+
//| Delta method detection                                           |
//+------------------------------------------------------------------+
bool ShouldUseTickFlags()
{
   if(InpDeltaMethod == DELTA_TICK_FLAGS) return true;
   if(InpDeltaMethod == DELTA_TICK_RULE)  return false;

   MqlTick ticks[];
   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_TRADE, 0, 100);
   if(copied <= 0) return false;

   for(int i = 0; i < copied; i++)
   {
      if((ticks[i].flags & TICK_FLAG_BUY) != 0 || (ticks[i].flags & TICK_FLAG_SELL) != 0)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Build prior day profiles                                         |
//+------------------------------------------------------------------+
void BuildPriorProfiles()
{
   for(int d = 0; d < InpDaysBack; d++)
   {
      datetime dayRef = GetTradingDay(g_todaySessionStart, d + 1);
      datetime sessStart, sessEnd;
      GetSessionTimes(dayRef, sessStart, sessEnd);

      g_priorProfiles[d].sessionStart = sessStart;
      g_priorProfiles[d].sessionEnd   = sessEnd;
      g_priorProfiles[d].sessionDate  = dayRef;

      BuildProfileFromTicks(sessStart, sessEnd, g_priorProfiles[d]);

      if(g_priorProfiles[d].isValid)
      {
         CalculateVWAPForRange(sessStart, sessEnd, g_priorProfiles[d].vwap);

         MqlDateTime dtDay;
         TimeToStruct(dayRef, dtDay);
         Print("Profile built for ", dtDay.year, "-",
               StringFormat("%02d", dtDay.mon), "-",
               StringFormat("%02d", dtDay.day),
               " | POC: ", g_priorProfiles[d].pocPrice,
               " | VAH: ", g_priorProfiles[d].vahPrice,
               " | VAL: ", g_priorProfiles[d].valPrice,
               " | Delta: ", g_priorProfiles[d].totalDelta,
               " | Levels: ", g_priorProfiles[d].levelCount);
      }
   }
}

//+------------------------------------------------------------------+
//| Build volume profile from tick data                               |
//+------------------------------------------------------------------+
void BuildProfileFromTicks(datetime start, datetime end, DailyProfile &profile)
{
   profile.isValid = false;

   MqlTick ticks[];
   ulong startMs = (ulong)start * 1000;
   ulong endMs   = (ulong)end * 1000;

   int copied = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, startMs, endMs);
   if(copied < 10)
   {
      Print("Insufficient ticks for ", TimeToString(start), " - ", TimeToString(end),
            " (got ", copied, ")");
      return;
   }

   double minPrice = DBL_MAX, maxPrice = -DBL_MAX;
   for(int i = 0; i < copied; i++)
   {
      double mid = (ticks[i].bid + ticks[i].ask) / 2.0;
      if(mid < minPrice) minPrice = mid;
      if(mid > maxPrice) maxPrice = mid;
   }

   double basePrice = MathFloor(minPrice / InpPriceStep) * InpPriceStep;
   double topPrice  = MathCeil(maxPrice / InpPriceStep) * InpPriceStep;
   int numLevels = (int)MathRound((topPrice - basePrice) / InpPriceStep) + 1;

   if(numLevels < 3 || numLevels > 5000)
   {
      Print("Invalid level count: ", numLevels, " for range ",
            minPrice, " - ", maxPrice);
      return;
   }

   ArrayResize(profile.levels, numLevels);
   profile.levelCount = numLevels;
   profile.totalVolume = 0;
   profile.totalDelta = 0;

   for(int i = 0; i < numLevels; i++)
   {
      profile.levels[i].price       = basePrice + i * InpPriceStep;
      profile.levels[i].totalVol    = 0;
      profile.levels[i].buyVol      = 0;
      profile.levels[i].sellVol     = 0;
      profile.levels[i].smoothedVol = 0;
      profile.levels[i].isHVN       = false;
      profile.levels[i].isLVN       = false;
      profile.levels[i].isPOC       = false;
      profile.levels[i].inVA        = false;
   }

   double prevMid = (ticks[0].bid + ticks[0].ask) / 2.0;

   for(int i = 1; i < copied; i++)
   {
      double mid = (ticks[i].bid + ticks[i].ask) / 2.0;
      int levelIdx = (int)MathRound((mid - basePrice) / InpPriceStep);
      if(levelIdx < 0 || levelIdx >= numLevels) continue;

      double vol = GetTickVolume(ticks[i]);
      int direction = ClassifyTick(ticks[i], prevMid, mid);

      profile.levels[levelIdx].totalVol += vol;
      if(direction > 0)
         profile.levels[levelIdx].buyVol += vol;
      else if(direction < 0)
         profile.levels[levelIdx].sellVol += vol;
      else
      {
         profile.levels[levelIdx].buyVol  += vol * 0.5;
         profile.levels[levelIdx].sellVol += vol * 0.5;
      }

      profile.totalVolume += vol;
      prevMid = mid;
   }

   for(int i = 0; i < numLevels; i++)
      profile.totalDelta += (profile.levels[i].buyVol - profile.levels[i].sellVol);

   SmoothProfile(profile);
   DetectNodes(profile);
   CalculateValueArea(profile);

   profile.isValid = true;
}

//+------------------------------------------------------------------+
double GetTickVolume(const MqlTick &tick)
{
   if(tick.volume > 0)      return (double)tick.volume;
   if(tick.volume_real > 0) return tick.volume_real;
   return 1.0;
}

//+------------------------------------------------------------------+
int ClassifyTick(const MqlTick &tick, double prevMid, double curMid)
{
   if(g_useTickFlags)
   {
      if((tick.flags & TICK_FLAG_BUY) != 0)  return 1;
      if((tick.flags & TICK_FLAG_SELL) != 0) return -1;
   }

   if(curMid > prevMid) return 1;
   if(curMid < prevMid) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Smooth the volume profile across price levels                     |
//+------------------------------------------------------------------+
void SmoothProfile(DailyProfile &profile)
{
   if(InpSmoothPeriod < 2)
   {
      for(int i = 0; i < profile.levelCount; i++)
         profile.levels[i].smoothedVol = profile.levels[i].totalVol;
      return;
   }

   int half = InpSmoothPeriod / 2;

   for(int i = 0; i < profile.levelCount; i++)
   {
      double sum = 0;
      int count = 0;
      int lo = MathMax(0, i - half);
      int hi = MathMin(profile.levelCount - 1, i + half);
      for(int j = lo; j <= hi; j++)
      {
         sum += profile.levels[j].totalVol;
         count++;
      }
      profile.levels[i].smoothedVol = (count > 0) ? sum / count : 0;
   }
}

//+------------------------------------------------------------------+
//| Detect HVN (local maxima) and LVN (local minima)                 |
//+------------------------------------------------------------------+
void DetectNodes(DailyProfile &profile)
{
   if(profile.levelCount < 3) return;

   int lb = InpPeakLookback;

   double maxSmoothed = 0;
   profile.pocIndex = 0;

   for(int i = 0; i < profile.levelCount; i++)
   {
      if(profile.levels[i].smoothedVol > maxSmoothed)
      {
         maxSmoothed = profile.levels[i].smoothedVol;
         profile.pocIndex = i;
      }
   }

   profile.levels[profile.pocIndex].isPOC = true;
   profile.pocPrice = profile.levels[profile.pocIndex].price;

   for(int i = lb; i < profile.levelCount - lb; i++)
   {
      bool isMax = true;
      bool isMin = true;
      double sv = profile.levels[i].smoothedVol;

      if(sv <= 0) { isMax = false; isMin = false; }

      for(int j = 1; j <= lb && (isMax || isMin); j++)
      {
         if(profile.levels[i - j].smoothedVol >= sv) isMax = false;
         if(profile.levels[i + j].smoothedVol >= sv) isMax = false;
         if(profile.levels[i - j].smoothedVol <= sv) isMin = false;
         if(profile.levels[i + j].smoothedVol <= sv) isMin = false;
      }

      if(isMax && i != profile.pocIndex)
         profile.levels[i].isHVN = true;
      if(isMin)
         profile.levels[i].isLVN = true;
   }
}

//+------------------------------------------------------------------+
//| Calculate Value Area (expand from POC until target % reached)     |
//+------------------------------------------------------------------+
void CalculateValueArea(DailyProfile &profile)
{
   if(profile.levelCount < 3 || profile.totalVolume <= 0) return;

   double targetVol = profile.totalVolume * InpValueAreaPct / 100.0;

   int upper = profile.pocIndex;
   int lower = profile.pocIndex;
   double vaVol = profile.levels[profile.pocIndex].totalVol;
   profile.levels[profile.pocIndex].inVA = true;

   while(vaVol < targetVol)
   {
      double aboveVol = 0;
      double belowVol = 0;

      if(upper + 1 < profile.levelCount)
         aboveVol = profile.levels[upper + 1].totalVol;
      if(lower - 1 >= 0)
         belowVol = profile.levels[lower - 1].totalVol;

      if(aboveVol <= 0 && belowVol <= 0) break;

      if(aboveVol >= belowVol)
      {
         upper++;
         vaVol += profile.levels[upper].totalVol;
         profile.levels[upper].inVA = true;
      }
      else
      {
         lower--;
         vaVol += profile.levels[lower].totalVol;
         profile.levels[lower].inVA = true;
      }
   }

   profile.vahPrice = profile.levels[upper].price;
   profile.valPrice = profile.levels[lower].price;
}

//+------------------------------------------------------------------+
//| VWAP calculation                                                  |
//+------------------------------------------------------------------+
void CalculateVWAP(datetime start, datetime end)
{
   MqlTick ticks[];
   int copied = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL,
                               (ulong)start * 1000, (ulong)end * 1000);
   if(copied <= 0) { g_vwap = 0; return; }

   g_cumPV    = 0;
   g_cumVol   = 0;
   g_cumDelta = 0;

   double prevMid = (ticks[0].bid + ticks[0].ask) / 2.0;

   for(int i = 1; i < copied; i++)
   {
      double mid = (ticks[i].bid + ticks[i].ask) / 2.0;
      double vol = GetTickVolume(ticks[i]);

      g_cumPV  += mid * vol;
      g_cumVol += vol;

      int dir = ClassifyTick(ticks[i], prevMid, mid);
      if(dir > 0)      g_cumDelta += vol;
      else if(dir < 0) g_cumDelta -= vol;

      prevMid = mid;
   }

   g_vwap = (g_cumVol > 0) ? g_cumPV / g_cumVol : 0;
}

void CalculateVWAPForRange(datetime start, datetime end, double &vwapOut)
{
   CalculateVWAP(start, end);
   vwapOut = g_vwap;
}

//+------------------------------------------------------------------+
//| Drawing functions                                                 |
//+------------------------------------------------------------------+
void RemoveAllObjects()
{
   ObjectsDeleteAll(0, g_objPrefix);
}

void RemoveObjectsWithPrefix(string prefix)
{
   ObjectsDeleteAll(0, g_objPrefix + prefix);
}

void DrawAllPriorProfiles()
{
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;

      string prefix = "D" + IntegerToString(d) + "_";
      RemoveObjectsWithPrefix(prefix);
      DrawSingleProfile(g_priorProfiles[d], prefix);
      DrawPOCExtension(g_priorProfiles[d], prefix);
   }
}

void DrawSingleProfile(DailyProfile &profile, string prefix)
{
   if(!profile.isValid || profile.levelCount == 0) return;

   double maxVol = 0;
   for(int i = 0; i < profile.levelCount; i++)
      if(profile.levels[i].totalVol > maxVol)
         maxVol = profile.levels[i].totalVol;

   if(maxVol <= 0) return;

   long sessionDuration = (long)(profile.sessionEnd - profile.sessionStart);
   double maxWidth = sessionDuration * InpProfileWidthPct / 100.0;

   for(int i = 0; i < profile.levelCount; i++)
   {
      if(profile.levels[i].totalVol <= 0) continue;

      double widthFraction = profile.levels[i].totalVol / maxVol;
      datetime barEnd = profile.sessionStart +
                        (datetime)(maxWidth * widthFraction);

      color barColor = InpNormalColor;
      if(profile.levels[i].isPOC)       barColor = InpPOCColor;
      else if(profile.levels[i].isHVN)  barColor = InpHVNColor;
      else if(profile.levels[i].isLVN)  barColor = InpLVNColor;
      else if(profile.levels[i].inVA)   barColor = InpVAColor;

      string objName = g_objPrefix + prefix + IntegerToString(i);
      double priceTop = profile.levels[i].price + InpPriceStep;

      ObjectCreate(0, objName, OBJ_RECTANGLE, 0,
                   profile.sessionStart, profile.levels[i].price,
                   barEnd, priceTop);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, barColor);
      ObjectSetInteger(0, objName, OBJPROP_FILL, true);
      ObjectSetInteger(0, objName, OBJPROP_BACK, true);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);

      if(profile.levels[i].isPOC || profile.levels[i].isHVN ||
         profile.levels[i].isLVN)
      {
         string lblName = g_objPrefix + prefix + "L" + IntegerToString(i);
         string lblText = "";
         if(profile.levels[i].isPOC)
            lblText = "POC " + DoubleToString(profile.levels[i].price, _Digits);
         else if(profile.levels[i].isHVN)
            lblText = "HVN";
         else if(profile.levels[i].isLVN)
            lblText = "LVN";

         ObjectCreate(0, lblName, OBJ_TEXT, 0, barEnd, profile.levels[i].price);
         ObjectSetString(0, lblName, OBJPROP_TEXT, lblText);
         ObjectSetInteger(0, lblName, OBJPROP_COLOR, barColor);
         ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, lblName, OBJPROP_HIDDEN, true);
      }
   }
}

void DrawPOCExtension(DailyProfile &profile, string prefix)
{
   if(!profile.isValid) return;

   string pocLine = g_objPrefix + prefix + "POC_EXT";
   ObjectCreate(0, pocLine, OBJ_TREND, 0,
                profile.sessionEnd, profile.pocPrice,
                TimeCurrent(), profile.pocPrice);
   ObjectSetInteger(0, pocLine, OBJPROP_COLOR, InpPOCLineColor);
   ObjectSetInteger(0, pocLine, OBJPROP_STYLE, InpPOCLineStyle);
   ObjectSetInteger(0, pocLine, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, pocLine, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, pocLine, OBJPROP_BACK, true);
   ObjectSetInteger(0, pocLine, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, pocLine, OBJPROP_HIDDEN, true);

   string vahLine = g_objPrefix + prefix + "VAH_EXT";
   ObjectCreate(0, vahLine, OBJ_TREND, 0,
                profile.sessionEnd, profile.vahPrice,
                TimeCurrent(), profile.vahPrice);
   ObjectSetInteger(0, vahLine, OBJPROP_COLOR, InpVAColor);
   ObjectSetInteger(0, vahLine, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, vahLine, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, vahLine, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, vahLine, OBJPROP_BACK, true);
   ObjectSetInteger(0, vahLine, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, vahLine, OBJPROP_HIDDEN, true);

   string valLine = g_objPrefix + prefix + "VAL_EXT";
   ObjectCreate(0, valLine, OBJ_TREND, 0,
                profile.sessionEnd, profile.valPrice,
                TimeCurrent(), profile.valPrice);
   ObjectSetInteger(0, valLine, OBJPROP_COLOR, InpVAColor);
   ObjectSetInteger(0, valLine, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, valLine, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, valLine, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, valLine, OBJPROP_BACK, true);
   ObjectSetInteger(0, valLine, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, valLine, OBJPROP_HIDDEN, true);
}

void DrawVWAPLine()
{
   if(g_vwap <= 0) return;

   string vwapName = g_objPrefix + "VWAP_LINE";
   ObjectDelete(0, vwapName);

   ObjectCreate(0, vwapName, OBJ_TREND, 0,
                g_todaySessionStart, g_vwap,
                TimeCurrent(), g_vwap);
   ObjectSetInteger(0, vwapName, OBJPROP_COLOR, InpVWAPColor);
   ObjectSetInteger(0, vwapName, OBJPROP_WIDTH, InpVWAPWidth);
   ObjectSetInteger(0, vwapName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, vwapName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, vwapName, OBJPROP_BACK, true);
   ObjectSetInteger(0, vwapName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, vwapName, OBJPROP_HIDDEN, true);

   string vwapLbl = g_objPrefix + "VWAP_LBL";
   ObjectDelete(0, vwapLbl);
   ObjectCreate(0, vwapLbl, OBJ_TEXT, 0, TimeCurrent(), g_vwap);
   ObjectSetString(0, vwapLbl, OBJPROP_TEXT,
                   "VWAP " + DoubleToString(g_vwap, _Digits));
   ObjectSetInteger(0, vwapLbl, OBJPROP_COLOR, InpVWAPColor);
   ObjectSetInteger(0, vwapLbl, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, vwapLbl, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, vwapLbl, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| CSV Export                                                        |
//+------------------------------------------------------------------+
void ExportAllProfiles()
{
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      ExportSingleProfile(g_priorProfiles[d], "");
   }
}

void ExportSingleProfile(DailyProfile &profile, string suffix)
{
   if(!profile.isValid) return;

   MqlDateTime dt;
   TimeToStruct(profile.sessionStart, dt);

   string dateStr = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string fileName = InpCSVFolder + "\\" + _Symbol + "_" + dateStr;
   if(suffix != "") fileName += "_" + suffix;
   fileName += "_profile.csv";

   int handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("Failed to open CSV: ", fileName);
      return;
   }

   FileWrite(handle, "# Symbol: " + _Symbol);
   FileWrite(handle, "# Date: " + dateStr);
   FileWrite(handle, "# SessionStart: " + TimeToString(profile.sessionStart));
   FileWrite(handle, "# SessionEnd: " + TimeToString(profile.sessionEnd));
   FileWrite(handle, "# POC: " + DoubleToString(profile.pocPrice, _Digits));
   FileWrite(handle, "# VAH: " + DoubleToString(profile.vahPrice, _Digits));
   FileWrite(handle, "# VAL: " + DoubleToString(profile.valPrice, _Digits));
   FileWrite(handle, "# VWAP: " + DoubleToString(profile.vwap, _Digits));
   FileWrite(handle, "# TotalVolume: " + DoubleToString(profile.totalVolume, 0));
   FileWrite(handle, "# TotalDelta: " + DoubleToString(profile.totalDelta, 0));
   FileWrite(handle, "PriceLevel", "TotalVolume", "BuyVolume", "SellVolume",
             "Delta", "SmoothedVolume", "NodeType");

   for(int i = 0; i < profile.levelCount; i++)
   {
      string nodeType = "Normal";
      if(profile.levels[i].isPOC)      nodeType = "POC";
      else if(profile.levels[i].isHVN) nodeType = "HVN";
      else if(profile.levels[i].isLVN) nodeType = "LVN";
      else if(profile.levels[i].inVA)  nodeType = "VA";

      double delta = profile.levels[i].buyVol - profile.levels[i].sellVol;

      FileWrite(handle,
                DoubleToString(profile.levels[i].price, _Digits),
                DoubleToString(profile.levels[i].totalVol, 2),
                DoubleToString(profile.levels[i].buyVol, 2),
                DoubleToString(profile.levels[i].sellVol, 2),
                DoubleToString(delta, 2),
                DoubleToString(profile.levels[i].smoothedVol, 2),
                nodeType);
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Delta snapshot ring buffer                                       |
//+------------------------------------------------------------------+
void RecordDeltaSnapshot(double delta, datetime time)
{
   int maxSnaps = ArraySize(g_deltaSnaps);
   g_deltaSnaps[g_deltaSnapIdx].delta = delta;
   g_deltaSnaps[g_deltaSnapIdx].time  = time;
   g_deltaSnapIdx = (g_deltaSnapIdx + 1) % maxSnaps;
   if(g_deltaSnapCount < maxSnaps)
      g_deltaSnapCount++;
}

double GetDeltaROC(datetime now)
{
   if(g_deltaSnapCount < 2) return 0;

   double currentDelta = g_cumDelta;
   datetime cutoff = now - InpDeltaRocSeconds;

   int maxSnaps = ArraySize(g_deltaSnaps);
   double oldestDelta = currentDelta;
   datetime oldestTime = now;
   bool found = false;

   for(int k = 0; k < g_deltaSnapCount; k++)
   {
      int idx = (g_deltaSnapIdx - 1 - k + maxSnaps * 2) % maxSnaps;
      if(g_deltaSnaps[idx].time <= cutoff)
      {
         oldestDelta = g_deltaSnaps[idx].delta;
         oldestTime  = g_deltaSnaps[idx].time;
         found = true;
         break;
      }
   }

   if(!found)
   {
      int idx = (g_deltaSnapIdx - g_deltaSnapCount + maxSnaps * 2) % maxSnaps;
      oldestDelta = g_deltaSnaps[idx].delta;
      oldestTime  = g_deltaSnaps[idx].time;
   }

   double elapsed = (double)(now - oldestTime);
   if(elapsed <= 0) return 0;

   return (currentDelta - oldestDelta) / elapsed * InpDeltaRocSeconds;
}

//+------------------------------------------------------------------+
//| Cooldown zone tracking                                           |
//+------------------------------------------------------------------+
void RecordTradedZone(double price, datetime time)
{
   if(g_tradedZoneCount < ArraySize(g_tradedZones))
   {
      g_tradedZones[g_tradedZoneCount].price = price;
      g_tradedZones[g_tradedZoneCount].time  = time;
      g_tradedZoneCount++;
   }
}

bool IsInCooldown(double price, datetime now)
{
   for(int i = 0; i < g_tradedZoneCount; i++)
   {
      double dist = MathAbs(price - g_tradedZones[i].price) / InpPriceStep;
      int elapsed = (int)(now - g_tradedZones[i].time);
      if(dist <= InpCooldownZoneSize && elapsed < InpCooldownSeconds)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Active trading window check                                      |
//+------------------------------------------------------------------+
bool IsWithinActiveWindow(datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int nowMins  = dt.hour * 60 + dt.min;
   int startMins = InpActiveStartHour * 60 + InpActiveStartMin;
   int endMins   = InpActiveEndHour * 60 + InpActiveEndMin;
   return (nowMins >= startMins && nowMins <= endMins);
}

//+------------------------------------------------------------------+
//| Day-of-week and hour filters                                     |
//+------------------------------------------------------------------+
bool IsDayBlocked(datetime now)
{
   if(StringLen(InpBlockedDays) == 0) return false;
   MqlDateTime dt;
   TimeToStruct(now, dt);
   string parts[];
   int n = StringSplit(InpBlockedDays, ',', parts);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if((int)StringToInteger(parts[i]) == dt.day_of_week)
         return true;
   }
   return false;
}

bool IsHourBlocked(datetime now)
{
   if(InpBlockedHourStart < 0) return false;
   MqlDateTime dt;
   TimeToStruct(now, dt);
   return (dt.hour >= InpBlockedHourStart && dt.hour <= InpBlockedHourEnd);
}

//+------------------------------------------------------------------+
//| Volume confirmation (current bar vs recent average)              |
//+------------------------------------------------------------------+
bool IsVolumeAboveAverage()
{
   // Method 1: Compare current M5 bar volume to recent M5 bar average
   long volumes[];
   int bars = CopyTickVolume(_Symbol, PERIOD_M5, 0, 30, volumes);

   if(bars >= 5)
   {
      double avg = 0;
      for(int i = 1; i < bars; i++)
         avg += (double)volumes[i];
      avg /= (bars - 1);
      if(avg > 0)
         return ((double)volumes[0] / avg) >= InpMinBarVolRatio;
   }

   // Method 2: Compare current bar's volume to same-timeframe prior-day averages
   if(g_currentProfile.isValid && g_currentProfile.levelCount > 0)
   {
      double curBarVol = 0;
      long vol1[];
      if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 1, vol1) >= 1)
         curBarVol = (double)vol1[0];

      if(curBarVol > 0)
      {
         double priorBarAvg = 0;
         int validDays = 0;
         for(int d = 0; d < InpDaysBack; d++)
         {
            if(!g_priorProfiles[d].isValid) continue;
            if(g_priorProfiles[d].levelCount <= 0) continue;
            double dayAvg = g_priorProfiles[d].totalVolume / g_priorProfiles[d].levelCount;
            priorBarAvg += dayAvg;
            validDays++;
         }
         if(validDays > 0)
         {
            priorBarAvg /= validDays;
            if(priorBarAvg > 0)
               return (curBarVol / priorBarAvg) >= InpMinBarVolRatio;
         }
      }
   }

   // Method 3: Session volume pace vs prior-day average pace
   if(!g_currentProfile.isValid || g_currentProfile.totalVolume <= 0)
      return false;

   double priorAvg = 0;
   int validDays = 0;
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      priorAvg += g_priorProfiles[d].totalVolume;
      validDays++;
   }
   if(validDays == 0) return false;
   priorAvg /= validDays;

   double elapsed = (double)(TimeCurrent() - g_todaySessionStart);
   double sessionLen = (double)(g_todaySessionEnd - g_todaySessionStart);
   if(sessionLen <= 0 || elapsed <= 0) return false;
   double paceRatio = (g_currentProfile.totalVolume / elapsed) /
                      (priorAvg / sessionLen);
   return paceRatio >= InpMinBarVolRatio;
}

//+------------------------------------------------------------------+
//| Confluence scoring                                               |
//+------------------------------------------------------------------+
int GetConfluenceScore(double price, int direction)
{
   int score = 0;
   datetime now = TimeCurrent();

   // 1. VWAP alignment — prerequisite when InpVwapPrereq, otherwise +1
   bool vwapOk = (direction > 0 && price <= g_vwap) ||
                 (direction < 0 && price >= g_vwap);
   if(InpVwapPrereq)
   {
      if(!vwapOk) return -1;
   }
   else if(vwapOk) score++;

   // 2. At current session HVN or POC (+2)
   int lvl = FindNearestLevel(g_currentProfile, price);
   if(lvl >= 0)
   {
      if(g_currentProfile.levels[lvl].isHVN ||
         g_currentProfile.levels[lvl].isPOC)
         score += 2;
   }

   // 3. Near prior day POC (configurable weight)
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      double dist = MathAbs(price - g_priorProfiles[d].pocPrice) / InpPriceStep;
      if(dist <= InpProximitySteps)
      {
         score += InpPriorPOCWeight;
         break;
      }
   }

   // 4. Near prior VAL (for longs) or VAH (for shorts) (+1)
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      if(direction > 0)
      {
         double dist = MathAbs(price - g_priorProfiles[d].valPrice) / InpPriceStep;
         if(dist <= InpProximitySteps) { score++; break; }
      }
      else
      {
         double dist = MathAbs(price - g_priorProfiles[d].vahPrice) / InpPriceStep;
         if(dist <= InpProximitySteps) { score++; break; }
      }
   }

   // 5. Near prior HVN — prerequisite when InpPriorHvnPrereq, otherwise +1
   bool hvnOk = false;
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      for(int i = 0; i < g_priorProfiles[d].levelCount; i++)
      {
         if(!g_priorProfiles[d].levels[i].isHVN) continue;
         double dist = MathAbs(price - g_priorProfiles[d].levels[i].price) / InpPriceStep;
         if(dist <= InpProximitySteps) { hvnOk = true; d = InpDaysBack; break; }
      }
   }
   if(InpPriorHvnPrereq)
   {
      if(!hvnOk) return -1;
   }
   else if(hvnOk) score++;

   // 6. Delta in favor (+1)
   if(direction > 0 && g_cumDelta > 0) score++;
   if(direction < 0 && g_cumDelta < 0) score++;

   // 7. Delta ROC — prerequisite when InpDeltaRocPrereq, otherwise +1
   double roc = GetDeltaROC(now);
   bool rocOk = (direction > 0 && roc >= InpDeltaRocMin) ||
                (direction < 0 && roc <= -InpDeltaRocMin);
   if(InpDeltaRocPrereq)
   {
      if(!rocOk) return -1;
   }
   else if(rocOk) score++;

   // 8. Volume above average (logged only, not scored — unreliable in tester)

   return score;
}

//+------------------------------------------------------------------+
//| Dynamic SL placement                                             |
//+------------------------------------------------------------------+
double FindStructuralSL(double entryPrice, int direction)
{
   double padding = InpSLPadding;

   if(InpSLMode == SL_FIXED)
   {
      if(direction > 0)
         return NormalizeDouble(entryPrice - InpSLFallback, _Digits);
      else
         return NormalizeDouble(entryPrice + InpSLFallback, _Digits);
   }

   // Collect candidates from each volume-based method
   double slLVN  = 0;  // beyond next LVN opposite to trade
   double slVA   = 0;  // beyond value area boundary
   double slPOC  = 0;  // beyond prior session POC

   // --- Search current session profile ---
   if(g_currentProfile.isValid)
   {
      if(InpSLMode == SL_BEYOND_LVN || InpSLMode == SL_COMPOSITE)
         slLVN = FindNextLVN(g_currentProfile, entryPrice, direction, padding);

      if(InpSLMode == SL_BEYOND_VA || InpSLMode == SL_COMPOSITE)
         slVA = FindVABoundarySL(g_currentProfile, entryPrice, direction, padding);
   }

   // --- Search prior session profiles ---
   // Keep the NEAREST candidate per method (closest structural support/resistance)
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;

      if(InpSLMode == SL_BEYOND_LVN || InpSLMode == SL_COMPOSITE)
      {
         double lvn = FindNextLVN(g_priorProfiles[d], entryPrice, direction, padding);
         if(lvn != 0 && IsCloserSL(lvn, slLVN, entryPrice, direction))
            slLVN = lvn;
      }

      if(InpSLMode == SL_BEYOND_VA || InpSLMode == SL_COMPOSITE)
      {
         double va = FindVABoundarySL(g_priorProfiles[d], entryPrice, direction, padding);
         if(va != 0 && IsCloserSL(va, slVA, entryPrice, direction))
            slVA = va;
      }

      if(InpSLMode == SL_PRIOR_POC || InpSLMode == SL_COMPOSITE)
      {
         double poc = g_priorProfiles[d].pocPrice;
         bool wrongSide = (direction > 0) ? (poc < entryPrice) : (poc > entryPrice);
         if(wrongSide)
         {
            double candidate = (direction > 0) ? poc - padding : poc + padding;
            if(slPOC == 0 || IsCloserSL(candidate, slPOC, entryPrice, direction))
               slPOC = candidate;
         }
      }
   }

   // --- Pick the best SL based on mode ---
   double bestSL = 0;

   if(InpSLMode == SL_COMPOSITE)
   {
      // Composite: use whichever structural level is FURTHEST from entry
      // (most protective — SL behind the strongest nearby structure)
      if(slLVN != 0) bestSL = slLVN;
      if(slVA != 0 && IsFurtherSL(slVA, bestSL, entryPrice, direction))
         bestSL = slVA;
      if(slPOC != 0 && IsFurtherSL(slPOC, bestSL, entryPrice, direction))
         bestSL = slPOC;
   }
   else if(InpSLMode == SL_BEYOND_LVN)
      bestSL = slLVN;
   else if(InpSLMode == SL_BEYOND_VA)
      bestSL = slVA;
   else if(InpSLMode == SL_PRIOR_POC)
      bestSL = slPOC;

   // --- Fallback if no level found ---
   if(bestSL == 0)
   {
      if(direction > 0) bestSL = entryPrice - InpSLFallback;
      else              bestSL = entryPrice + InpSLFallback;
   }

   // --- Enforce min/max distance ---
   double dist = MathAbs(entryPrice - bestSL);

   if(dist < InpMinSL)
   {
      if(direction > 0) bestSL = entryPrice - InpMinSL;
      else              bestSL = entryPrice + InpMinSL;
   }
   else if(dist > InpMaxSL)
   {
      if(direction > 0) bestSL = entryPrice - InpMaxSL;
      else              bestSL = entryPrice + InpMaxSL;
   }

   return NormalizeDouble(bestSL, _Digits);
}

// Find the nearest LVN in the opposite direction to the trade
double FindNextLVN(DailyProfile &profile, double entry, int dir, double padding)
{
   double best = 0;

   for(int i = 0; i < profile.levelCount; i++)
   {
      if(!profile.levels[i].isLVN) continue;
      double p = profile.levels[i].price;

      if(dir > 0 && p < entry - InpPriceStep)
      {
         double candidate = p - padding;
         if(best == 0 || candidate > best)
            best = candidate;
      }
      else if(dir < 0 && p > entry + InpPriceStep)
      {
         double candidate = p + padding;
         if(best == 0 || candidate < best)
            best = candidate;
      }
   }
   return best;
}

// Find SL beyond the value area boundary
double FindVABoundarySL(DailyProfile &profile, double entry, int dir, double padding)
{
   if(dir > 0 && profile.valPrice < entry)
      return profile.valPrice - padding;
   if(dir < 0 && profile.vahPrice > entry)
      return profile.vahPrice + padding;
   return 0;
}

// Returns true if candidate is further from entry than current best
bool IsFurtherSL(double candidate, double current, double entry, int dir)
{
   if(current == 0) return true;
   double candDist = MathAbs(entry - candidate);
   double currDist = MathAbs(entry - current);
   return candDist > currDist;
}

// Returns true if candidate is closer to entry than current best
bool IsCloserSL(double candidate, double current, double entry, int dir)
{
   if(current == 0) return true;
   double candDist = MathAbs(entry - candidate);
   double currDist = MathAbs(entry - current);
   return candDist < currDist;
}

//+------------------------------------------------------------------+
//| Dynamic TP placement                                             |
//+------------------------------------------------------------------+
void FindTargetTP(double entryPrice, int direction,
                  double &tp1Out, double &tp2Out)
{
   tp1Out = 0;
   tp2Out = 0;

   if(InpTPMode == TP_FIXED)
   {
      if(direction > 0) tp1Out = entryPrice + InpTPFallback;
      else              tp1Out = entryPrice - InpTPFallback;
      return;
   }

   double nearestLVN = 0;
   double nearestHVN = 0;
   double nearestPOC = 0;

   // Search current session profile
   if(g_currentProfile.isValid)
      FindTPLevels(g_currentProfile, entryPrice, direction,
                   nearestLVN, nearestHVN, nearestPOC);

   // Search prior profiles for additional levels
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      double lvn2 = 0, hvn2 = 0, poc2 = 0;
      FindTPLevels(g_priorProfiles[d], entryPrice, direction,
                   lvn2, hvn2, poc2);

      if(lvn2 != 0 && (nearestLVN == 0 || IsCloserInDir(lvn2, nearestLVN, entryPrice, direction)))
         nearestLVN = lvn2;
      if(hvn2 != 0 && (nearestHVN == 0 || IsCloserInDir(hvn2, nearestHVN, entryPrice, direction)))
         nearestHVN = hvn2;
      if(poc2 != 0 && (nearestPOC == 0 || IsCloserInDir(poc2, nearestPOC, entryPrice, direction)))
         nearestPOC = poc2;
   }

   if(InpTPMode == TP_NEXT_LVN)
   {
      tp1Out = nearestLVN;
   }
   else if(InpTPMode == TP_NEXT_HVN)
   {
      tp1Out = nearestHVN;
   }
   else if(InpTPMode == TP_MULTI_TARGET)
   {
      tp1Out = nearestLVN;
      // TP2 = next HVN beyond TP1, or prior POC if further
      if(nearestHVN != 0)
      {
         bool hvnBeyondLvn = (direction > 0)
            ? (nearestHVN > nearestLVN || nearestLVN == 0)
            : (nearestHVN < nearestLVN || nearestLVN == 0);
         if(hvnBeyondLvn) tp2Out = nearestHVN;
      }
      if(tp2Out == 0 && nearestPOC != 0) tp2Out = nearestPOC;
   }

   // Fallback if no structural level found
   if(tp1Out == 0)
   {
      if(direction > 0) tp1Out = entryPrice + InpTPFallback;
      else              tp1Out = entryPrice - InpTPFallback;
   }

   // Enforce minimum TP distance
   double tp1Dist = MathAbs(tp1Out - entryPrice);
   if(tp1Dist < InpMinTP)
   {
      if(direction > 0) tp1Out = entryPrice + InpMinTP;
      else              tp1Out = entryPrice - InpMinTP;
   }

   if(tp2Out != 0)
   {
      double tp2Dist = MathAbs(tp2Out - entryPrice);
      if(tp2Dist < InpMinTP)
      {
         if(direction > 0) tp2Out = entryPrice + InpTPFallback;
         else              tp2Out = entryPrice - InpTPFallback;
      }
   }

   // Ensure TP2 is further than TP1
   if(tp2Out != 0)
   {
      bool tp2Further = (direction > 0) ? (tp2Out > tp1Out) : (tp2Out < tp1Out);
      if(!tp2Further) tp2Out = 0;
   }

   tp1Out = NormalizeDouble(tp1Out, _Digits);
   if(tp2Out != 0)
      tp2Out = NormalizeDouble(tp2Out, _Digits);
}

void FindTPLevels(DailyProfile &profile, double entry, int dir,
                  double &lvnOut, double &hvnOut, double &pocOut)
{
   for(int i = 0; i < profile.levelCount; i++)
   {
      double p = profile.levels[i].price;
      double dist = MathAbs(p - entry);

      // Must be in trade direction AND beyond minimum TP distance
      bool inDir = (dir > 0) ? (p > entry + InpPriceStep) : (p < entry - InpPriceStep);
      if(!inDir) continue;
      if(dist < InpMinTP) continue;

      if(profile.levels[i].isLVN)
      {
         if(lvnOut == 0 || IsCloserInDir(p, lvnOut, entry, dir))
            lvnOut = p;
      }
      if(profile.levels[i].isHVN)
      {
         if(hvnOut == 0 || IsCloserInDir(p, hvnOut, entry, dir))
            hvnOut = p;
      }
      if(profile.levels[i].isPOC)
      {
         if(pocOut == 0 || IsCloserInDir(p, pocOut, entry, dir))
            pocOut = p;
      }
   }
}

bool IsCloserInDir(double a, double b, double ref, int dir)
{
   if(dir > 0) return (a - ref) < (b - ref);
   return (ref - a) < (ref - b);
}

//+------------------------------------------------------------------+
//| Scan a single profile for trail SL candidates                    |
//+------------------------------------------------------------------+
double ScanProfileForTrailSL(DailyProfile &profile, double posPrice,
                              double bid, double ask, double padding,
                              int dir, double currentBest)
{
   if(!profile.isValid) return currentBest;

   for(int i = 0; i < profile.levelCount; i++)
   {
      if(!profile.levels[i].isHVN && !profile.levels[i].isPOC) continue;

      double hvnPrice = profile.levels[i].price;

      if(dir > 0)
      {
         if(hvnPrice > posPrice && hvnPrice < bid - InpPriceStep)
         {
            double candidate = hvnPrice - padding;
            if(candidate > currentBest)
               currentBest = candidate;
         }
      }
      else
      {
         if(hvnPrice < posPrice && hvnPrice > ask + InpPriceStep)
         {
            double candidate = hvnPrice + padding;
            if(candidate < currentBest || currentBest == 0)
               currentBest = candidate;
         }
      }
   }

   return currentBest;
}

//+------------------------------------------------------------------+
//| Trailing stop management (trail to cleared HVNs)                 |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!PositionSelectByTicket(g_managedTicket)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double posPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double padding = InpTrailPadding;

   double newSL = currentSL;

   newSL = ScanProfileForTrailSL(g_currentProfile, posPrice, bid, ask, padding, g_managedDir, newSL);

   for(int d = 0; d < InpDaysBack; d++)
      newSL = ScanProfileForTrailSL(g_priorProfiles[d], posPrice, bid, ask, padding, g_managedDir, newSL);

   newSL = NormalizeDouble(newSL, _Digits);

   // Before TP1, enforce minimum distance from entry
   if(!g_tp1Hit && InpTrailMinPct > 0 && g_entrySL != 0)
   {
      double origDist = MathAbs(g_entryPrice - g_entrySL);
      double minDist  = origDist * InpTrailMinPct / 100.0;
      double trailDist = MathAbs(newSL - posPrice);
      if(trailDist < minDist)
         return;
   }

   if(g_managedDir > 0 && newSL > currentSL && newSL < bid)
   {
      if(g_trade.PositionModify(g_managedTicket, newSL, currentTP))
      {
         g_currentSL = newSL;
         Print("Trail SL moved to ", newSL, " (HVN cleared)");
      }
   }
   else if(g_managedDir < 0 && (newSL < currentSL || currentSL == 0) && newSL > ask)
   {
      if(g_trade.PositionModify(g_managedTicket, newSL, currentTP))
      {
         g_currentSL = newSL;
         Print("Trail SL moved to ", newSL, " (HVN cleared)");
      }
   }
}

//+------------------------------------------------------------------+
//| Partial close at TP1                                             |
//+------------------------------------------------------------------+
void CheckTP1PartialClose()
{
   if(!PositionSelectByTicket(g_managedTicket)) return;
   if(g_tp1Hit) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentTP = PositionGetDouble(POSITION_TP);

   bool tp1Reached = false;
   if(g_managedDir > 0 && bid >= currentTP) tp1Reached = true;
   if(g_managedDir < 0 && ask <= currentTP) tp1Reached = true;

   if(!tp1Reached) return;

   double posVol = PositionGetDouble(POSITION_VOLUME);
   double closeVol = NormalizeDouble(posVol * InpPartialClosePct / 100.0,
                                      (int)MathLog10(1.0 / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)));

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   closeVol = MathFloor(closeVol / lotStep) * lotStep;
   if(closeVol < minLot) closeVol = minLot;

   double remaining = posVol - closeVol;
   if(remaining < minLot)
   {
      g_tp1Hit = true;
      return;
   }

   if(g_trade.PositionClosePartial(g_managedTicket, closeVol))
   {
      Print("TP1 partial close: ", closeVol, " lots at ",
            (g_managedDir > 0) ? bid : ask);
      g_tp1Hit = true;

      // Move TP to TP2 for the remainder
      if(g_tp2Price > 0 && PositionSelectByTicket(g_managedTicket))
      {
         double sl = PositionGetDouble(POSITION_SL);
         g_trade.PositionModify(g_managedTicket, sl, g_tp2Price);
         Print("TP moved to TP2: ", g_tp2Price);
      }
   }
}

//+------------------------------------------------------------------+
//| Signal logic with confluence scoring                             |
//+------------------------------------------------------------------+
void CheckSignals()
{
   if(!g_currentProfile.isValid || g_vwap <= 0) return;

   datetime now = TimeCurrent();

   // --- Pre-filters (fast rejection) ---

   if(!IsWithinActiveWindow(now)) return;
   if(IsDayBlocked(now)) return;
   if(IsHourBlocked(now)) return;

   if(InpGlobalCooldown > 0 && g_lastTradeTime > 0 &&
      (now - g_lastTradeTime) < InpGlobalCooldown) return;

   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);
   datetime today = (datetime)(now - now % 86400);
   if(today != g_lastTradeDay)
   {
      g_tradesToday = 0;
      g_lastTradeDay = today;
   }
   if(g_tradesToday >= InpMaxTradesPerDay) return;

   if(HasOpenPosition()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   if(IsInCooldown(mid, now)) return;

   // --- Score both directions with breakdown ---
   // Returns -1 when a prerequisite (VWAP/DeltaROC/PriorHVN) fails
   int lVwap, lHvn, lPPoc, lPVa, lPHvn, lDelta, lRoc, lVol;
   int sVwap, sHvn, sPPoc, sPVa, sPHvn, sDelta, sRoc, sVol;
   int longScore  = GetConfluenceScoreDetailed(mid, 1,
                       lVwap, lHvn, lPPoc, lPVa, lPHvn, lDelta, lRoc, lVol);
   int shortScore = GetConfluenceScoreDetailed(mid, -1,
                       sVwap, sHvn, sPPoc, sPVa, sPHvn, sDelta, sRoc, sVol);

   // Prerequisites failed for both directions
   if(longScore < 0 && shortScore < 0)
   {
      if(InpSignalLog && !InpLogTradesOnly)
         LogSignalEvaluation(now, mid, 1,
            lVwap, lHvn, lPPoc, lPVa, lPHvn, lDelta, lRoc, lVol,
            0, 0, 0, 0, "SKIP", "prereq_failed");
      return;
   }

   // --- Determine best direction if either qualifies ---
   int tradeDir = 0;

   if(longScore >= InpMinScore && (shortScore < 0 || longScore > shortScore))
      tradeDir = 1;
   else if(shortScore >= InpMinScore && (longScore < 0 || shortScore > longScore))
      tradeDir = -1;
   else if(longScore >= InpMinScore && longScore == shortScore)
   {
      if(InpSignalLog && !InpLogTradesOnly)
         LogSignalEvaluation(now, mid, 1,
            lVwap, lHvn, lPPoc, lPVa, lPHvn, lDelta, lRoc, lVol,
            longScore, 0, 0, 0, "SKIP", "conflicting_scores");
      return;
   }

   if(tradeDir == 0)
   {
      int bestDir = (longScore >= shortScore) ? 1 : -1;
      int bestScore = (bestDir > 0) ? longScore : shortScore;
      if(InpSignalLog && !InpLogTradesOnly && bestScore >= 2)
         LogSignalEvaluation(now, mid, bestDir,
            (bestDir > 0 ? lVwap : sVwap), (bestDir > 0 ? lHvn : sHvn),
            (bestDir > 0 ? lPPoc : sPPoc), (bestDir > 0 ? lPVa : sPVa),
            (bestDir > 0 ? lPHvn : sPHvn), (bestDir > 0 ? lDelta : sDelta),
            (bestDir > 0 ? lRoc : sRoc), (bestDir > 0 ? lVol : sVol),
            bestScore, 0, 0, 0, "SKIP", "score_below_min");
      return;
   }

   // Pick the winning direction's breakdown
   int wVwap, wHvn, wPPoc, wPVa, wPHvn, wDelta, wRoc, wVol;
   if(tradeDir > 0) { wVwap=lVwap; wHvn=lHvn; wPPoc=lPPoc; wPVa=lPVa; wPHvn=lPHvn; wDelta=lDelta; wRoc=lRoc; wVol=lVol; }
   else              { wVwap=sVwap; wHvn=sHvn; wPPoc=sPPoc; wPVa=sPVa; wPHvn=sPHvn; wDelta=sDelta; wRoc=sRoc; wVol=sVol; }

   // --- Calculate dynamic SL/TP ---
   double entryPrice = (tradeDir > 0) ? ask : bid;
   double sl = FindStructuralSL(entryPrice, tradeDir);
   double tp1 = 0, tp2 = 0;
   FindTargetTP(entryPrice, tradeDir, tp1, tp2);

   // Enforce broker minimum stop distance
   double minStopDist = GetMinStopDistance();
   sl  = EnforceMinDistance(entryPrice, sl, tradeDir, true, minStopDist);
   tp1 = EnforceMinDistance(entryPrice, tp1, tradeDir, false, minStopDist);
   if(tp2 != 0)
      tp2 = EnforceMinDistance(entryPrice, tp2, tradeDir, false, minStopDist);

   double slDist  = MathAbs(entryPrice - sl);
   double tp1Dist = MathAbs(tp1 - entryPrice);

   // Require reward >= risk
   if(tp1Dist < slDist * InpMinRR)
   {
      RecordTradedZone(mid, now);
      if(InpSignalLog && !InpLogTradesOnly)
         LogSignalEvaluation(now, mid, tradeDir,
            wVwap, wHvn, wPPoc, wPVa, wPHvn, wDelta, wRoc, wVol,
            (tradeDir > 0 ? longScore : shortScore),
            sl, tp1, tp2, "SKIP", "RR_too_low");
      Print("Skipping: R:R too low. TP1=", tp1Dist / _Point,
            " pts vs SL=", slDist / _Point, " pts");
      return;
   }

   double lots = GetLotSize(slDist);
   int score = (tradeDir > 0) ? longScore : shortScore;

   string comment = InpComment + ((tradeDir > 0) ? " L" : " S") +
                     " s" + IntegerToString(score);

   // --- Execute ---
   RecordTradedZone(mid, now);

   bool success = false;
   if(tradeDir > 0)
      success = g_trade.Buy(lots, _Symbol, ask, sl, tp1, comment);
   else
      success = g_trade.Sell(lots, _Symbol, bid, sl, tp1, comment);

   if(success)
   {
      g_managedTicket = g_trade.ResultOrder();
      g_managedDir    = tradeDir;
      g_tp2Price      = tp2;
      g_tp1Hit        = (InpTPMode != TP_MULTI_TARGET || tp2 == 0);
      g_lastTrailPrice = entryPrice;
      g_beApplied     = false;
      g_tradesToday++;
      g_lastTradeTime = now;

      g_entryPrice = entryPrice;
      g_entrySL    = sl;
      g_currentSL  = sl;
      g_entryTP1   = tp1;
      g_entryTP2   = tp2;
      g_entryScore = score;
      g_entryVwap  = wVwap; g_entryHvn  = wHvn;
      g_entryPPoc  = wPPoc; g_entryPVa  = wPVa;
      g_entryPHvn  = wPHvn; g_entryDelta = wDelta;
      g_entryRoc   = wRoc;  g_entryVol  = wVol;

      if(InpSignalLog)
         LogSignalEvaluation(now, mid, tradeDir,
            wVwap, wHvn, wPPoc, wPVa, wPHvn, wDelta, wRoc, wVol,
            score, sl, tp1, tp2, "TRADE", "");

      Print((tradeDir > 0 ? "LONG" : "SHORT"),
            " | Score: ", score,
            " | Entry: ", entryPrice,
            " | SL: ", sl, " (", slDist / _Point, " pts)",
            " | TP1: ", tp1, " (", tp1Dist / _Point, " pts)",
            " | TP2: ", (tp2 > 0 ? DoubleToString(tp2, _Digits) : "none"),
            " | DeltaROC: ", DoubleToString(GetDeltaROC(now), 1),
            " | Lots: ", lots);
   }
   else
   {
      if(InpSignalLog)
         LogSignalEvaluation(now, mid, tradeDir,
            wVwap, wHvn, wPPoc, wPVa, wPHvn, wDelta, wRoc, wVol,
            score, sl, tp1, tp2, "FAIL", "order_failed");
   }
}

//+------------------------------------------------------------------+
//| Stop distance validation                                        |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point;

   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double freezeDist = freezeLevel * _Point;

   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double result = MathMax(minDist, spread * 2.0);
   result = MathMax(result, freezeDist);

   if(result <= 0)
      result = 20 * _Point;

   return result;
}

double EnforceMinDistance(double entry, double stopPrice, int dir,
                          bool isSL, double minDist)
{
   double dist = MathAbs(entry - stopPrice);

   if(dist < minDist)
   {
      if(isSL)
      {
         if(dir > 0) stopPrice = entry - minDist;
         else        stopPrice = entry + minDist;
      }
      else
      {
         if(dir > 0) stopPrice = entry + minDist;
         else        stopPrice = entry - minDist;
      }
   }

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      stopPrice = MathRound(stopPrice / tickSize) * tickSize;

   return NormalizeDouble(stopPrice, _Digits);
}

//+------------------------------------------------------------------+
//| ATR Breakeven                                                    |
//+------------------------------------------------------------------+
void CheckBreakeven()
{
   if(g_atrHandle == INVALID_HANDLE) return;
   if(!PositionSelectByTicket(g_managedTicket)) return;

   double atr[];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atr) < 1) return;

   double atrVal   = atr[0];
   double trigger  = atrVal * InpBE_ATR_Multi;
   double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL    = PositionGetDouble(POSITION_SL);
   double curTP    = PositionGetDouble(POSITION_TP);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double newSL;

   if(g_managedDir > 0)
   {
      if(bid - posPrice < trigger) return;
      newSL = posPrice + InpBE_Offset;
      if(newSL <= curSL) return;
      if(newSL >= bid) return;
   }
   else
   {
      if(posPrice - ask < trigger) return;
      newSL = posPrice - InpBE_Offset;
      if(curSL != 0 && newSL >= curSL) return;
      if(newSL <= ask) return;
   }

   newSL = NormalizeDouble(newSL, _Digits);
   if(g_trade.PositionModify(g_managedTicket, newSL, curTP))
   {
      g_beApplied = true;
      g_currentSL = newSL;
      Print("Breakeven applied. SL moved to ", newSL,
            " (ATR=", DoubleToString(atrVal, _Digits),
            ", trigger=", DoubleToString(trigger, _Digits), ")");
   }
}

//+------------------------------------------------------------------+
//| Signal Log                                                       |
//+------------------------------------------------------------------+
void OpenSignalLog()
{
   string filename = InpSignalLogFolder + "\\SignalLog_" + _Symbol + ".csv";

   g_signalLogHandle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(g_signalLogHandle == INVALID_HANDLE)
   {
      Print("Warning: cannot open signal log: ", filename);
      return;
   }

   ulong fileSize = FileSize(g_signalLogHandle);
   if(fileSize > 0)
   {
      FileSeek(g_signalLogHandle, 0, SEEK_END);
      g_signalLogHeaderWritten = true;
   }
   else
   {
      FileWrite(g_signalLogHandle,
         "Time", "Price", "Direction",
         "VWAP_Align", "At_HVN_POC", "Prior_POC", "Prior_VA", "Prior_HVN",
         "Delta_Favor", "Delta_ROC", "Vol_Above_Avg",
         "Total_Score", "Min_Score",
         "SL", "SL_Dist", "TP1", "TP1_Dist", "TP2",
         "RR_Ratio",
         "Outcome", "Reject_Reason",
         "Close_Price", "Close_Time", "Result", "PnL", "Duration_Min");
      g_signalLogHeaderWritten = true;
   }
}

void LogSignalEvaluation(datetime time, double price, int direction,
                          int vwap, int atHvn, int priorPoc, int priorVa, int priorHvn,
                          int deltaFav, int deltaRoc, int volAbove,
                          int totalScore,
                          double sl, double tp1, double tp2,
                          string outcome, string rejectReason)
{
   if(g_signalLogHandle == INVALID_HANDLE) return;

   double slDist  = (sl > 0)  ? MathAbs(price - sl) : 0;
   double tp1Dist = (tp1 > 0) ? MathAbs(tp1 - price) : 0;
   double rr      = (slDist > 0 && tp1Dist > 0) ? tp1Dist / slDist : 0;

   FileWrite(g_signalLogHandle,
      TimeToString(time, TIME_DATE | TIME_SECONDS),
      DoubleToString(price, _Digits),
      (direction > 0 ? "LONG" : "SHORT"),
      IntegerToString(vwap),
      IntegerToString(atHvn),
      IntegerToString(priorPoc),
      IntegerToString(priorVa),
      IntegerToString(priorHvn),
      IntegerToString(deltaFav),
      IntegerToString(deltaRoc),
      IntegerToString(volAbove),
      IntegerToString(totalScore),
      IntegerToString(InpMinScore),
      (sl > 0  ? DoubleToString(sl, _Digits) : ""),
      DoubleToString(slDist, 2),
      (tp1 > 0 ? DoubleToString(tp1, _Digits) : ""),
      DoubleToString(tp1Dist, 2),
      (tp2 > 0 ? DoubleToString(tp2, _Digits) : ""),
      DoubleToString(rr, 2),
      outcome,
      rejectReason,
      "", "", "", "", "");
   FileFlush(g_signalLogHandle);
}

//+------------------------------------------------------------------+
//| Log trade close with win/loss result                              |
//+------------------------------------------------------------------+
void LogTradeClose(ulong ticket)
{
   if(g_signalLogHandle == INVALID_HANDLE) return;
   if(g_entryPrice <= 0) return;

   // Select deal history for this position
   datetime closeTime = TimeCurrent();
   double closePrice = 0;
   double profit = 0;
   string result = "UNKNOWN";
   datetime entryTime = 0;

   HistorySelect(TimeCurrent() - 86400 * 2, TimeCurrent());

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong dealPos = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPos != ticket) continue;

      long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealEntry == DEAL_ENTRY_IN)
      {
         entryTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      }
      else if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
      {
         closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         profit += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         profit += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      }
   }

   if(closePrice <= 0)
   {
      closePrice = (g_managedDir > 0) ?
         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   }

   // Determine result by comparing close price to entry levels and modified SL
   double slDist = MathAbs(closePrice - g_entrySL);
   double modSlDist = (g_currentSL != 0 && g_currentSL != g_entrySL)
                      ? MathAbs(closePrice - g_currentSL) : 9999;
   double tp1Dist = (g_entryTP1 > 0) ? MathAbs(closePrice - g_entryTP1) : 9999;
   double tp2Dist = (g_entryTP2 > 0) ? MathAbs(closePrice - g_entryTP2) : 9999;
   double tolerance = InpPriceStep * 3;

   if(slDist <= tolerance)
      result = "LOSS_SL";
   else if(modSlDist <= tolerance && profit <= 0)
      result = "LOSS_TRAIL";
   else if(modSlDist <= tolerance && profit > 0)
      result = "WIN_TRAIL";
   else if(tp2Dist <= tolerance)
      result = "WIN_TP2";
   else if(tp1Dist <= tolerance)
      result = "WIN_TP1";
   else if(profit > 0)
      result = "WIN_OTHER";
   else if(profit < 0)
      result = "LOSS_OTHER";
   else
      result = "BREAKEVEN";

   double durationMin = (entryTime > 0) ? (double)(closeTime - entryTime) / 60.0 : 0;

   // Write CLOSE row with entry factors + exit details
   FileWrite(g_signalLogHandle,
      (entryTime > 0 ? TimeToString(entryTime, TIME_DATE | TIME_SECONDS) :
                        TimeToString(closeTime, TIME_DATE | TIME_SECONDS)),
      DoubleToString(g_entryPrice, _Digits),
      (g_managedDir > 0 ? "LONG" : "SHORT"),
      IntegerToString(g_entryVwap),
      IntegerToString(g_entryHvn),
      IntegerToString(g_entryPPoc),
      IntegerToString(g_entryPVa),
      IntegerToString(g_entryPHvn),
      IntegerToString(g_entryDelta),
      IntegerToString(g_entryRoc),
      IntegerToString(g_entryVol),
      IntegerToString(g_entryScore),
      IntegerToString(InpMinScore),
      DoubleToString(g_entrySL, _Digits),
      DoubleToString(MathAbs(g_entryPrice - g_entrySL), 2),
      DoubleToString(g_entryTP1, _Digits),
      DoubleToString(MathAbs(g_entryTP1 - g_entryPrice), 2),
      (g_entryTP2 > 0 ? DoubleToString(g_entryTP2, _Digits) : ""),
      DoubleToString((MathAbs(g_entryTP1 - g_entryPrice) /
                      MathMax(MathAbs(g_entryPrice - g_entrySL), 0.01)), 2),
      "CLOSE",
      result,
      DoubleToString(closePrice, _Digits),
      TimeToString(closeTime, TIME_DATE | TIME_SECONDS),
      result,
      DoubleToString(profit, 2),
      DoubleToString(durationMin, 1));
   FileFlush(g_signalLogHandle);

   Print("Trade closed: ", result,
         " | Entry: ", g_entryPrice,
         " | Close: ", closePrice,
         " | P&L: ", DoubleToString(profit, 2),
         " | Duration: ", DoubleToString(durationMin, 1), " min");

   g_entryPrice = 0;
}

//+------------------------------------------------------------------+
//| Confluence scoring with individual factor breakdown               |
//+------------------------------------------------------------------+
int GetConfluenceScoreDetailed(double price, int direction,
                                int &outVwap, int &outAtHvn, int &outPriorPoc,
                                int &outPriorVa, int &outPriorHvn,
                                int &outDeltaFav, int &outDeltaRoc, int &outVolAbove)
{
   int score = 0;
   datetime now = TimeCurrent();
   outVwap = outAtHvn = outPriorPoc = outPriorVa = outPriorHvn = 0;
   outDeltaFav = outDeltaRoc = outVolAbove = 0;

   // 1. VWAP alignment — prerequisite or +1
   bool vwapOk = (direction > 0 && price <= g_vwap) ||
                 (direction < 0 && price >= g_vwap);
   if(vwapOk) outVwap = 1;
   if(InpVwapPrereq)
   {
      if(!vwapOk) return -1;
   }
   else if(vwapOk) score++;

   int lvl = FindNearestLevel(g_currentProfile, price);
   if(lvl >= 0)
   {
      if(g_currentProfile.levels[lvl].isHVN ||
         g_currentProfile.levels[lvl].isPOC)
      { score += 2; outAtHvn = 2; }
   }

   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      double dist = MathAbs(price - g_priorProfiles[d].pocPrice) / InpPriceStep;
      if(dist <= InpProximitySteps) { score += InpPriorPOCWeight; outPriorPoc = InpPriorPOCWeight; break; }
   }

   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      if(direction > 0)
      {
         double dist = MathAbs(price - g_priorProfiles[d].valPrice) / InpPriceStep;
         if(dist <= InpProximitySteps) { score++; outPriorVa = 1; break; }
      }
      else
      {
         double dist = MathAbs(price - g_priorProfiles[d].vahPrice) / InpPriceStep;
         if(dist <= InpProximitySteps) { score++; outPriorVa = 1; break; }
      }
   }

   // 5. Near prior HVN — prerequisite or +1
   bool hvnOk2 = false;
   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      for(int i = 0; i < g_priorProfiles[d].levelCount; i++)
      {
         if(!g_priorProfiles[d].levels[i].isHVN) continue;
         double dist = MathAbs(price - g_priorProfiles[d].levels[i].price) / InpPriceStep;
         if(dist <= InpProximitySteps) { hvnOk2 = true; d = InpDaysBack; break; }
      }
   }
   if(hvnOk2) outPriorHvn = 1;
   if(InpPriorHvnPrereq)
   {
      if(!hvnOk2) return -1;
   }
   else if(hvnOk2) score++;

   if(direction > 0 && g_cumDelta > 0) { score++; outDeltaFav = 1; }
   if(direction < 0 && g_cumDelta < 0) { score++; outDeltaFav = 1; }

   // 7. Delta ROC — prerequisite or +1
   double roc = GetDeltaROC(now);
   bool rocOk = (direction > 0 && roc >= InpDeltaRocMin) ||
                (direction < 0 && roc <= -InpDeltaRocMin);
   if(rocOk) outDeltaRoc = 1;
   if(InpDeltaRocPrereq)
   {
      if(!rocOk) return -1;
   }
   else if(rocOk) score++;

   // Volume above average — logged only, not scored (unreliable in tester)
   if(IsVolumeAboveAverage()) outVolAbove = 1;

   return score;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int FindNearestLevel(DailyProfile &profile, double price)
{
   if(profile.levelCount == 0) return -1;

   int best = 0;
   double bestDist = MathAbs(price - profile.levels[0].price);

   for(int i = 1; i < profile.levelCount; i++)
   {
      double dist = MathAbs(price - profile.levels[i].price);
      if(dist < bestDist)
      {
         bestDist = dist;
         best = i;
      }
   }
   return best;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
      }
   }
   return false;
}

double GetLotSize(double slDistance)
{
   if(InpRiskPercent <= 0 || slDistance <= 0)
      return InpLotSize;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0) return InpLotSize;

   double slTicks = slDistance / tickSize;
   double lots    = riskMoney / (slTicks * tickValue);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return lots;
}
//+------------------------------------------------------------------+
