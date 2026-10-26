//+------------------------------------------------------------------+
//|                                              NasdaqFairPrice.mq5 |
//|  Nasdaq 100 CFD, M1. New York open "fair price" strategy:        |
//|   - 09:30 NY opening candle -> continuation trade                |
//|   - 09:35-11:00 NY -> displacement / break-of-structure          |
//|     reversion trades back toward the 09:30 fair price            |
//|   - Optional red-folder news mode (CSV) from the news release    |
//+------------------------------------------------------------------+
#property copyright "emoorby"
#property version   "1.00"
#property description "NY-open fair price EA for Nasdaq 100 (USTEC / NAS100) on M1."
#property description "All distances are in index points (1.0 = one Nasdaq point)."
#property description "All session times are New York time."

#include <Trade\Trade.mqh>

CTrade trade;

//--- enums
enum ENUM_TZ_MODE
  {
   TZ_NY_PLUS7  = 0, // Server = New York + 7h (IC Markets, Vantage)
   TZ_FIXED_GMT = 1, // Fixed GMT offset (no DST on server)
   TZ_AUTO      = 2  // Auto-detect (live only; tester uses NY+7)
  };

enum ENUM_SETUP_MODE
  {
   SETUP_BOTH      = 0, // Displacement or break of structure
   SETUP_DISP_ONLY = 1, // Displacement only
   SETUP_BOS_ONLY  = 2  // Break of structure only (A+ setups)
  };

enum ENUM_RISK_MODE
  {
   RISK_PCT_BALANCE = 0, // % of balance
   RISK_FIXED_MONEY = 1, // Fixed amount (account currency)
   RISK_FIXED_LOTS  = 2  // Fixed lots
  };

enum ENUM_NEWS_CONT_MODE
  {
   NEWSCONT_TAKE      = 0, // Take it as normal
   NEWSCONT_TOWARD_FP = 1, // Only if it points toward the news fair price
   NEWSCONT_SKIP      = 2  // Skip it
  };

enum ENUM_TP_MODE
  {
   TP_FIXED = 0, // Fixed points (Take profit input)
   TP_FAIR  = 1  // At fair price
  };

enum ENUM_DAY_RESET
  {
   RESET_SERVER_MIDNIGHT = 0, // Server midnight
   RESET_NY_MIDNIGHT     = 1  // New York midnight
  };

//--- inputs
input group "=== General ==="
input ulong               InpMagic               = 930930;              // Magic number
input string              InpComment             = "NasdaqFP";          // Trade comment prefix

input group "=== Time (New York time, HH:MM) ==="
input ENUM_TZ_MODE        InpTZMode              = TZ_NY_PLUS7;         // Broker server time model
input int                 InpServerGMTOffset     = 2;                   // Server GMT offset (Fixed GMT mode only)
input string              InpSessionStart        = "09:30";             // Session open / continuation candle
input string              InpFairPriceTime       = "09:30";             // Fair price = open of this candle (at or before session open)
input int                 InpContWindowMin       = 5;                   // Continuation window (minutes)
input string              InpSessionEnd          = "11:00";             // No new entries from this time

input group "=== Continuation (opening candle) ==="
input bool                InpUseContinuation     = true;                // Trade the opening candle continuation
input double              InpContMinBody         = 2.0;                 // Min opening candle body (pts), else skip
input double              InpContMaxAgainstWick  = 0.0;                 // Skip if wick against trade > % of range (0 = off)
input double              InpBigCandleBody       = 25.0;                // Body above this uses the big SL/TP
input double              InpContSL              = 25.0;                // Stop loss (pts)
input double              InpContTP              = 38.0;                // Take profit (pts)
input double              InpContBigSL           = 50.0;                // Big candle stop loss (pts)
input double              InpContBigTP           = 76.0;                // Big candle take profit (pts)
input bool                InpContExitOnOppBOS    = false;               // Close continuation on opposite break of structure

input group "=== Reversion (toward fair price) ==="
input bool                InpUseReversion        = true;                // Trade reversion toward fair price
input ENUM_SETUP_MODE     InpSetupMode           = SETUP_BOTH;          // Entry setups
input double              InpSL                  = 25.0;                // Stop loss (pts)
input double              InpTP                  = 38.0;                // Take profit (pts)
input ENUM_TP_MODE        InpTPMode              = TP_FIXED;            // Take profit mode
input double              InpTPFairFraction      = 1.0;                 // Fair price TP: fraction of the way (1 = all the way)
input double              InpTPFairBuffer        = 2.0;                 // Fair price TP: stop short of it by (pts)
input double              InpMinBody             = 3.0;                 // Displacement: min body (pts)
input double              InpMinBodyExcess       = 0.0;                 // Displacement: body must beat previous by (pts)
input double              InpMinBodyRangeRatio   = 0.5;                 // Displacement: min body / range (0-1)
input bool                InpRequireCloseBeyond  = false;               // Displacement: must close beyond previous wick
input int                 InpCombineBars         = 1;                   // Displacement: combine up to N candles (1 = off)
input int                 InpSwingStrength       = 2;                   // BOS: bars each side of a swing point
input int                 InpSwingLookback       = 30;                  // BOS: bars to look back for swings
input double              InpMinDistToFPMult     = 1.0;                 // Skip if distance to fair price < TP x this
input bool                InpLayerOnlyOnBOS      = true;                // Extra position same direction only on BOS

input group "=== Trend-day protection ==="
input int                 InpDirStopLosses       = 1;                   // A: stop a direction after N losses in it today (0 = off)
input bool                InpUseFPReset          = false;               // B: move fair price after consolidation + break away
input int                 InpConsolBars          = 10;                  // B: consolidation length (bars)
input double              InpConsolMaxRange      = 25.0;                // B: consolidation max high-low range (pts)
input double              InpResetMinDist        = 38.0;                // B: consolidation must be this far from fair price (pts)
input int                 InpMaxFPResets         = 3;                   // B: max fair price moves per day
input bool                InpDirStopResetOnFP    = true;                // A+B: clear direction stops when fair price moves

input group "=== Trade limits ==="
input int                 InpMaxTradesPerDay     = 5;                   // Max entries per NY day
input int                 InpMaxOpenPositions    = 3;                   // Max open positions at once
input bool                InpCloseAtSessionEnd   = false;               // Close open trades at session end

input group "=== Risk ==="
input ENUM_RISK_MODE      InpRiskMode            = RISK_PCT_BALANCE;    // Position sizing
input double              InpRiskPct             = 0.5;                 // Risk per trade (% of balance)
input double              InpRiskMoney           = 100.0;               // Risk per trade (fixed amount)
input double              InpFixedLots           = 0.10;                // Lots (fixed lots mode)
input double              InpMaxLots             = 50.0;                // Max lots per trade
input double              InpCommissionPerLot    = 0.0;                 // Round-turn commission per lot (account ccy)
input bool                InpAllowMinLot         = false;               // Use min lot if risk sizing is below it

input group "=== Execution ==="
input double              InpMaxSpread           = 3.0;                 // Max spread to enter (pts)
input double              InpSlippage            = 3.0;                 // Max slippage (pts)

input group "=== Prop-firm guards (equity based) ==="
input double              InpDailyLossPct        = 3.0;                 // Daily loss limit % (0 = off)
input double              InpMaxDrawdownPct      = 0.0;                 // Max drawdown % (0 = off)
input double              InpDDReferenceBalance  = 0.0;                 // Max DD reference balance (0 = balance at start)
input ENUM_DAY_RESET      InpDailyResetMode      = RESET_SERVER_MIDNIGHT; // Daily loss reset time

input group "=== News (CSV in Terminal\\Common\\Files) ==="
input bool                InpUseNewsFile         = true;                // Load news CSV
input string              InpNewsFile            = "NasdaqFairPrice_news.csv"; // News file name
input bool                InpUseNewsMode         = true;                // Pre-open news sets fair price and starts trading
input string              InpNewsModeEarliest    = "08:00";             // Earliest pre-open news time used
input ENUM_NEWS_CONT_MODE InpNewsContMode        = NEWSCONT_TOWARD_FP;  // 09:30 continuation on news days
input bool                InpNewsKeepFairPrice   = true;                // Keep pre-news fair price after 09:30
input bool                InpNewsDaysOnly        = false;               // Only trade on days with pre-open news
input bool                InpNewsBlackout        = false;               // Block entries around in-session news
input int                 InpNewsBlackoutBefore  = 2;                   // Blackout minutes before
input int                 InpNewsBlackoutAfter   = 2;                   // Blackout minutes after

input group "=== Display / logging ==="
input bool                InpDrawFairPrice       = true;                // Draw fair price line
input bool                InpShowPanel           = true;                // Show status panel
input bool                InpWriteLog            = true;                // Write CSV log (Common\Files)
input color               InpFairPriceColor      = clrDodgerBlue;       // Fair price line colour

//--- parsed settings
int      g_sessStart, g_sessEnd, g_contEnd, g_newsEarliest, g_fpTime;
int      g_maxOpen;
bool     g_isTester, g_isOptim;

//--- news
datetime g_newsNY[];
string   g_newsLabel[];

//--- day state (NY trading day)
datetime g_nyDay        = 0;
datetime g_lastBar      = 0;
double   g_fairPrice    = 0.0;
datetime g_fpBarServer  = 0;
bool     g_newsFPSet    = false;
bool     g_anchorFPSet  = false;
int      g_newsMin      = -1;
datetime g_newsEventNY  = 0;
string   g_newsName     = "";
bool     g_sessionOpenSeen = false;
bool     g_sessionClosed   = false;
ulong    g_contTicket   = 0;
int      g_tradesToday  = 0;
int      g_fpResets     = 0;
datetime g_dirStopFrom  = 0;
string   g_fpLineName   = "";

//--- guard state
datetime g_guardDayKey   = 0;
double   g_guardDayStart = 0.0;
bool     g_dayHalted     = false;
bool     g_allHalted     = false;
double   g_initBalance   = 0.0;
string   g_lastStatus    = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   g_isOptim  = (bool)MQLInfoInteger(MQL_OPTIMIZATION);

   if(!ParseHHMM(InpSessionStart, g_sessStart) || !ParseHHMM(InpSessionEnd, g_sessEnd) ||
      !ParseHHMM(InpNewsModeEarliest, g_newsEarliest) || !ParseHHMM(InpFairPriceTime, g_fpTime))
     {
      Print("Invalid time input. Use HH:MM, e.g. 09:30");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_contEnd = g_sessStart + MathMax(InpContWindowMin, 1);
   if(g_fpTime > g_sessStart)
     {
      Print("Fair price time must be at or before the session open");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(g_sessEnd <= g_contEnd)
     {
      Print("Session end must be after the continuation window");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpSL <= 0 || InpTP <= 0 || InpContSL <= 0 || InpContTP <= 0 || InpContBigSL <= 0 || InpContBigTP <= 0)
     {
      Print("Stop loss and take profit inputs must be positive");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpCombineBars < 1 || InpSwingStrength < 1 || InpSwingLookback < InpSwingStrength * 2 + 2 || InpConsolBars < 2)
     {
      Print("Invalid displacement / swing settings");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpNewsDaysOnly && (!InpUseNewsFile || !InpUseNewsMode))
     {
      Print("News days only needs the news file and news mode switched on");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpTPMode == TP_FAIR && (InpTPFairFraction <= 0 || InpTPFairFraction > 1.0))
     {
      Print("Fair price TP fraction must be above 0 and at most 1");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_maxOpen = MathMax(InpMaxOpenPositions, 1);
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("WARNING: account is not a hedging account. Layering is disabled (max 1 open position).");
      g_maxOpen = 1;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints((ulong)MathMax(1.0, MathRound(InpSlippage / _Point)));

   if(InpTZMode == TZ_AUTO && g_isTester)
      Print("Auto time zone is not available in the tester; using Server = New York + 7h.");

   g_initBalance = (InpDDReferenceBalance > 0) ? InpDDReferenceBalance : AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpUseNewsFile)
      LoadNews();
   if(InpNewsDaysOnly && ArraySize(g_newsNY) == 0)
     {
      Print("News days only is on but no news events were loaded");
      return(INIT_FAILED);
     }

   datetime now = TimeCurrent();
   datetime ny  = ToNY(now);
   PrintFormat("Server time %s = New York %s. Today's %s NY candle = server %s. Check this matches your chart.",
               TimeToString(now, TIME_DATE | TIME_MINUTES), TimeToString(ny, TIME_DATE | TIME_MINUTES),
               InpSessionStart, TimeToString(NYToServer(DayStart(ny) + g_sessStart * 60), TIME_DATE | TIME_MINUTES));

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   PrintFormat("%s: digits %d, tick size %s, tick value %s, min lot %s, lot step %s, stops level %d pts",
               _Symbol, _Digits, DoubleToString(tickSize, _Digits),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 4),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));

   UpdateGuards();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateGuards();

   datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 == 0 || t0 == g_lastBar)
      return;
   g_lastBar = t0;

   OnNewBar(t0);
   ShowPanel();
  }

//+------------------------------------------------------------------+
//| Main logic, once per new M1 bar. Signals use the bar just closed |
//+------------------------------------------------------------------+
void OnNewBar(datetime t0)
  {
   int need = MathMax(MathMax(InpSwingLookback + InpSwingStrength + 3, InpCombineBars + 3), InpConsolBars + 3);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, need, rates) < need)
      return;

   datetime nyNow  = ToNY(t0);
   datetime nySig  = ToNY(rates[1].time);
   int      nowMin = MinuteOfDay(nyNow);
   int      sigMin = MinuteOfDay(nySig);

   if(DayStart(nyNow) != g_nyDay)
      ResetDay(DayStart(nyNow), nowMin);

   MqlDateTime d;
   TimeToStruct(nyNow, d);
   if(d.day_of_week == 0 || d.day_of_week == 6)
      return;

   bool sigToday = (DayStart(nySig) == g_nyDay);
   bool tradeDay = !(InpNewsDaysOnly && g_newsMin < 0);   // news days only: skip days without pre-open news

   //--- pre-open news: fair price = price at the release
   if(sigToday && !g_newsFPSet && g_newsMin >= 0 && sigMin >= g_newsMin && sigMin < g_sessStart)
     {
      SetFairPrice(rates[1].open, rates[1].time);
      g_newsFPSet = true;
      LogEvent("NEWS_FP", 0, g_newsName, g_fairPrice, 0, 0, 0, "fair price set at news release");
     }

   //--- fair price anchored before the open (InpFairPriceTime), unless news set it
   if(sigToday && !g_anchorFPSet && !g_newsFPSet && g_fpTime < g_sessStart && sigMin >= g_fpTime && sigMin < g_sessStart)
     {
      SetFairPrice(rates[1].open, rates[1].time);
      g_anchorFPSet = true;
      LogEvent("ANCHOR_FP", 0, InpFairPriceTime, g_fairPrice, 0, 0, 0, "fair price set at " + InpFairPriceTime);
     }

   //--- session open: fair price and continuation
   if(sigToday && !g_sessionOpenSeen && sigMin >= g_sessStart)
     {
      g_sessionOpenSeen = true;
      if(!(g_newsFPSet && InpNewsKeepFairPrice) && !(g_anchorFPSet && !g_newsFPSet))
        {
         if(sigMin < g_contEnd)
            SetFairPrice(rates[1].open, rates[1].time);
         else
            RecoverSessionFairPrice();
         LogEvent("SESSION_FP", 0, "", g_fairPrice, 0, 0, 0, "");
        }
      if(InpUseContinuation && sigMin == g_sessStart && tradeDay)
         DoContinuation(rates);
     }

   //--- continuation exit on opposite structure break
   if(InpContExitOnOppBOS && g_contTicket > 0)
     {
      if(!PositionSelectByTicket(g_contTicket))
         g_contTicket = 0;
      else
        {
         int cdir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(IsBOS(rates, -cdir))
           {
            if(trade.PositionClose(g_contTicket))
               LogEvent("CONT_EXIT", cdir, "OPP_BOS", rates[1].close, 0, 0, 0, "opposite break of structure");
            g_contTicket = 0;
           }
        }
     }

   //--- session end
   if(nowMin >= g_sessEnd)
     {
      if(InpCloseAtSessionEnd && !g_sessionClosed)
        {
         CloseAll("session end");
         g_sessionClosed = true;
        }
      return;
     }

   //--- option B: move fair price when price consolidates then breaks further away
   if(InpUseFPReset && sigToday && g_fairPrice > 0 && InReversionWindow(sigMin) && g_fpResets < InpMaxFPResets)
      CheckFairPriceReset(rates);

   //--- reversion
   if(InpUseReversion && tradeDay && sigToday && g_fairPrice > 0 && InReversionWindow(sigMin))
      EvaluateReversion(rates, nyNow);
  }

//+------------------------------------------------------------------+
bool InReversionWindow(int sigMin)
  {
   if(sigMin >= g_sessStart && sigMin < g_contEnd)
      return(false);                          // continuation window
   if(sigMin >= g_contEnd && sigMin < g_sessEnd)
      return(true);
   if(g_newsFPSet && sigMin >= g_newsMin && sigMin < g_sessStart)
      return(true);                           // news mode before the open
   return(false);
  }

//+------------------------------------------------------------------+
void DoContinuation(const MqlRates &rates[])
  {
   double o = rates[1].open, c = rates[1].close, h = rates[1].high, l = rates[1].low;
   double body  = MathAbs(c - o);
   double range = h - l;
   if(body < InpContMinBody || range <= 0)
     {
      LogEvent("CONT_SKIP", 0, "CONT", c, 0, 0, 0, "opening candle body too small");
      return;
     }
   int dir = (c > o) ? 1 : -1;

   if(InpContMaxAgainstWick > 0)
     {
      double wick = (dir > 0) ? (h - c) : (c - l);
      if(wick / range * 100.0 > InpContMaxAgainstWick)
        {
         LogEvent("CONT_SKIP", dir, "CONT", c, 0, 0, 0, "wick against trade too large");
         return;
        }
     }

   if(g_newsFPSet)
     {
      if(InpNewsContMode == NEWSCONT_SKIP)
        {
         LogEvent("CONT_SKIP", dir, "CONT", c, 0, 0, 0, "news day");
         return;
        }
      if(InpNewsContMode == NEWSCONT_TOWARD_FP && (g_fairPrice - c) * dir <= 0)
        {
         LogEvent("CONT_SKIP", dir, "CONT", c, 0, 0, 0, "news day, not toward fair price");
         return;
        }
     }

   bool   big = (body > InpBigCandleBody);
   double sl  = big ? InpContBigSL : InpContSL;
   double tp  = big ? InpContBigTP : InpContTP;
   ulong  ticket = 0;
   if(TryEnter(dir, sl, tp, big ? "CONT_BIG" : "CONT", false, ticket))
      g_contTicket = ticket;
  }

//+------------------------------------------------------------------+
void EvaluateReversion(const MqlRates &rates[], datetime nyNow)
  {
   double c1 = rates[1].close;
   int dir = 0;
   if(c1 > g_fairPrice)
      dir = -1;
   else
      if(c1 < g_fairPrice)
         dir = 1;
   if(dir == 0)
      return;

   bool disp = IsDisplacement(rates, dir);
   bool bos  = IsBOS(rates, dir);

   bool signal = false;
   switch(InpSetupMode)
     {
      case SETUP_BOTH:
         signal = disp || bos;
         break;
      case SETUP_DISP_ONLY:
         signal = disp;
         break;
      case SETUP_BOS_ONLY:
         signal = bos;
         break;
     }
   if(!signal)
      return;

   string type = (disp && bos) ? "BOS+DISP" : (bos ? "BOS" : "DISP");

   if(InpNewsBlackout && InNewsBlackout(nyNow))
     {
      LogEvent("SKIP", dir, type, c1, 0, 0, 0, "news blackout");
      return;
     }
   if(InpLayerOnlyOnBOS && !bos && CountOpen(dir) > 0)
     {
      LogEvent("SKIP", dir, type, c1, 0, 0, 0, "layering needs BOS");
      return;
     }
   if(InpDirStopLosses > 0 && CountDirLosses(dir) >= InpDirStopLosses)
     {
      LogEvent("SKIP", dir, type, c1, 0, 0, 0, "direction stopped after losses");
      return;
     }

   ulong ticket = 0;
   TryEnter(dir, InpSL, InpTP, type, true, ticket);
  }

//+------------------------------------------------------------------+
//| Displacement: candle toward fair price whose body beats the      |
//| previous candle's body (optionally several candles combined)     |
//+------------------------------------------------------------------+
bool IsDisplacement(const MqlRates &rates[], int dir)
  {
   double body1 = (rates[1].close - rates[1].open) * dir;
   double range1 = rates[1].high - rates[1].low;
   double body2 = MathAbs(rates[2].close - rates[2].open);

   if(body1 > 0 && range1 > 0 &&
      body1 >= InpMinBody &&
      body1 >= body2 + InpMinBodyExcess &&
      body1 / range1 >= InpMinBodyRangeRatio)
     {
      bool beyond = (dir < 0) ? (rates[1].close < rates[2].low) : (rates[1].close > rates[2].high);
      if(!InpRequireCloseBeyond || beyond)
         return(true);
     }

   //--- combined: candles 1..k all toward fair price beat the opposing candle k+1
   for(int k = 2; k <= InpCombineBars; k++)
     {
      if((rates[k].close - rates[k].open) * dir <= 0)
         break;                                // run of same-colour candles ended
      int opp = k + 1;
      if((rates[opp].close - rates[opp].open) * dir >= 0)
         continue;                             // candle before the run is not opposing

      double hi = rates[1].high, lo = rates[1].low;
      for(int i = 2; i <= k; i++)
        {
         hi = MathMax(hi, rates[i].high);
         lo = MathMin(lo, rates[i].low);
        }
      double cBody  = (rates[1].close - rates[k].open) * dir;
      double cRange = hi - lo;
      double oBody  = MathAbs(rates[opp].close - rates[opp].open);
      bool   beyond = (dir < 0) ? (rates[1].close < rates[opp].low) : (rates[1].close > rates[opp].high);

      if(cRange > 0 && cBody >= InpMinBody && cBody >= oBody + InpMinBodyExcess &&
         cBody / cRange >= InpMinBodyRangeRatio && beyond)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Break of structure: candle toward fair price closes beyond an    |
//| unbroken swing low (shorts) / swing high (longs)                 |
//+------------------------------------------------------------------+
bool IsBOS(const MqlRates &rates[], int dir)
  {
   if((rates[1].close - rates[1].open) * dir <= 0)
      return(false);

   int S = InpSwingStrength;
   int maxJ = MathMin(InpSwingLookback, ArraySize(rates) - 1 - S);
   for(int j = 2 + S; j <= maxJ; j++)
     {
      if(!IsSwing(rates, j, S, dir))
         continue;
      double level = (dir < 0) ? rates[j].low : rates[j].high;

      bool broken = false;
      for(int k = 2; k < j && !broken; k++)
         broken = (dir < 0) ? (rates[k].close < level) : (rates[k].close > level);
      if(broken)
         continue;

      if((dir < 0 && rates[1].close < level) || (dir > 0 && rates[1].close > level))
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Swing low (dir<0) or swing high (dir>0) at bar j                 |
//+------------------------------------------------------------------+
bool IsSwing(const MqlRates &rates[], int j, int S, int dir)
  {
   for(int i = 1; i <= S; i++)
     {
      if(dir < 0)
        {
         if(rates[j - i].low <= rates[j].low || rates[j + i].low < rates[j].low)
            return(false);
        }
      else
        {
         if(rates[j - i].high >= rates[j].high || rates[j + i].high > rates[j].high)
            return(false);
        }
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Entry with all filters, sizing and fill-relative SL/TP           |
//+------------------------------------------------------------------+
bool TryEnter(int dir, double slPts, double tpPts, string type, bool checkDist, ulong &ticket)
  {
   ticket = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (dir > 0) ? ask : bid;

   if(g_allHalted || g_dayHalted)
     {
      LogEvent("SKIP", dir, type, price, 0, 0, 0, "risk guard halted");
      return(false);
     }
   if(g_tradesToday >= InpMaxTradesPerDay)
     {
      LogEvent("SKIP", dir, type, price, 0, 0, 0, "max trades per day");
      return(false);
     }
   if(CountOpen(0) >= g_maxOpen)
     {
      LogEvent("SKIP", dir, type, price, 0, 0, 0, "max open positions");
      return(false);
     }
   if(ask - bid > InpMaxSpread)
     {
      LogEvent("SKIP", dir, type, price, 0, 0, 0, "spread " + DoubleToString(ask - bid, 2));
      return(false);
     }
   if(checkDist)
     {
      double dist = (dir > 0) ? (g_fairPrice - ask) : (bid - g_fairPrice);
      if(dist < tpPts * InpMinDistToFPMult)
        {
         LogEvent("SKIP", dir, type, price, 0, 0, 0, "too close to fair price (" + DoubleToString(dist, 1) + ")");
         return(false);
        }
      //--- target the fair price itself (never closer than the fixed TP)
      if(InpTPMode == TP_FAIR)
         tpPts = MathMax(InpTP, dist * InpTPFairFraction - InpTPFairBuffer);
     }

   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slPts <= stopsLevel || tpPts <= stopsLevel)
     {
      LogEvent("SKIP", dir, type, price, 0, 0, 0, "SL/TP inside broker stops level");
      return(false);
     }

   double riskMoney = 0;
   double lots = CalcLots(slPts, riskMoney);
   if(lots <= 0)
     {
      LogEvent("SKIP", dir, type, price, 0, 0, 0, "lot size below broker minimum");
      return(false);
     }
   if(!RiskFitsGuards(riskMoney))
     {
      LogEvent("SKIP", dir, type, price, 0, 0, lots, "trade risk would breach a loss limit");
      return(false);
     }

   double margin = 0;
   ENUM_ORDER_TYPE otype = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(otype, _Symbol, lots, price, margin) && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      LogEvent("SKIP", dir, type, price, 0, 0, lots, "not enough free margin");
      return(false);
     }

   double sl = NormPrice(price - dir * slPts);
   double tp = NormPrice(price + dir * tpPts);
   string cmt = InpComment + "|" + type;

   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0, sl, tp, cmt) : trade.Sell(lots, _Symbol, 0, sl, tp, cmt);
   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      LogEvent("FAIL", dir, type, price, sl, tp, lots, trade.ResultRetcodeDescription());
      return(false);
     }
   g_tradesToday++;

   //--- re-anchor SL/TP to the actual fill price
   double fill = trade.ResultPrice();
   ulong deal = trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
     {
      ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      fill = HistoryDealGetDouble(deal, DEAL_PRICE);
     }
   if(ticket > 0 && fill > 0 && PositionSelectByTicket(ticket))
     {
      double nsl = NormPrice(fill - dir * slPts);
      double ntp = NormPrice(fill + dir * tpPts);
      double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(MathAbs(nsl - sl) >= tick * 0.5 || MathAbs(ntp - tp) >= tick * 0.5)
        {
         if(trade.PositionModify(ticket, nsl, ntp))
           {
            sl = nsl;
            tp = ntp;
           }
        }
     }

   LogEvent("ENTRY", dir, type, fill, sl, tp, lots,
            "risk " + DoubleToString(riskMoney, 2) + ", trade " + IntegerToString(g_tradesToday) + " today");
   return(true);
  }

//+------------------------------------------------------------------+
double CalcLots(double slPts, double &riskMoney)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLots);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(tickSize <= 0 || tickValue <= 0 || step <= 0)
      return(0);

   double lossPerLot = slPts / tickSize * tickValue + InpCommissionPerLot;
   double lots;
   if(InpRiskMode == RISK_FIXED_LOTS)
      lots = InpFixedLots;
   else
     {
      double target = (InpRiskMode == RISK_PCT_BALANCE)
                      ? AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0
                      : InpRiskMoney;
      lots = target / lossPerLot;
     }

   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minLot)
     {
      if(InpRiskMode == RISK_FIXED_LOTS || InpAllowMinLot)
         lots = minLot;
      else
         return(0);
     }
   lots = MathMin(lots, maxLot);
   int volDigits = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   lots = NormalizeDouble(lots, volDigits);
   riskMoney = lots * lossPerLot;
   return(lots);
  }

//+------------------------------------------------------------------+
//| Prop-firm style guards on account equity                         |
//+------------------------------------------------------------------+
void UpdateGuards()
  {
   datetime now = TimeCurrent();
   datetime key = (InpDailyResetMode == RESET_SERVER_MIDNIGHT) ? DayStart(now) : DayStart(ToNY(now));
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(key != g_guardDayKey)
     {
      g_guardDayKey   = key;
      g_guardDayStart = MathMax(balance, equity);
      g_dayHalted     = false;
     }

   if(InpDailyLossPct > 0 && !g_dayHalted && equity <= DailyFloor())
     {
      g_dayHalted = true;
      CloseAll("daily loss limit");
      LogEvent("HALT_DAY", 0, "", equity, 0, 0, 0, "daily loss limit reached");
     }
   if(InpMaxDrawdownPct > 0 && !g_allHalted && equity <= DrawdownFloor())
     {
      g_allHalted = true;
      CloseAll("max drawdown");
      LogEvent("HALT_ALL", 0, "", equity, 0, 0, 0, "max drawdown reached, EA stopped");
     }
  }

double DailyFloor()    { return(g_guardDayStart * (1.0 - InpDailyLossPct / 100.0)); }
double DrawdownFloor() { return(g_initBalance * (1.0 - InpMaxDrawdownPct / 100.0)); }

//+------------------------------------------------------------------+
//| Would losing this trade (plus open risk) breach a limit?         |
//+------------------------------------------------------------------+
bool RiskFitsGuards(double riskMoney)
  {
   double worst = AccountInfoDouble(ACCOUNT_EQUITY) - riskMoney - OpenRiskMoney();
   if(InpDailyLossPct > 0 && worst < DailyFloor())
      return(false);
   if(InpMaxDrawdownPct > 0 && worst < DrawdownFloor())
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Money still at risk on open positions (to their stops)           |
//+------------------------------------------------------------------+
double OpenRiskMoney()
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0)
      return(0);

   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      double sl  = PositionGetDouble(POSITION_SL);
      double cur = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(sl <= 0)
         continue;
      //--- equity already includes floating P/L, so count only the move from here to the stop
      double dist = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (cur - sl) : (sl - cur);
      if(dist > 0)
         total += dist / tickSize * tickValue * PositionGetDouble(POSITION_VOLUME);
     }
   return(total);
  }

//+------------------------------------------------------------------+
int CountOpen(int dir)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      int pdir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(dir == 0 || pdir == dir)
         n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
void CloseAll(string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      double px = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(trade.PositionClose(t))
         LogEvent("CLOSE", 0, "", px, 0, 0, 0, reason);
     }
  }

//+------------------------------------------------------------------+
//| New NY trading day: reset state, find news, recover after restart|
//+------------------------------------------------------------------+
void ResetDay(datetime nyDay, int nowMin)
  {
   g_nyDay           = nyDay;
   g_fairPrice       = 0;
   g_fpBarServer     = 0;
   g_newsFPSet       = false;
   g_anchorFPSet     = false;
   g_newsMin         = -1;
   g_newsEventNY     = 0;
   g_newsName        = "";
   g_sessionOpenSeen = false;
   g_sessionClosed   = false;
   g_contTicket      = 0;
   g_fpResets        = 0;
   g_dirStopFrom     = 0;
   g_fpLineName      = "";
   g_tradesToday     = CountEntriesSince(NYToServer(nyDay));

   //--- earliest pre-open news event today
   if(InpUseNewsMode)
     {
      for(int i = 0; i < ArraySize(g_newsNY); i++)
        {
         if(DayStart(g_newsNY[i]) != nyDay)
            continue;
         int m = MinuteOfDay(g_newsNY[i]);
         if(m >= g_newsEarliest && m < g_sessStart && (g_newsMin < 0 || m < g_newsMin))
           {
            g_newsMin     = m;
            g_newsEventNY = g_newsNY[i];
            g_newsName    = g_newsLabel[i];
           }
        }
     }

   //--- EA (re)started mid-day: rebuild fair price from history
   if(g_newsMin >= 0 && nowMin > g_newsMin + 1 && nowMin < g_sessEnd)
     {
      MqlRates r[];
      datetime from = NYToServer(nyDay + g_newsMin * 60);
      if(CopyRates(_Symbol, PERIOD_M1, from, from + 10 * 60, r) > 0)
        {
         SetFairPrice(r[0].open, r[0].time);
         g_newsFPSet = true;
        }
     }
   if(!g_newsFPSet && g_fpTime < g_sessStart && nowMin > g_fpTime + 1 && nowMin < g_sessEnd)
     {
      MqlRates r[];
      datetime from = NYToServer(nyDay + g_fpTime * 60);
      if(CopyRates(_Symbol, PERIOD_M1, from, from + 10 * 60, r) > 0)
        {
         SetFairPrice(r[0].open, r[0].time);
         g_anchorFPSet = true;
        }
     }
   if(nowMin > g_sessStart + 1)
     {
      g_sessionOpenSeen = true;               // never take a late continuation
      if(!(g_newsFPSet && InpNewsKeepFairPrice) && !(g_anchorFPSet && !g_newsFPSet))
         RecoverSessionFairPrice();
     }
  }

//+------------------------------------------------------------------+
void RecoverSessionFairPrice()
  {
   MqlRates r[];
   datetime from = NYToServer(g_nyDay + g_sessStart * 60);
   datetime to   = NYToServer(g_nyDay + g_contEnd * 60);
   if(CopyRates(_Symbol, PERIOD_M1, from, to, r) > 0)
      SetFairPrice(r[0].open, r[0].time);
  }

//+------------------------------------------------------------------+
int CountEntriesSince(datetime fromServer)
  {
   if(!HistorySelect(fromServer, TimeCurrent() + 86400))
      return(0);
   int n = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(d, DEAL_MAGIC) == (long)InpMagic &&
         HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
//| Losing trades in a direction today (since the last fair price    |
//| move when InpDirStopResetOnFP is on)                             |
//+------------------------------------------------------------------+
int CountDirLosses(int dir)
  {
   datetime from = (g_dirStopFrom > 0) ? g_dirStopFrom : NYToServer(g_nyDay);
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return(0);
   int n = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol ||
         HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic ||
         HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      double pl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                  HistoryDealGetDouble(d, DEAL_SWAP);
      if(pl >= 0)
         continue;
      //--- a sell deal closes a buy position
      int pdir = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_SELL) ? 1 : -1;
      if(pdir == dir)
         n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
//| Option B: price holds in a tight range away from fair price,     |
//| then closes out of it further away -> fair price = that range    |
//+------------------------------------------------------------------+
void CheckFairPriceReset(const MqlRates &rates[])
  {
   int N = InpConsolBars;
   double hi = rates[2].high, lo = rates[2].low;
   for(int i = 3; i <= N + 1; i++)
     {
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
     }
   if(hi - lo > InpConsolMaxRange)
      return;

   double c1 = rates[1].close;
   bool up   = (lo > g_fairPrice && c1 > hi && c1 > rates[1].open);
   bool down = (hi < g_fairPrice && c1 < lo && c1 < rates[1].open);
   if(!up && !down)
      return;

   double mid = (hi + lo) / 2.0;
   if(MathAbs(mid - g_fairPrice) < InpResetMinDist)
      return;

   double old = g_fairPrice;
   g_fpResets++;
   SetFairPrice(NormPrice(mid), rates[N + 1].time);
   if(InpDirStopResetOnFP)
      g_dirStopFrom = rates[0].time;
   LogEvent("FP_RESET", up ? 1 : -1, "", g_fairPrice, 0, 0, 0,
            "fair price moved from " + DoubleToString(old, _Digits) + " (move " + IntegerToString(g_fpResets) + ")");
  }

//+------------------------------------------------------------------+
void SetFairPrice(double price, datetime barServer)
  {
   g_fairPrice   = price;
   g_fpBarServer = barServer;
   if(!InpDrawFairPrice || g_isOptim)
      return;

   //--- end the previous line where the new fair price takes over
   datetime nowBar = iTime(_Symbol, PERIOD_M1, 0);
   if(g_fpLineName != "" && ObjectFind(0, g_fpLineName) >= 0)
      ObjectMove(0, g_fpLineName, 1, nowBar, ObjectGetDouble(0, g_fpLineName, OBJPROP_PRICE, 0));

   string name = "NFP_FP_" + TimeToString(g_nyDay, TIME_DATE) + "_" + IntegerToString(g_fpResets) +
                 (g_newsFPSet ? "n" : "");
   g_fpLineName = name;
   datetime to = NYToServer(g_nyDay + g_sessEnd * 60);
   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_TREND, 0, barServer, price, to, price))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpFairPriceColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, "Fair price " + DoubleToString(price, _Digits));
     }
  }

//+------------------------------------------------------------------+
//| News CSV: date,time[,label]  e.g. 2026-03-11,08:30,CPI (NY time) |
//+------------------------------------------------------------------+
void LoadNews()
  {
   ArrayResize(g_newsNY, 0);
   ArrayResize(g_newsLabel, 0);

   int h = FileOpen(InpNewsFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("News file %s not found in Terminal\\Common\\Files (error %d). News mode disabled.",
                  InpNewsFile, GetLastError());
      return;
     }
   int lineNo = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      lineNo++;
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#')
         continue;

      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 2)
         continue;
      string ds = parts[0];
      StringTrimLeft(ds);
      StringTrimRight(ds);
      StringReplace(ds, "-", ".");
      StringReplace(ds, "/", ".");
      string ts = parts[1];
      StringTrimLeft(ts);
      StringTrimRight(ts);
      int mins;
      if(StringLen(ds) != 10 || !ParseHHMM(ts, mins))
        {
         if(StringFind(ds, "date") != 0)
            PrintFormat("News file line %d ignored: %s", lineNo, line);
         continue;                             // header or bad line
        }
      datetime day = StringToTime(ds);
      if(day <= 0)
         continue;
      int k = ArraySize(g_newsNY);
      ArrayResize(g_newsNY, k + 1);
      ArrayResize(g_newsLabel, k + 1);
      g_newsNY[k]    = day + mins * 60;
      g_newsLabel[k] = (n >= 3) ? parts[2] : "news";
      StringTrimLeft(g_newsLabel[k]);
      StringTrimRight(g_newsLabel[k]);
     }
   FileClose(h);
   PrintFormat("Loaded %d news events from %s", ArraySize(g_newsNY), InpNewsFile);
  }

//+------------------------------------------------------------------+
bool InNewsBlackout(datetime nyNow)
  {
   for(int i = 0; i < ArraySize(g_newsNY); i++)
     {
      if(g_newsNY[i] == g_newsEventNY)
         continue;                             // the event driving news mode
      if(MinuteOfDay(g_newsNY[i]) < g_sessStart || DayStart(g_newsNY[i]) != g_nyDay)
         continue;
      if(nyNow >= g_newsNY[i] - InpNewsBlackoutBefore * 60 && nyNow < g_newsNY[i] + InpNewsBlackoutAfter * 60)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Time zone helpers                                                |
//+------------------------------------------------------------------+
datetime ToNY(datetime server)
  {
   if(InpTZMode == TZ_FIXED_GMT)
      return(GMTtoNY(server - InpServerGMTOffset * 3600));
   if(InpTZMode == TZ_AUTO && !g_isTester)
     {
      int off = (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 1800.0) * 1800;
      return(GMTtoNY(server - off));
     }
   return(server - 7 * 3600);
  }

datetime NYToServer(datetime ny)
  {
   datetime s = ny + (ny - ToNY(ny));
   return(ny + (s - ToNY(s)));
  }

datetime GMTtoNY(datetime gmt)
  {
   MqlDateTime g;
   TimeToStruct(gmt, g);
   datetime dstStart = NthSundayUTC(g.year, 3, 2, 7);   // 2nd Sun Mar, 02:00 EST
   datetime dstEnd   = NthSundayUTC(g.year, 11, 1, 6);  // 1st Sun Nov, 02:00 EDT
   bool dst = (gmt >= dstStart && gmt < dstEnd);
   return(gmt - (dst ? 4 : 5) * 3600);
  }

datetime NthSundayUTC(int year, int month, int n, int hourUTC)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = year;
   s.mon  = month;
   s.day  = 1;
   datetime first = StructToTime(s);
   MqlDateTime f;
   TimeToStruct(first, f);
   int add = (7 - f.day_of_week) % 7;
   return(first + (add + 7 * (n - 1)) * 86400 + hourUTC * 3600);
  }

datetime DayStart(datetime t)   { return(t - (t % 86400)); }
int      MinuteOfDay(datetime t) { return((int)((t % 86400) / 60)); }

bool ParseHHMM(string s, int &mins)
  {
   string p[];
   if(StringSplit(s, ':', p) != 2)
      return(false);
   int hh = (int)StringToInteger(p[0]);
   int mm = (int)StringToInteger(p[1]);
   if(hh < 0 || hh > 23 || mm < 0 || mm > 59)
      return(false);
   mins = hh * 60 + mm;
   return(true);
  }

double NormPrice(double p)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0)
      p = MathRound(p / tick) * tick;
   return(NormalizeDouble(p, _Digits));
  }

//+------------------------------------------------------------------+
//| Logging and panel                                                |
//+------------------------------------------------------------------+
void LogEvent(string event, int dir, string type, double price, double sl, double tp, double lots, string note)
  {
   if(!g_isOptim)
      PrintFormat("%s %s %s @%s %s", event, (dir > 0 ? "BUY" : (dir < 0 ? "SELL" : "")), type,
                  DoubleToString(price, _Digits), note);
   if(event == "ENTRY" || event == "SKIP" || event == "FAIL")
      g_lastStatus = event + " " + type + " " + note;
   if(!InpWriteLog || g_isOptim)
      return;

   string file = "NasdaqFairPrice_log_" + _Symbol + ".csv";
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
      FileWrite(h, "server_time", "ny_time", "event", "dir", "type", "fair_price", "price", "sl", "tp", "lots",
                "spread", "trades_today", "note");
   FileSeek(h, 0, SEEK_END);
   datetime now = TimeCurrent();
   FileWrite(h, TimeToString(now, TIME_DATE | TIME_SECONDS), TimeToString(ToNY(now), TIME_DATE | TIME_SECONDS),
             event, (dir > 0 ? "BUY" : (dir < 0 ? "SELL" : "")), type,
             DoubleToString(g_fairPrice, _Digits), DoubleToString(price, _Digits),
             DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), DoubleToString(lots, 2),
             DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
             g_tradesToday, note);
   FileClose(h);
  }

void ShowPanel()
  {
   if(!InpShowPanel || g_isOptim)
      return;
   datetime ny = ToNY(TimeCurrent());
   string s = "NasdaqFairPrice\n";
   s += "New York: " + TimeToString(ny, TIME_DATE | TIME_MINUTES) + "\n";
   s += "Fair price: " + (g_fairPrice > 0 ? DoubleToString(g_fairPrice, _Digits) : "-") +
        (g_newsFPSet ? "  (news: " + g_newsName + ")" : (g_anchorFPSet ? "  (" + InpFairPriceTime + ")" : "")) +
        (g_fpResets > 0 ? "  (moved " + IntegerToString(g_fpResets) + "x)" : "") + "\n";
   if(InpNewsDaysOnly)
      s += (g_newsMin >= 0 ? "News day: " + g_newsName : "Not a news day: no trading") + "\n";
   if(InpDirStopLosses > 0 && g_fairPrice > 0)
      s += "Direction stops: longs " + (CountDirLosses(1) >= InpDirStopLosses ? "STOPPED" : "ok") +
           ", shorts " + (CountDirLosses(-1) >= InpDirStopLosses ? "STOPPED" : "ok") + "\n";
   s += "Trades today: " + IntegerToString(g_tradesToday) + " / " + IntegerToString(InpMaxTradesPerDay) +
        "   Open: " + IntegerToString(CountOpen(0)) + " / " + IntegerToString(g_maxOpen) + "\n";
   if(InpDailyLossPct > 0)
      s += "Daily loss floor: " + DoubleToString(DailyFloor(), 2) + "\n";
   if(g_dayHalted)
      s += "HALTED for the day (daily loss)\n";
   if(g_allHalted)
      s += "HALTED (max drawdown)\n";
   s += "Last: " + g_lastStatus;
   Comment(s);
  }
//+------------------------------------------------------------------+
