//+------------------------------------------------------------------+
//|                                          HiLo_Breakout_EA.mq4   |
//|                        HiLo Breakout Expert Adviser               |
//|                        Based on 3-Level ZZ Semafor Indicator      |
//+------------------------------------------------------------------+
#property copyright "HiLo Breakout EA"
#property link      ""
#property version   "1.00"
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
// --- General ---
input int         MagicNumber          = 123456;     // Magic Number
input string      OrderComment         = "HiLo_BRK"; // Order Comment
input bool        EnableLogging        = true;        // Enable Logging

// --- Indicator ---
input string      IndicatorName        = "!!!3 level zz semafor mtf alerts nmc-pfeil"; // Indicator Name

// --- Trade Parameters ---
input double      PipsToRisk           = 56.0;       // Pips to Risk (total)
input double      MaxSpreadPips        = 5.0;        // Max Spread (pips)

// --- ATR ---
input int         ATR_Period           = 30;          // ATR Period
input bool        EnableATRFilter      = true;        // Enable ATR Filter
input double      ATR_MinValue         = 14.0;        // ATR Minimum Value (pips)

// --- Profit Target ---
input double      ProfitTargetFactor   = 4.8;         // Profit Target Factor (x ATR)

// --- Breakeven ---
input bool        EnableBreakeven      = true;        // Enable Breakeven
input double      BreakevenTriggerFactor = 0.75;      // Breakeven Trigger Factor (x ATR)

// --- Trailing Stop ---
input bool        EnableTrailingStop   = true;        // Enable Trailing Stop
input double      TrailTriggerFactor   = 1.7;         // Trailing Trigger Factor (x ATR)
input double      TrailDistancePips    = 70.0;        // Distance to trail behind price (pips)

// --- Lot Sizing ---
input ENUM_LOT_MODE LotMode            = LOT_MODE_FIXED; // Lot Sizing Mode
input double      FixedLots            = 0.1;        // Fixed Lot Size
input double      RiskPercent          = 1.0;        // Risk Percent of Balance

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
double   g_pipSize;           // pip size in price terms
int      g_pipDigits;         // number of decimal places for pips
double   g_halfRisk;          // PipsToRisk / 2 in price terms

datetime g_lastM30Bar;        // track M30 bar close
int      g_sellTicket;        // current sell stop ticket
int      g_buyTicket;         // current buy stop ticket

double   g_lastSellValue5;    // last Value5 used for sell order
double   g_lastBuyValue6;     // last Value6 used for buy order

bool     g_sellWaitingSignal; // waiting for new Value5 after SL/close
bool     g_buyWaitingSignal;  // waiting for new Value6 after SL/close

bool     g_breakevenApplied; // breakeven already moved for current position

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

   double entryPrice = NormalizeDouble(value5 - g_halfRisk, Digits);
   double slPrice    = NormalizeDouble(value5 + g_halfRisk, Digits);
   double lots       = CalculateLotSize(PipsToRisk);

   // Calculate TP from ATR
   double atrPrice = GetATRPrice();
   double tpPrice  = NormalizeDouble(entryPrice - atrPrice * ProfitTargetFactor, Digits);

   Log(StringFormat("SELL TP calc: ATR_Period=%d, ATR_price=%.5f, Factor=%.2f, TP=%.5f",
       ATR_Period, atrPrice, ProfitTargetFactor, tpPrice));

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

   double entryPrice = NormalizeDouble(value6 + g_halfRisk, Digits);
   double slPrice    = NormalizeDouble(value6 - g_halfRisk, Digits);
   double lots       = CalculateLotSize(PipsToRisk);

   // Calculate TP from ATR
   double atrPrice = GetATRPrice();
   double tpPrice  = NormalizeDouble(entryPrice + atrPrice * ProfitTargetFactor, Digits);

   Log(StringFormat("BUY TP calc: ATR_Period=%d, ATR_price=%.5f, Factor=%.2f, TP=%.5f",
       ATR_Period, atrPrice, ProfitTargetFactor, tpPrice));

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
//| Manage breakeven and trailing stop for open positions             |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atrPips = GetATRPips();
   double breakevenThreshold = atrPips * BreakevenTriggerFactor;
   double trailTriggerThreshold = atrPips * TrailTriggerFactor;

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

         // Trailing stop (triggered at ATR * TrailTriggerFactor)
         if(EnableTrailingStop && profitPips >= trailTriggerThreshold)
         {
            double trailSL = NormalizeDouble(Bid - TrailDistancePips * g_pipSize, Digits);
            if(trailSL > newSL || newSL == 0)
            {
               Log(StringFormat("TRAILING BUY #%d: Moving SL to %.5f (profit=%.1f pips, trigger=%.1f pips [ATR*%.2f], trail=%.1f pips)",
                   OrderTicket(), trailSL, profitPips, trailTriggerThreshold, TrailTriggerFactor, TrailDistancePips));
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

         // Trailing stop (triggered at ATR * TrailTriggerFactor)
         if(EnableTrailingStop && profitPips >= trailTriggerThreshold)
         {
            double trailSL = NormalizeDouble(Ask + TrailDistancePips * g_pipSize, Digits);
            if(trailSL < newSL || newSL == 0)
            {
               Log(StringFormat("TRAILING SELL #%d: Moving SL to %.5f (profit=%.1f pips, trigger=%.1f pips [ATR*%.2f], trail=%.1f pips)",
                   OrderTicket(), trailSL, profitPips, trailTriggerThreshold, TrailTriggerFactor, TrailDistancePips));
               newSL = trailSL;
            }
         }
      }

      // Apply SL modification if changed
      if(MathAbs(newSL - currentSL) > Point && newSL != 0)
      {
         if(!OrderModify(OrderTicket(), openPrice, newSL, OrderTakeProfit(), 0, clrYellow))
         {
            Log(StringFormat("FAILED to modify SL for #%d: newSL=%.5f, error=%d",
                OrderTicket(), newSL, GetLastError()));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Log("=== HiLo Breakout EA Starting ===");
   Log(StringFormat("Symbol: %s, Digits: %d, Point: %s", Symbol(), Digits, DoubleToStr(Point, Digits)));
   Log(StringFormat("Settings: PipsToRisk=%.1f, MaxSpread=%.1f, ATR_Period=%d",
       PipsToRisk, MaxSpreadPips, ATR_Period));
   Log(StringFormat("ATR Filter: %s, Min=%.1f pips", (EnableATRFilter ? "ON" : "OFF"), ATR_MinValue));
   Log(StringFormat("Profit Target Factor: %.2f (x ATR)", ProfitTargetFactor));
   Log(StringFormat("Lot Mode: %s, FixedLots=%.2f, RiskPct=%.2f",
       (LotMode == LOT_MODE_FIXED ? "Fixed" : "Risk%"), FixedLots, RiskPercent));
   Log(StringFormat("Breakeven: %s, Trigger Factor=%.2f (x ATR)", (EnableBreakeven ? "ON" : "OFF"), BreakevenTriggerFactor));
   Log(StringFormat("Trailing Stop: %s, Trigger Factor=%.2f (x ATR), Distance=%.1f pips",
       (EnableTrailingStop ? "ON" : "OFF"), TrailTriggerFactor, TrailDistancePips));
   Log(StringFormat("Magic: %d, Comment: %s", MagicNumber, OrderComment));

   // Calculate pip size
   CalculatePipSize();

   // Calculate half risk in price terms
   g_halfRisk = (PipsToRisk / 2.0) * g_pipSize;
   Log(StringFormat("Half risk in price: %s (%0.1f pips)", DoubleToStr(g_halfRisk, Digits), PipsToRisk / 2.0));

   // Initialize state
   g_sellTicket        = -1;
   g_buyTicket         = -1;
   g_lastSellValue5    = 0;
   g_lastBuyValue6     = 0;
   g_sellWaitingSignal = false;
   g_buyWaitingSignal  = false;
   g_breakevenApplied  = false;
   g_lastM30Bar        = iTime(Symbol(), PERIOD_M30, 0);

   // Check for any existing orders from previous runs
   int existingSell = FindPendingTicket(OP_SELLSTOP);
   int existingBuy  = FindPendingTicket(OP_BUYSTOP);

   if(existingSell > 0 || existingBuy > 0)
   {
      Log(StringFormat("Found existing orders: SellStop=#%d, BuyStop=#%d", existingSell, existingBuy));
      g_sellTicket = existingSell;
      g_buyTicket  = existingBuy;

      // Recover last values used
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
      // No existing orders - place initial ones
      PlaceInitialOrders();
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Log(StringFormat("=== HiLo Breakout EA Stopping (reason=%d) ===", reason));
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Monitor order states every tick (check for SL hits, closures)
   MonitorOrderStates();

   // Manage breakeven and trailing stop for open positions
   ManageOpenPositions();

   // Check for new M30 candle close
   datetime currentM30Bar = iTime(Symbol(), PERIOD_M30, 0);

   if(currentM30Bar != g_lastM30Bar)
   {
      // New M30 candle has opened - the previous one just closed
      g_lastM30Bar = currentM30Bar;
      Log(StringFormat("--- M30 candle closed at %s ---", TimeToStr(currentM30Bar, TIME_DATE | TIME_MINUTES)));

      // Monitor for new signals
      MonitorM30Candle();
   }
}
//+------------------------------------------------------------------+
