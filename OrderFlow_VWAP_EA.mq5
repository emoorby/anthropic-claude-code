//+------------------------------------------------------------------+
//| OrderFlow_VWAP_EA.mq5                                            |
//| Order Flow + VWAP + Volume Profile Strategy                       |
//+------------------------------------------------------------------+
#property copyright "Order Flow VWAP Strategy"
#property version   "1.00"
#property description "Volume Profile with HVN/LVN/POC, VWAP, Delta Volume"

#include <Trade\Trade.mqh>

enum ENUM_DELTA_METHOD
{
   DELTA_AUTO,       // Auto-detect
   DELTA_TICK_FLAGS, // Tick flags (exchange)
   DELTA_TICK_RULE   // Tick rule (CFD/Forex)
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
input double         InpSLPoints         = 50.0;        // Stop Loss (points)
input double         InpTPPoints         = 100.0;       // Take Profit (points)
input int            InpMinDelta         = 30;          // Min |Delta| for Signal

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

   EventSetMillisecondTimer(3000);

   Print("OrderFlow VWAP EA initialized. Delta method: ",
         g_useTickFlags ? "Tick Flags" : "Tick Rule");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   RemoveAllObjects();
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!InpEnableTrading) return;

   datetime now = TimeCurrent();
   if(now < g_todaySessionStart || now > g_todaySessionEnd) return;

   if(!g_currentProfile.isValid) return;

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
      if((ticks[i].flags & TICK_FLAG_BUY) || (ticks[i].flags & TICK_FLAG_SELL))
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
      if(tick.flags & TICK_FLAG_BUY)  return 1;
      if(tick.flags & TICK_FLAG_SELL) return -1;
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
//| Signal logic                                                      |
//+------------------------------------------------------------------+
void CheckSignals()
{
   if(!g_currentProfile.isValid || g_vwap <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   bool aboveVWAP = (mid > g_vwap);
   bool belowVWAP = (mid < g_vwap);

   double sessionDelta = g_cumDelta;
   bool positiveDelta = (sessionDelta > InpMinDelta);
   bool negativeDelta = (sessionDelta < -InpMinDelta);

   int nearestLevel = FindNearestLevel(g_currentProfile, mid);
   if(nearestLevel < 0) return;

   bool atHVN = g_currentProfile.levels[nearestLevel].isHVN ||
                g_currentProfile.levels[nearestLevel].isPOC;
   bool atLVN = g_currentProfile.levels[nearestLevel].isLVN;

   bool nearPriorPOC = false;
   bool nearPriorVAL = false;
   bool nearPriorVAH = false;

   for(int d = 0; d < InpDaysBack; d++)
   {
      if(!g_priorProfiles[d].isValid) continue;
      double dist = MathAbs(mid - g_priorProfiles[d].pocPrice) / InpPriceStep;
      if(dist <= 2) nearPriorPOC = true;
      dist = MathAbs(mid - g_priorProfiles[d].valPrice) / InpPriceStep;
      if(dist <= 2) nearPriorVAL = true;
      dist = MathAbs(mid - g_priorProfiles[d].vahPrice) / InpPriceStep;
      if(dist <= 2) nearPriorVAH = true;
   }

   if(!HasOpenPosition())
   {
      // Long: price at/near VWAP or HVN/POC support, positive delta
      if(belowVWAP && positiveDelta && (atHVN || nearPriorPOC || nearPriorVAL))
      {
         double sl = ask - InpSLPoints * _Point;
         double tp = ask + InpTPPoints * _Point;
         double lots = GetLotSize(InpSLPoints * _Point);
         g_trade.Buy(lots, _Symbol, ask, sl, tp, InpComment + " LONG");
         Print("LONG signal: VWAP=", g_vwap, " Delta=", sessionDelta,
               " at HVN/POC=", atHVN, " nearPriorPOC=", nearPriorPOC);
      }

      // Short: price above VWAP at resistance, negative delta
      if(aboveVWAP && negativeDelta && (atHVN || nearPriorPOC || nearPriorVAH))
      {
         double sl = bid + InpSLPoints * _Point;
         double tp = bid - InpTPPoints * _Point;
         double lots = GetLotSize(InpSLPoints * _Point);
         g_trade.Sell(lots, _Symbol, bid, sl, tp, InpComment + " SHORT");
         Print("SHORT signal: VWAP=", g_vwap, " Delta=", sessionDelta,
               " at HVN/POC=", atHVN, " nearPriorPOC=", nearPriorPOC);
      }
   }
}

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
