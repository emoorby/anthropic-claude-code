//+------------------------------------------------------------------+
//|                                          HiLo_Breakout_EA.mq4   |
//|                        HiLo Breakout Expert Adviser               |
//|                        Based on 3-Level ZZ Semafor Indicator      |
//+------------------------------------------------------------------+
#property copyright "HiLo Breakout EA"
#property link      ""
#property version   "2.10"
#property strict

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED      = 0,  // Fixed Lot Size
   LOT_MODE_RISK_PCT   = 1   // Percentage of Balance
};

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

input string   _sep_general          = ""; // ═══════════════ GENERAL ═══════════════
input int      MagicNumber           = 123456;     // Magic Number
input string   OrderComment          = "HiLo_BRK"; // Order Comment
input bool     EnableLogging         = true;        // Enable Logging

input string   _sep_zzsemafor        = ""; // ══════════ ZZ SEMAFOR ENTRY ═══════════
input bool     UseZZSemaforMethod    = true;        // Enable ZZ Semafor Entry Method
input string   IndicatorName         = "!!!3 level zz semafor mtf alerts nmc-pfeil"; // ZZ Semafor Indicator Name
input string   _sep_er               = ""; // ──────────── Efficiency Ratio ──────────
input string   ER_IndicatorName      = "SqEfficiencyRatio"; // ER Indicator Name
input int      ER_Period             = 48;          // ER Period
input bool     EnableER_Layer1       = true;        // ER Layer 1: Block new orders when ER low
input double   ER_Layer1_MinValue    = 0.30;        // ER Layer 1: Minimum ER value
input bool     EnableER_Layer2       = true;        // ER Layer 2: Delete pending orders when ER drops
input double   ER_Layer2_MinValue    = 0.30;        // ER Layer 2: Minimum ER value

input string   _sep_atrcandle        = ""; // ══════════ ATR CANDLE ENTRY ════════════
input bool     UseATRCandleMethod    = false;       // Enable ATR Candle Entry Method
input ENUM_TIMEFRAMES ATRCandle_TF   = PERIOD_H1;  // ATR Candle: Signal Timeframe
input int      ATRCandle_ATRPeriod   = 14;          // ATR Candle: ATR Period
input double   ATRCandle_Multiplier  = 2.0;         // ATR Candle: Candle size minimum (x ATR)
input double   ATRCandle_ClosePct    = 30.0;        // ATR Candle: Max close distance from extreme (%)
input string   _sep_tw               = ""; // ──────── ATR Candle: Trading Time Windows ────────
input bool     ATRCandle_TW1_Enable  = false;       // Time Window 1: Enable
input int      ATRCandle_TW1_StartH  = 1;           // Time Window 1: Start Hour   (0-23)
input int      ATRCandle_TW1_StartM  = 0;           // Time Window 1: Start Minute (0-59)
input int      ATRCandle_TW1_StopH   = 4;           // Time Window 1: Stop Hour    (0-23)
input int      ATRCandle_TW1_StopM   = 59;          // Time Window 1: Stop Minute  (0-59)
input bool     ATRCandle_TW2_Enable  = false;       // Time Window 2: Enable
input int      ATRCandle_TW2_StartH  = 7;           // Time Window 2: Start Hour   (0-23)
input int      ATRCandle_TW2_StartM  = 0;           // Time Window 2: Start Minute (0-59)
input int      ATRCandle_TW2_StopH   = 11;          // Time Window 2: Stop Hour    (0-23)
input int      ATRCandle_TW2_StopM   = 59;          // Time Window 2: Stop Minute  (0-59)
input bool     ATRCandle_TW3_Enable  = false;       // Time Window 3: Enable
input int      ATRCandle_TW3_StartH  = 13;          // Time Window 3: Start Hour   (0-23)
input int      ATRCandle_TW3_StartM  = 0;           // Time Window 3: Start Minute (0-59)
input int      ATRCandle_TW3_StopH   = 17;          // Time Window 3: Stop Hour    (0-23)
input int      ATRCandle_TW3_StopM   = 59;          // Time Window 3: Stop Minute  (0-59)
input bool     ATRCandle_TW4_Enable  = false;       // Time Window 4: Enable
input int      ATRCandle_TW4_StartH  = 19;          // Time Window 4: Start Hour   (0-23)
input int      ATRCandle_TW4_StartM  = 0;           // Time Window 4: Start Minute (0-59)
input int      ATRCandle_TW4_StopH   = 22;          // Time Window 4: Stop Hour    (0-23)
input int      ATRCandle_TW4_StopM   = 59;          // Time Window 4: Stop Minute  (0-59)
input bool     ATRCandle_TW5_Enable  = false;       // Time Window 5: Enable
input int      ATRCandle_TW5_StartH  = 0;           // Time Window 5: Start Hour   (0-23)
input int      ATRCandle_TW5_StartM  = 0;           // Time Window 5: Start Minute (0-59)
input int      ATRCandle_TW5_StopH   = 23;          // Time Window 5: Stop Hour    (0-23)
input int      ATRCandle_TW5_StopM   = 59;          // Time Window 5: Stop Minute  (0-59)

input string   _sep_filters          = ""; // ══════════════ FILTERS ═════════════════
input double   MaxSpreadPips         = 5.0;         // Max Spread (pips)
input bool     EnableATRFilter       = true;        // Enable ATR Volatility Filter
input double   ATR_MinValue          = 14.0;        // ATR Minimum Value (pips)

input string   _sep_tp               = ""; // ══════════════ PROFIT TARGET ════════════
input int      ATR_Period            = 30;           // ATR Period (chart timeframe)
input int      KAMA_FastPeriod       = 3;            // KAMA Fast Smoothing Period
input double   ProfitTargetFactor    = 4.8;          // Profit Target Factor (x ATR, KAMA-adaptive)

input string   _sep_mgmt             = ""; // ══════════ TRADE MANAGEMENT ════════════
input int      MinModifyIntervalSec  = 10;           // Min seconds between SL/TP modifications
input bool     EnableBreakeven       = true;         // Enable Breakeven
input double   BreakevenTriggerFactor = 0.75;        // Breakeven Trigger Factor (x ATR)
input bool     EnableTrailingStop    = true;         // Enable Trailing Stop
input double   TrailActivationPips   = 70.0;         // Trailing Activation Threshold (pips profit)
input double   TrailSCCoef           = 1.7;          // Trail Distance Coefficient (x SC x ATR)

input string   _sep_risk             = ""; // ══════════ RISK & POSITION SIZING ══════
input double   PipsToRisk            = 56.0;         // Pips to Risk - ZZ Semafor (total)
input ENUM_LOT_MODE LotMode          = LOT_MODE_FIXED; // Lot Sizing Mode
input double   FixedLots             = 0.1;          // Fixed Lot Size
input double   RiskPercent           = 1.0;          // Risk Percent of Balance

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
double   g_pipSize;             // pip size in price terms
int      g_pipDigits;           // number of decimal places for pips
double   g_halfRisk;            // PipsToRisk / 2 in price terms

datetime g_lastM30Bar;          // track M30 bar close for signal detection
datetime g_lastChartBar;        // track chart-timeframe bar for trail distance recalculation

int      g_sellTicket;          // current sell stop ticket
int      g_buyTicket;           // current buy stop ticket

double   g_lastSellValue5;      // last Value5 used for sell order
double   g_lastBuyValue6;       // last Value6 used for buy order

bool     g_sellWaitingSignal;   // waiting for new Value5 after SL/close
bool     g_buyWaitingSignal;    // waiting for new Value6 after SL/close

bool     g_breakevenApplied;    // breakeven already moved for current position

double   g_trailDistancePrice;  // adaptive trail distance in price terms (updated per chart bar)

datetime g_lastATRCandleBar;    // last bar time processed by ATR Candle method
datetime g_lastSLModifyTime;    // throttle: last time SL was modified (seconds)

// Buffer indices for iCustom
const int BUF_VALUE5 = 4;    // Value 5 - local lows  (Sell Stop)
const int BUF_VALUE6 = 5;    // Value 6 - local highs (Buy Stop)

//+------------------------------------------------------------------+
//| Helper: Log function                                              |
//+------------------------------------------------------------------+
void Log(string msg)
{
   if(EnableLogging)
      Print("[HiLo_BRK] ", msg);
}

//+------------------------------------------------------------------+
//| Helper: Calculate pip size                                        |
//+------------------------------------------------------------------+
void CalculatePipSize()
{
   // For XAUUSD and other metals/JPY pairs
   // Standard: if Digits is 2 or 3, pip = 0.01 * 10^(Digits-2)
   // For 5-digit forex pairs: pip = Point * 10
   // For XAUUSD (typically 2 digits): pip = 0.10

   if(Digits == 3 || Digits == 5)
   {
      g_pipSize  = Point * 10.0;
      g_pipDigits = Digits - 1;
   }
   else if(Digits == 2)
   {
      // XAUUSD with 2 decimal places: 1 pip = 0.10
      g_pipSize  = 0.10;
      g_pipDigits = Digits;
   }
   else if(Digits == 1)
   {
      g_pipSize  = 1.0;
      g_pipDigits = Digits;
   }
   else
   {
      // Default: use Point
      g_pipSize  = Point;
      g_pipDigits = Digits;
   }

   Log(StringFormat("Pip size calculated: %s (Digits=%d, Point=%s)",
       DoubleToStr(g_pipSize, Digits), Digits, DoubleToStr(Point, Digits)));
}

//+------------------------------------------------------------------+
//| Helper: Get indicator value from M30                              |
//+------------------------------------------------------------------+
double GetIndicatorValue(int bufferIndex, int shift)
{
   return iCustom(Symbol(), PERIOD_M30, IndicatorName, bufferIndex, shift);
}

//+------------------------------------------------------------------+
//| Helper: Find most recent non-empty indicator value on M30         |
//+------------------------------------------------------------------+
double FindMostRecentValue(int bufferIndex, int &outShift)
{
   int barsM30 = iBars(Symbol(), PERIOD_M30);
   int maxLookback = MathMin(barsM30, 500);

   for(int i = 1; i < maxLookback; i++)
   {
      double val = GetIndicatorValue(bufferIndex, i);
      if(val != 0.0 && val != EMPTY_VALUE)
      {
         outShift = i;
         return val;
      }
   }

   outShift = -1;
   return 0.0;
}

//+------------------------------------------------------------------+
//| Helper: Calculate lot size                                        |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePips)
{
   double lots = FixedLots;

   if(LotMode == LOT_MODE_RISK_PCT)
   {
      double balance    = AccountBalance();
      double riskAmount = balance * (RiskPercent / 100.0);
      double tickValue  = MarketInfo(Symbol(), MODE_TICKVALUE);
      double tickSize   = MarketInfo(Symbol(), MODE_TICKSIZE);

      if(tickValue == 0 || tickSize == 0 || slDistancePips == 0)
      {
         Log("WARNING: Cannot calculate risk lot size - using fixed lots");
         return NormalizeDouble(FixedLots, 2);
      }

      // Convert SL distance from pips to price
      double slDistancePrice = slDistancePips * g_pipSize;
      // How many ticks in the SL distance
      double ticks = slDistancePrice / tickSize;
      // Cost per lot for the SL distance
      double costPerLot = ticks * tickValue;

      if(costPerLot > 0)
         lots = riskAmount / costPerLot;

      Log(StringFormat("Risk calc: Balance=%.2f, Risk%%=%.2f, RiskAmt=%.2f, SL_pips=%.1f, TickVal=%.5f, TickSize=%.5f, Lots=%.4f",
          balance, RiskPercent, riskAmount, slDistancePips, tickValue, tickSize, lots));
   }

   // Normalize lot size
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(minLot, lots);
   lots = MathMin(maxLot, lots);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Helper: Get current spread in pips                                |
//+------------------------------------------------------------------+
double GetSpreadPips()
{
   return (Ask - Bid) / g_pipSize;
}

//+------------------------------------------------------------------+
//| Helper: Get ATR value in pips (chart timeframe)                   |
//+------------------------------------------------------------------+
double GetATRPips()
{
   double atrValue = iATR(Symbol(), Period(), ATR_Period, 1);
   return atrValue / g_pipSize;
}

//+------------------------------------------------------------------+
//| Helper: Get ATR value in price terms (chart timeframe)            |
//+------------------------------------------------------------------+
double GetATRPrice()
{
   return iATR(Symbol(), Period(), ATR_Period, 1);
}

//+------------------------------------------------------------------+
//| Helper: Get Efficiency Ratio value (chart timeframe, shift 1)     |
//+------------------------------------------------------------------+
double GetERValue()
{
   return iCustom(Symbol(), Period(), ER_IndicatorName, ER_Period, 0, 1);
}

//+------------------------------------------------------------------+
//| KAMA: Calculate smoothing constant SC = SC_raw^2                  |
//|   fast_SC = 2 / (KAMA_FastPeriod + 1)                            |
//|   slow_SC = 2 / (ATR_Period + 1)                                  |
//|   SC_raw  = ER * (fast_SC - slow_SC) + slow_SC                    |
//|   SC      = SC_raw^2                                              |
//+------------------------------------------------------------------+
double CalculateKAMASC()
{
   double er     = GetERValue();
   double fastSC = 2.0 / (KAMA_FastPeriod + 1.0);
   double slowSC = 2.0 / (ATR_Period + 1.0);
   double scRaw  = er * (fastSC - slowSC) + slowSC;
   return scRaw * scRaw;  // SC = SC_raw^2
}

//+------------------------------------------------------------------+
//| V2.0 TP Formula: KAMA-adaptive take profit distance               |
//|   TP_dist = ATR * ProfitTargetFactor *                            |
//|             [1 + (ER * ProfitTargetFactor) / KAMA_FastPeriod]     |
//|   Sell TP = entryPrice - TP_dist                                  |
//|   Buy  TP = entryPrice + TP_dist                                  |
//+------------------------------------------------------------------+
double CalculateAdaptiveTP(double entryPrice, bool isBuy)
{
   double atr = GetATRPrice();
   double er  = GetERValue();

   // Guard: if ER unavailable, fall back to base factor (no adaptive adjustment)
   if(er <= 0.0 || er == EMPTY_VALUE)
      er = 0.0;

   double multiplier = ProfitTargetFactor * (1.0 + (er * ProfitTargetFactor) / KAMA_FastPeriod);
   double tpDist     = atr * multiplier;

   if(isBuy)
      return NormalizeDouble(entryPrice + tpDist, Digits);
   else
      return NormalizeDouble(entryPrice - tpDist, Digits);
}

//+------------------------------------------------------------------+
//| Helper: Check if spread filter passes                             |
//+------------------------------------------------------------------+
bool CheckSpreadFilter()
{
   double spread = GetSpreadPips();
   if(spread > MaxSpreadPips)
   {
      Log(StringFormat("Spread filter FAILED: Current spread=%.1f pips > Max=%.1f pips", spread, MaxSpreadPips));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Helper: Check if ATR filter passes                                |
//+------------------------------------------------------------------+
bool CheckATRFilter()
{
   if(!EnableATRFilter)
      return true;

   double atrPips = GetATRPips();
   if(atrPips < ATR_MinValue)
   {
      Log(StringFormat("ATR filter FAILED: ATR=%.1f pips < Min=%.1f pips", atrPips, ATR_MinValue));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Helper: Check if Efficiency Ratio filter passes                   |
//+------------------------------------------------------------------+
bool CheckERFilter()
{
   if(!EnableER_Layer1)
      return true;

   double erValue = GetERValue();
   if(erValue < ER_Layer1_MinValue)
   {
      Log(StringFormat("ER Layer 1 BLOCKED: ER=%.4f < Min=%.4f", erValue, ER_Layer1_MinValue));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Helper: Count open positions with our magic number                |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
               count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Helper: Find our pending order ticket                             |
//+------------------------------------------------------------------+
int FindPendingTicket(int orderType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            if(OrderType() == orderType)
               return OrderTicket();
         }
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Helper: Check if a pending order still exists                     |
//+------------------------------------------------------------------+
bool PendingOrderExists(int ticket)
{
   if(ticket <= 0)
      return false;

   // Check in active orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderTicket() == ticket)
         {
            // It's still there - check if it's still pending
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP ||
               OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT)
               return true;
            else
               return false; // It triggered and became an open position
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Check if a ticket turned into an open position            |
//+------------------------------------------------------------------+
bool OrderTriggered(int ticket)
{
   if(ticket <= 0)
      return false;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderTicket() == ticket)
         {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
               return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Check if order was closed (no longer in active list)      |
//+------------------------------------------------------------------+
bool OrderWasClosed(int ticket)
{
   if(ticket <= 0)
      return false;

   // Check in history
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
      {
         if(OrderTicket() == ticket)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Check if order was stopped out (closed at SL)             |
//+------------------------------------------------------------------+
bool OrderStoppedOut(int ticket)
{
   if(ticket <= 0)
      return false;

   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
      {
         if(OrderTicket() == ticket && OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         {
            // Closed position — was it at SL?
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
            {
               double closePrice = OrderClosePrice();
               double sl = OrderStopLoss();
               if(sl != 0 && MathAbs(closePrice - sl) < g_pipSize)
                  return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Delete a pending order                                    |
//+------------------------------------------------------------------+
bool DeletePendingOrder(int ticket)
{
   if(ticket <= 0)
      return false;

   if(!PendingOrderExists(ticket))
      return false;

   if(OrderDelete(ticket))
   {
      Log(StringFormat("Deleted pending order #%d", ticket));
      return true;
   }
   else
   {
      Log(StringFormat("FAILED to delete pending order #%d, error=%d", ticket, GetLastError()));
      return false;
   }
}

//+------------------------------------------------------------------+
//| Helper: Place a Sell Stop order                                   |
//+------------------------------------------------------------------+
int PlaceSellStop(double value5)
{
   if(!CheckSpreadFilter())
      return -1;
   if(!CheckATRFilter())
      return -1;
   if(!CheckERFilter())
      return -1;

   double entryPrice = NormalizeDouble(value5 - g_halfRisk, Digits);
   double slPrice    = NormalizeDouble(value5 + g_halfRisk, Digits);
   double lots       = CalculateLotSize(PipsToRisk);

   // V2.0: KAMA-adaptive TP formula
   double tpPrice = CalculateAdaptiveTP(entryPrice, false);

   // Minimum distance check
   double stopLevel  = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(Bid - entryPrice < stopLevel)
   {
      Log(StringFormat("REJECTED: Sell Stop too close to market. Entry=%.5f, Bid=%.5f, MinDist=%.5f",
          entryPrice, Bid, stopLevel));
      return -1;
   }

   int ticket = OrderSend(Symbol(), OP_SELLSTOP, lots, entryPrice, 3, slPrice, tpPrice,
                           OrderComment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      Log(StringFormat("SELL STOP placed #%d: Entry=%.5f, SL=%.5f, TP=%.5f, Lots=%.2f, Value5=%.5f",
          ticket, entryPrice, slPrice, tpPrice, lots, value5));
   }
   else
   {
      Log(StringFormat("FAILED to place Sell Stop: Entry=%.5f, SL=%.5f, TP=%.5f, Error=%d",
          entryPrice, slPrice, tpPrice, GetLastError()));
   }

   return ticket;
}

//+------------------------------------------------------------------+
//| Helper: Place a Buy Stop order                                    |
//+------------------------------------------------------------------+
int PlaceBuyStop(double value6)
{
   if(!CheckSpreadFilter())
      return -1;
   if(!CheckATRFilter())
      return -1;
   if(!CheckERFilter())
      return -1;

   double entryPrice = NormalizeDouble(value6 + g_halfRisk, Digits);
   double slPrice    = NormalizeDouble(value6 - g_halfRisk, Digits);
   double lots       = CalculateLotSize(PipsToRisk);

   // V2.0: KAMA-adaptive TP formula
   double tpPrice = CalculateAdaptiveTP(entryPrice, true);

   // Minimum distance check
   double stopLevel  = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(entryPrice - Ask < stopLevel)
   {
      Log(StringFormat("REJECTED: Buy Stop too close to market. Entry=%.5f, Ask=%.5f, MinDist=%.5f",
          entryPrice, Ask, stopLevel));
      return -1;
   }

   int ticket = OrderSend(Symbol(), OP_BUYSTOP, lots, entryPrice, 3, slPrice, tpPrice,
                           OrderComment, MagicNumber, 0, clrBlue);

   if(ticket > 0)
   {
      Log(StringFormat("BUY STOP placed #%d: Entry=%.5f, SL=%.5f, TP=%.5f, Lots=%.2f, Value6=%.5f",
          ticket, entryPrice, slPrice, tpPrice, lots, value6));
   }
   else
   {
      Log(StringFormat("FAILED to place Buy Stop: Entry=%.5f, SL=%.5f, TP=%.5f, Error=%d",
          entryPrice, slPrice, tpPrice, GetLastError()));
   }

   return ticket;
}

//+------------------------------------------------------------------+
//| Helper: Modify a Sell Stop order                                  |
//+------------------------------------------------------------------+
bool ModifySellStop(int ticket, double value5)
{
   if(ticket <= 0 || !PendingOrderExists(ticket))
      return false;

   if(!CheckSpreadFilter())
      return false;
   if(!CheckATRFilter())
      return false;
   if(!CheckERFilter())
      return false;

   double entryPrice = NormalizeDouble(value5 - g_halfRisk, Digits);
   double slPrice    = NormalizeDouble(value5 + g_halfRisk, Digits);

   // Minimum distance check
   double stopLevel  = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(Bid - entryPrice < stopLevel)
   {
      Log(StringFormat("REJECTED modify: Sell Stop too close to market. Entry=%.5f, Bid=%.5f, MinDist=%.5f",
          entryPrice, Bid, stopLevel));
      return false;
   }

   // Delete old and place new (MT4 can't modify pending order price reliably on all brokers)
   if(DeletePendingOrder(ticket))
   {
      int newTicket = PlaceSellStop(value5);
      if(newTicket > 0)
      {
         g_sellTicket = newTicket;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Helper: Modify a Buy Stop order                                   |
//+------------------------------------------------------------------+
bool ModifyBuyStop(int ticket, double value6)
{
   if(ticket <= 0 || !PendingOrderExists(ticket))
      return false;

   if(!CheckSpreadFilter())
      return false;
   if(!CheckATRFilter())
      return false;
   if(!CheckERFilter())
      return false;

   double entryPrice = NormalizeDouble(value6 + g_halfRisk, Digits);
   double slPrice    = NormalizeDouble(value6 - g_halfRisk, Digits);

   // Minimum distance check
   double stopLevel  = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(entryPrice - Ask < stopLevel)
   {
      Log(StringFormat("REJECTED modify: Buy Stop too close to market. Entry=%.5f, Ask=%.5f, MinDist=%.5f",
          entryPrice, Ask, stopLevel));
      return false;
   }

   // Delete old and place new
   if(DeletePendingOrder(ticket))
   {
      int newTicket = PlaceBuyStop(value6);
      if(newTicket > 0)
      {
         g_buyTicket = newTicket;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Initialization: Place initial pending orders                      |
//+------------------------------------------------------------------+
void PlaceInitialOrders()
{
   Log("=== INITIALIZING - Scanning for signals ===");

   // Find most recent Value 5 (local low) for Sell Stop
   int sellShift = -1;
   double value5 = FindMostRecentValue(BUF_VALUE5, sellShift);

   if(value5 > 0 && sellShift >= 0)
   {
      Log(StringFormat("Found Value5 (local low) = %.5f at M30 shift %d", value5, sellShift));
      g_lastSellValue5 = value5;
      g_sellWaitingSignal = false;
      g_sellTicket = PlaceSellStop(value5);
   }
   else
   {
      Log("WARNING: No Value5 found in lookback - Sell Stop not placed");
      g_sellWaitingSignal = true;
   }

   // Find most recent Value 6 (local high) for Buy Stop
   int buyShift = -1;
   double value6 = FindMostRecentValue(BUF_VALUE6, buyShift);

   if(value6 > 0 && buyShift >= 0)
   {
      Log(StringFormat("Found Value6 (local high) = %.5f at M30 shift %d", value6, buyShift));
      g_lastBuyValue6 = value6;
      g_buyWaitingSignal = false;
      g_buyTicket = PlaceBuyStop(value6);
   }
   else
   {
      Log("WARNING: No Value6 found in lookback - Buy Stop not placed");
      g_buyWaitingSignal = true;
   }

   Log("=== INITIALIZATION COMPLETE ===");
}

//+------------------------------------------------------------------+
//| Monitor: Check for new signals on M30 candle close                |
//+------------------------------------------------------------------+
void MonitorM30Candle()
{
   bool hasOpenPosition = (CountOpenPositions() > 0);

   // Check Value 5 on shift 1 (just-closed M30 candle)
   double newValue5 = GetIndicatorValue(BUF_VALUE5, 1);

   if(newValue5 != 0.0 && newValue5 != EMPTY_VALUE)
   {
      // New Value5 detected on last closed candle
      if(MathAbs(newValue5 - g_lastSellValue5) > Point)
      {
         Log(StringFormat("NEW Value5 detected: %.5f (prev: %.5f)", newValue5, g_lastSellValue5));
         g_lastSellValue5 = newValue5;

         // If a position is open, pause all updates to the sell stop
         if(hasOpenPosition)
         {
            Log("Position is open - pausing Sell Stop updates");
         }
         else if(g_sellWaitingSignal)
         {
            // Was waiting for a new signal after SL/close - place new order
            Log("Sell side was waiting for signal - placing new Sell Stop");
            g_sellWaitingSignal = false;
            g_sellTicket = PlaceSellStop(newValue5);
         }
         else if(PendingOrderExists(g_sellTicket))
         {
            // Update existing pending order
            Log("Updating Sell Stop to new Value5");
            ModifySellStop(g_sellTicket, newValue5);
         }
         else if(!OrderTriggered(g_sellTicket))
         {
            // No pending and no open - place fresh
            g_sellTicket = PlaceSellStop(newValue5);
         }
      }
   }

   // Check Value 6 on shift 1 (just-closed M30 candle)
   double newValue6 = GetIndicatorValue(BUF_VALUE6, 1);

   if(newValue6 != 0.0 && newValue6 != EMPTY_VALUE)
   {
      // New Value6 detected on last closed candle
      if(MathAbs(newValue6 - g_lastBuyValue6) > Point)
      {
         Log(StringFormat("NEW Value6 detected: %.5f (prev: %.5f)", newValue6, g_lastBuyValue6));
         g_lastBuyValue6 = newValue6;

         // If a position is open, pause all updates to the buy stop
         if(hasOpenPosition)
         {
            Log("Position is open - pausing Buy Stop updates");
         }
         else if(g_buyWaitingSignal)
         {
            // Was waiting for a new signal after SL/close - place new order
            Log("Buy side was waiting for signal - placing new Buy Stop");
            g_buyWaitingSignal = false;
            g_buyTicket = PlaceBuyStop(newValue6);
         }
         else if(PendingOrderExists(g_buyTicket))
         {
            // Update existing pending order
            Log("Updating Buy Stop to new Value6");
            ModifyBuyStop(g_buyTicket, newValue6);
         }
         else if(!OrderTriggered(g_buyTicket))
         {
            // No pending and no open - place fresh
            g_buyTicket = PlaceBuyStop(newValue6);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Monitor: Check order states (triggered, stopped out, closed)      |
//+------------------------------------------------------------------+
void MonitorOrderStates()
{
   // --- Check Sell Side ---
   if(g_sellTicket > 0 && !g_sellWaitingSignal)
   {
      // Was it a pending that triggered into a position?
      if(OrderTriggered(g_sellTicket))
      {
         // Position is open - nothing to do, let it run
      }
      else if(!PendingOrderExists(g_sellTicket))
      {
         // Ticket no longer exists as pending or open - check history
         if(OrderWasClosed(g_sellTicket))
         {
            Log(StringFormat("Sell order #%d was CLOSED (SL hit or manual close)", g_sellTicket));
            g_sellTicket = -1;
            g_sellWaitingSignal = true;
            g_breakevenApplied = false;
            Log("Sell side now WAITING for new Value5 signal before re-entry");
         }
      }
   }

   // --- Check Buy Side ---
   if(g_buyTicket > 0 && !g_buyWaitingSignal)
   {
      if(OrderTriggered(g_buyTicket))
      {
         // Position is open - nothing to do
      }
      else if(!PendingOrderExists(g_buyTicket))
      {
         if(OrderWasClosed(g_buyTicket))
         {
            Log(StringFormat("Buy order #%d was CLOSED (SL hit or manual close)", g_buyTicket));
            g_buyTicket = -1;
            g_buyWaitingSignal = true;
            g_breakevenApplied = false;
            Log("Buy side now WAITING for new Value6 signal before re-entry");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| V2.0: Recalculate adaptive trail distance on each chart bar       |
//|   distance = TrailSCCoef * SC * ATR                               |
//|   SC = SC_raw^2, SC_raw = ER*(fast_SC - slow_SC) + slow_SC        |
//|   Called once per chart-timeframe bar close.                      |
//+------------------------------------------------------------------+
void RecalculateTrailDistance()
{
   double atr = GetATRPrice();
   double er  = GetERValue();

   // Guard: skip if indicators are not ready
   if(atr <= 0.0 || er <= 0.0 || er == EMPTY_VALUE)
   {
      Log("Trail distance recalculation skipped: ATR or ER not ready");
      return;
   }

   double sc = CalculateKAMASC();
   g_trailDistancePrice = TrailSCCoef * sc * atr;

   Log(StringFormat("Trail distance recalculated: %.5f price units (ER=%.4f, SC=%.6f, ATR=%.5f, Coef=%.2f)",
       g_trailDistancePrice, er, sc, atr, TrailSCCoef));
}

//+------------------------------------------------------------------+
//| V2.0: Manage breakeven and adaptive trailing stop                 |
//|   Activation : fixed TrailActivationPips (default 70 pips)        |
//|   Distance   : g_trailDistancePrice (recalculated per bar)        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atrPips            = GetATRPips();
   double breakevenThreshold = atrPips * BreakevenTriggerFactor;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      double openPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double newSL     = currentSL;

      if(type == OP_BUY)
      {
         double profitPips = (Bid - openPrice) / g_pipSize;

         // Breakeven (triggered at ATR * BreakevenTriggerFactor)
         if(EnableBreakeven && !g_breakevenApplied && profitPips >= breakevenThreshold)
         {
            double beSL = NormalizeDouble(openPrice, Digits);
            if(beSL > currentSL || currentSL == 0)
            {
               newSL = beSL;
               g_breakevenApplied = true;
               Log(StringFormat("BREAKEVEN BUY #%d: Moving SL to entry %.5f (profit=%.1f pips, trigger=%.1f pips [ATR*%.2f])",
                   OrderTicket(), beSL, profitPips, breakevenThreshold, BreakevenTriggerFactor));
            }
         }

         // V2.0 Trailing stop: fixed pip activation, adaptive SC-based distance
         if(EnableTrailingStop && profitPips >= TrailActivationPips && g_trailDistancePrice > 0)
         {
            double trailSL = NormalizeDouble(Bid - g_trailDistancePrice, Digits);
            if(trailSL > newSL || newSL == 0)
            {
               Log(StringFormat("TRAILING BUY #%d: Moving SL to %.5f (profit=%.1f pips, activation=%.1f pips, trail_dist=%.5f)",
                   OrderTicket(), trailSL, profitPips, TrailActivationPips, g_trailDistancePrice));
               newSL = trailSL;
            }
         }
      }
      else // OP_SELL
      {
         double profitPips = (openPrice - Ask) / g_pipSize;

         // Breakeven (triggered at ATR * BreakevenTriggerFactor)
         if(EnableBreakeven && !g_breakevenApplied && profitPips >= breakevenThreshold)
         {
            double beSL = NormalizeDouble(openPrice, Digits);
            if(beSL < currentSL || currentSL == 0)
            {
               newSL = beSL;
               g_breakevenApplied = true;
               Log(StringFormat("BREAKEVEN SELL #%d: Moving SL to entry %.5f (profit=%.1f pips, trigger=%.1f pips [ATR*%.2f])",
                   OrderTicket(), beSL, profitPips, breakevenThreshold, BreakevenTriggerFactor));
            }
         }

         // V2.0 Trailing stop: fixed pip activation, adaptive SC-based distance
         if(EnableTrailingStop && profitPips >= TrailActivationPips && g_trailDistancePrice > 0)
         {
            double trailSL = NormalizeDouble(Ask + g_trailDistancePrice, Digits);
            if(trailSL < newSL || newSL == 0)
            {
               Log(StringFormat("TRAILING SELL #%d: Moving SL to %.5f (profit=%.1f pips, activation=%.1f pips, trail_dist=%.5f)",
                   OrderTicket(), trailSL, profitPips, TrailActivationPips, g_trailDistancePrice));
               newSL = trailSL;
            }
         }
      }

      // Apply SL modification if changed by at least 1 pip — preserve current TP
      // Throttle: respect minimum interval between modifications to avoid broker overload
      if(MathAbs(newSL - currentSL) > g_pipSize && newSL != 0)
      {
         if(TimeCurrent() - g_lastSLModifyTime < MinModifyIntervalSec)
            continue;

         if(!OrderModify(OrderTicket(), openPrice, newSL, OrderTakeProfit(), 0, clrYellow))
         {
            Log(StringFormat("FAILED to modify SL for #%d: newSL=%.5f, error=%d",
                OrderTicket(), newSL, GetLastError()));
         }
         else
         {
            g_lastSLModifyTime = TimeCurrent();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| V2.0: Update TP dynamically every tick for open positions         |
//|   TP recalculated using current ATR and ER (shift 1 = last bar)   |
//|   Only calls OrderModify when TP changes by at least 1 pip.       |
//+------------------------------------------------------------------+
void UpdateDynamicTP()
{
   // Guard: skip if indicators are not ready
   double atrCheck = GetATRPrice();
   double erCheck  = GetERValue();
   if(atrCheck <= 0.0 || erCheck <= 0.0 || erCheck == EMPTY_VALUE)
      return;

   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber)
         continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      bool   isBuy      = (type == OP_BUY);
      double openPrice  = OrderOpenPrice();
      double currentTP  = OrderTakeProfit();
      double newTP      = CalculateAdaptiveTP(openPrice, isBuy);

      // Sanity check: TP must be a minimum broker distance from current price
      if(isBuy)
      {
         if(newTP - Ask < stopLevel)
         {
            Log(StringFormat("Dynamic TP for BUY #%d skipped: newTP=%.5f too close to Ask=%.5f (minDist=%.5f)",
                OrderTicket(), newTP, Ask, stopLevel));
            continue;
         }
      }
      else
      {
         if(Bid - newTP < stopLevel)
         {
            Log(StringFormat("Dynamic TP for SELL #%d skipped: newTP=%.5f too close to Bid=%.5f (minDist=%.5f)",
                OrderTicket(), newTP, Bid, stopLevel));
            continue;
         }
      }

      // Only modify if TP changed by more than 1 pip to avoid broker spam
      if(MathAbs(newTP - currentTP) > g_pipSize)
      {
         if(!OrderModify(OrderTicket(), openPrice, OrderStopLoss(), newTP, 0, clrCyan))
         {
            Log(StringFormat("FAILED to update dynamic TP for #%d: newTP=%.5f, error=%d",
                OrderTicket(), newTP, GetLastError()));
         }
         else
         {
            Log(StringFormat("DYNAMIC TP updated #%d: TP %.5f → %.5f (ATR=%.5f, ER=%.4f)",
                OrderTicket(), currentTP, newTP, GetATRPrice(), GetERValue()));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ATR Candle: Draw label above signal candle                        |
//|   Shows ATR value and candle size at the time of the signal.      |
//+------------------------------------------------------------------+
void DrawATRCandleLabel(datetime barTime, double candleHigh, double atrValue,
                        double candleSize, bool isBuy)
{
   string objName   = "ATRCandle_" + IntegerToString((int)barTime);
   string labelText = StringFormat("ATR:%.2f  Sz:%.2f", atrValue, candleSize);
   double labelPrice = candleHigh + 10.0 * g_pipSize;
   color  labelColor = isBuy ? clrDodgerBlue : clrOrangeRed;

   ObjectDelete(objName);

   if(!ObjectCreate(objName, OBJ_TEXT, 0, barTime, labelPrice))
   {
      Log(StringFormat("ATR Candle label create failed: error=%d", GetLastError()));
      return;
   }

   ObjectSetText(objName, labelText, 8, "Arial", labelColor);
}

//+------------------------------------------------------------------+
//| ATR Candle: Remove all chart labels created by this method        |
//+------------------------------------------------------------------+
void DeleteAllATRCandleObjects()
{
   for(int i = ObjectsTotal() - 1; i >= 0; i--)
   {
      string name = ObjectName(i);
      if(StringFind(name, "ATRCandle_") == 0)
         ObjectDelete(name);
   }
}

//+------------------------------------------------------------------+
//| ATR Candle: Place market order with SL at opposite candle end     |
//+------------------------------------------------------------------+
bool PlaceATRCandleMarketOrder(bool isBuy, double slPrice, double candleHigh,
                               datetime barTime, double atrValue, double candleSize)
{
   if(!CheckSpreadFilter())
      return false;

   double entryPrice = isBuy ? Ask : Bid;
   double stopLevel  = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double slDistance = MathAbs(entryPrice - slPrice);

   if(slDistance < stopLevel)
   {
      Log(StringFormat("ATR Candle %s rejected: SL too close. Dist=%.5f, Min=%.5f",
          isBuy ? "BUY" : "SELL", slDistance, stopLevel));
      return false;
   }

   double slPips  = slDistance / g_pipSize;
   double lots    = CalculateLotSize(slPips);
   double tpPrice = CalculateAdaptiveTP(entryPrice, isBuy);

   int ticket = OrderSend(Symbol(), isBuy ? OP_BUY : OP_SELL, lots, entryPrice, 3,
                          slPrice, tpPrice, OrderComment, MagicNumber, 0,
                          isBuy ? clrBlue : clrRed);

   if(ticket > 0)
   {
      Log(StringFormat("ATR Candle %s #%d: Entry=%.5f, SL=%.5f, TP=%.5f, Lots=%.2f, ATR=%.5f, CandleSz=%.5f",
          isBuy ? "BUY" : "SELL", ticket, entryPrice, slPrice, tpPrice, lots,
          atrValue, candleSize));
      DrawATRCandleLabel(barTime, candleHigh, atrValue, candleSize, isBuy);
      return true;
   }

   Log(StringFormat("ATR Candle %s FAILED: Entry=%.5f, SL=%.5f, TP=%.5f, Error=%d",
       isBuy ? "BUY" : "SELL", entryPrice, slPrice, tpPrice, GetLastError()));
   return false;
}

//+------------------------------------------------------------------+
//| ATR Candle: Check if a time falls within a start-stop range      |
//|   Handles ranges that cross midnight (e.g. 22:00 - 02:00).       |
//+------------------------------------------------------------------+
bool IsInTimeRange(int startH, int startM, int stopH, int stopM)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int current = dt.hour * 60 + dt.min;
   int start   = startH  * 60 + startM;
   int stop    = stopH   * 60 + stopM;

   if(start <= stop)
      return current >= start && current <= stop;
   else // crosses midnight
      return current >= start || current <= stop;
}

//+------------------------------------------------------------------+
//| ATR Candle: Check if current server time is within any enabled   |
//|   trading time window.                                            |
//|   If all windows are disabled, all times are permitted.           |
//+------------------------------------------------------------------+
bool IsWithinATRCandleTimeWindow()
{
   // No windows enabled → unrestricted trading
   if(!ATRCandle_TW1_Enable && !ATRCandle_TW2_Enable && !ATRCandle_TW3_Enable &&
      !ATRCandle_TW4_Enable && !ATRCandle_TW5_Enable)
      return true;

   if(ATRCandle_TW1_Enable && IsInTimeRange(ATRCandle_TW1_StartH, ATRCandle_TW1_StartM,
                                            ATRCandle_TW1_StopH,  ATRCandle_TW1_StopM))
      return true;
   if(ATRCandle_TW2_Enable && IsInTimeRange(ATRCandle_TW2_StartH, ATRCandle_TW2_StartM,
                                            ATRCandle_TW2_StopH,  ATRCandle_TW2_StopM))
      return true;
   if(ATRCandle_TW3_Enable && IsInTimeRange(ATRCandle_TW3_StartH, ATRCandle_TW3_StartM,
                                            ATRCandle_TW3_StopH,  ATRCandle_TW3_StopM))
      return true;
   if(ATRCandle_TW4_Enable && IsInTimeRange(ATRCandle_TW4_StartH, ATRCandle_TW4_StartM,
                                            ATRCandle_TW4_StopH,  ATRCandle_TW4_StopM))
      return true;
   if(ATRCandle_TW5_Enable && IsInTimeRange(ATRCandle_TW5_StartH, ATRCandle_TW5_StartM,
                                            ATRCandle_TW5_StopH,  ATRCandle_TW5_StopM))
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| ATR Candle: Scan signal timeframe for new bar and check signal    |
//|   Signal : candle range > ATRCandle_Multiplier * ATR(period)      |
//|   Buy    : bullish candle, close within ATRCandle_ClosePct% of high|
//|   Sell   : bearish candle, close within ATRCandle_ClosePct% of low |
//|   Entry  : market order; SL at opposite candle extreme            |
//+------------------------------------------------------------------+
void MonitorATRCandleSignals()
{
   datetime currentBar = iTime(Symbol(), ATRCandle_TF, 0);
   if(currentBar == g_lastATRCandleBar)
      return;  // no new bar yet

   g_lastATRCandleBar = currentBar;

   // Do not open a new trade while one is already open
   if(CountOpenPositions() > 0)
   {
      Log("ATR Candle: position already open - skipping signal check");
      return;
   }

   // Check trading time windows
   if(!IsWithinATRCandleTimeWindow())
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      Log(StringFormat("ATR Candle: outside trading time windows (%02d:%02d server time) - skipping",
          dt.hour, dt.min));
      return;
   }

   // Signal candle = last closed bar (shift 1) on signal timeframe
   double candleHigh  = iHigh(Symbol(),  ATRCandle_TF, 1);
   double candleLow   = iLow(Symbol(),   ATRCandle_TF, 1);
   double candleOpen  = iOpen(Symbol(),  ATRCandle_TF, 1);
   double candleClose = iClose(Symbol(), ATRCandle_TF, 1);
   datetime barTime   = iTime(Symbol(),  ATRCandle_TF, 1);

   double candleRange = candleHigh - candleLow;
   if(candleRange <= 0)
      return;

   double atrValue = iATR(Symbol(), ATRCandle_TF, ATRCandle_ATRPeriod, 1);
   if(atrValue <= 0)
      return;

   // Size condition: full range must exceed multiplier * ATR
   if(candleRange <= ATRCandle_Multiplier * atrValue)
      return;

   bool isBull = (candleClose > candleOpen);
   bool isBear = (candleClose < candleOpen);

   if(isBull)
   {
      // Close proximity: close must be within ATRCandle_ClosePct% of the high
      double distPct = (candleHigh - candleClose) / candleRange * 100.0;
      if(distPct > ATRCandle_ClosePct)
      {
         Log(StringFormat("ATR Candle BUY skipped: close %.1f%% from high > limit %.1f%%",
             distPct, ATRCandle_ClosePct));
         return;
      }

      Log(StringFormat("ATR Candle BUY signal: Range=%.5f, ATR=%.5f (x%.2f), ClosePct=%.1f%%",
          candleRange, atrValue, candleRange / atrValue, distPct));
      PlaceATRCandleMarketOrder(true, candleLow, candleHigh, barTime, atrValue, candleRange);
   }
   else if(isBear)
   {
      // Close proximity: close must be within ATRCandle_ClosePct% of the low
      double distPct = (candleClose - candleLow) / candleRange * 100.0;
      if(distPct > ATRCandle_ClosePct)
      {
         Log(StringFormat("ATR Candle SELL skipped: close %.1f%% from low > limit %.1f%%",
             distPct, ATRCandle_ClosePct));
         return;
      }

      Log(StringFormat("ATR Candle SELL signal: Range=%.5f, ATR=%.5f (x%.2f), ClosePct=%.1f%%",
          candleRange, atrValue, candleRange / atrValue, distPct));
      PlaceATRCandleMarketOrder(false, candleHigh, candleHigh, barTime, atrValue, candleRange);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Log("=== HiLo Breakout EA v2.10 Starting ===");
   Log(StringFormat("Entry Methods: ZZ Semafor=%s, ATR Candle=%s",
       (UseZZSemaforMethod ? "ON" : "OFF"), (UseATRCandleMethod ? "ON" : "OFF")));
   Log(StringFormat("Symbol: %s, Digits: %d, Point: %s", Symbol(), Digits, DoubleToStr(Point, Digits)));
   Log(StringFormat("Settings: PipsToRisk=%.1f, MaxSpread=%.1f, ATR_Period=%d",
       PipsToRisk, MaxSpreadPips, ATR_Period));
   Log(StringFormat("ATR Filter: %s, Min=%.1f pips", (EnableATRFilter ? "ON" : "OFF"), ATR_MinValue));
   Log(StringFormat("KAMA: FastPeriod=%d, SlowPeriod=%d (ATR_Period)", KAMA_FastPeriod, ATR_Period));
   Log(StringFormat("ER Layer 1 (block orders): %s, Min=%.2f | Layer 2 (delete pending): %s, Min=%.2f | Period=%d, Indicator=%s",
       (EnableER_Layer1 ? "ON" : "OFF"), ER_Layer1_MinValue,
       (EnableER_Layer2 ? "ON" : "OFF"), ER_Layer2_MinValue,
       ER_Period, ER_IndicatorName));
   if(UseATRCandleMethod)
   {
      Log(StringFormat("ATR Candle: TF=%s, ATRPeriod=%d, Multiplier=%.2f, ClosePct=%.1f%%",
          EnumToString(ATRCandle_TF), ATRCandle_ATRPeriod, ATRCandle_Multiplier, ATRCandle_ClosePct));
      bool anyTW = (ATRCandle_TW1_Enable || ATRCandle_TW2_Enable || ATRCandle_TW3_Enable ||
                    ATRCandle_TW4_Enable || ATRCandle_TW5_Enable);
      if(!anyTW)
      {
         Log("ATR Candle Time Windows: all disabled — trading unrestricted by time");
      }
      else
      {
         if(ATRCandle_TW1_Enable) Log(StringFormat("ATR Candle TW1: %02d:%02d - %02d:%02d",
             ATRCandle_TW1_StartH, ATRCandle_TW1_StartM, ATRCandle_TW1_StopH, ATRCandle_TW1_StopM));
         if(ATRCandle_TW2_Enable) Log(StringFormat("ATR Candle TW2: %02d:%02d - %02d:%02d",
             ATRCandle_TW2_StartH, ATRCandle_TW2_StartM, ATRCandle_TW2_StopH, ATRCandle_TW2_StopM));
         if(ATRCandle_TW3_Enable) Log(StringFormat("ATR Candle TW3: %02d:%02d - %02d:%02d",
             ATRCandle_TW3_StartH, ATRCandle_TW3_StartM, ATRCandle_TW3_StopH, ATRCandle_TW3_StopM));
         if(ATRCandle_TW4_Enable) Log(StringFormat("ATR Candle TW4: %02d:%02d - %02d:%02d",
             ATRCandle_TW4_StartH, ATRCandle_TW4_StartM, ATRCandle_TW4_StopH, ATRCandle_TW4_StopM));
         if(ATRCandle_TW5_Enable) Log(StringFormat("ATR Candle TW5: %02d:%02d - %02d:%02d",
             ATRCandle_TW5_StartH, ATRCandle_TW5_StartM, ATRCandle_TW5_StopH, ATRCandle_TW5_StopM));
      }
   }
   Log(StringFormat("V2.0 Profit Target: Factor=%.2f (KAMA-adaptive: ATR * Factor * [1 + ER*Factor/FastPeriod])",
       ProfitTargetFactor));
   Log("V2.0 Dynamic TP: recalculated on each bar close for open positions");
   Log(StringFormat("V2.0 Trailing Stop: %s | Activation=%.1f pips (fixed) | Distance=%.2f * SC * ATR (per bar) | MinModifyInterval=%ds",
       (EnableTrailingStop ? "ON" : "OFF"), TrailActivationPips, TrailSCCoef, MinModifyIntervalSec));
   Log(StringFormat("Lot Mode: %s, FixedLots=%.2f, RiskPct=%.2f",
       (LotMode == LOT_MODE_FIXED ? "Fixed" : "Risk%"), FixedLots, RiskPercent));
   Log(StringFormat("Breakeven: %s, Trigger Factor=%.2f (x ATR)", (EnableBreakeven ? "ON" : "OFF"), BreakevenTriggerFactor));
   Log(StringFormat("Magic: %d, Comment: %s", MagicNumber, OrderComment));

   // Calculate pip size
   CalculatePipSize();

   // Calculate half risk in price terms
   g_halfRisk = (PipsToRisk / 2.0) * g_pipSize;
   Log(StringFormat("Half risk in price: %s (%.1f pips)", DoubleToStr(g_halfRisk, Digits), PipsToRisk / 2.0));

   // Initialize state
   g_sellTicket          = -1;
   g_buyTicket           = -1;
   g_lastSellValue5      = 0;
   g_lastBuyValue6       = 0;
   g_sellWaitingSignal   = false;
   g_buyWaitingSignal    = false;
   g_breakevenApplied    = false;
   g_lastM30Bar          = iTime(Symbol(), PERIOD_M30, 0);
   g_lastChartBar        = iTime(Symbol(), Period(), 0);
   g_trailDistancePrice  = 0.0;
   g_lastATRCandleBar    = iTime(Symbol(), ATRCandle_TF, 0);
   g_lastSLModifyTime    = 0;

   // Compute initial adaptive trail distance
   RecalculateTrailDistance();

   // ZZ Semafor: check for existing pending orders and seed initial signals
   if(UseZZSemaforMethod)
   {
      int existingSell = FindPendingTicket(OP_SELLSTOP);
      int existingBuy  = FindPendingTicket(OP_BUYSTOP);

      if(existingSell > 0 || existingBuy > 0)
      {
         Log(StringFormat("Found existing orders: SellStop=#%d, BuyStop=#%d", existingSell, existingBuy));
         g_sellTicket = existingSell;
         g_buyTicket  = existingBuy;

         // Recover last signal values
         if(existingSell > 0)
         {
            int shift = -1;
            g_lastSellValue5 = FindMostRecentValue(BUF_VALUE5, shift);
         }
         if(existingBuy > 0)
         {
            int shift = -1;
            g_lastBuyValue6 = FindMostRecentValue(BUF_VALUE6, shift);
         }
      }
      else
      {
         PlaceInitialOrders();
      }
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Log(StringFormat("=== HiLo Breakout EA v2.10 Stopping (reason=%d) ===", reason));
   DeleteAllATRCandleObjects();
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // ZZ Semafor: monitor pending order states every tick
   if(UseZZSemaforMethod)
      MonitorOrderStates();

   // Manage breakeven and adaptive trailing stop for all open positions
   ManageOpenPositions();

   // ZZ Semafor: ER Layer 2 — delete pending orders if ER drops below threshold
   if(UseZZSemaforMethod && EnableER_Layer2)
   {
      double erValue = GetERValue();
      if(erValue < ER_Layer2_MinValue)
      {
         if(g_sellTicket > 0 && PendingOrderExists(g_sellTicket))
         {
            Log(StringFormat("ER Layer 2: ER=%.4f < Min=%.4f - deleting sell stop #%d", erValue, ER_Layer2_MinValue, g_sellTicket));
            if(DeletePendingOrder(g_sellTicket))
               g_sellTicket = 0;
         }
         if(g_buyTicket > 0 && PendingOrderExists(g_buyTicket))
         {
            Log(StringFormat("ER Layer 2: ER=%.4f < Min=%.4f - deleting buy stop #%d", erValue, ER_Layer2_MinValue, g_buyTicket));
            if(DeletePendingOrder(g_buyTicket))
               g_buyTicket = 0;
         }
      }
   }

   // Chart bar close: recalculate adaptive trail distance and dynamic TP
   datetime currentChartBar = iTime(Symbol(), Period(), 0);
   if(currentChartBar != g_lastChartBar)
   {
      g_lastChartBar = currentChartBar;
      Log(StringFormat("--- Chart bar closed at %s ---", TimeToStr(currentChartBar, TIME_DATE | TIME_MINUTES)));
      RecalculateTrailDistance();

      // V2.0: Update TP on bar close (ATR/ER at shift 1 only change on bar close)
      UpdateDynamicTP();
   }

   // ZZ Semafor: M30 bar close → scan for new indicator signals
   if(UseZZSemaforMethod)
   {
      datetime currentM30Bar = iTime(Symbol(), PERIOD_M30, 0);
      if(currentM30Bar != g_lastM30Bar)
      {
         g_lastM30Bar = currentM30Bar;
         Log(StringFormat("--- M30 candle closed at %s ---", TimeToStr(currentM30Bar, TIME_DATE | TIME_MINUTES)));
         MonitorM30Candle();
      }
   }

   // ATR Candle method: check signal timeframe for breakout signals
   if(UseATRCandleMethod)
      MonitorATRCandleSignals();
}
//+------------------------------------------------------------------+
