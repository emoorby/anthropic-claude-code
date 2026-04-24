//+------------------------------------------------------------------+
//|                                             Gold Scalper.mq5     |
//|                                                            2026   |
//+------------------------------------------------------------------+
#property copyright   "2026"
#property version     "1.01"
#property description "XAUUSD H1 Gold Scalper — breakout pending orders"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Enums
enum ENUM_LOTS_TYPE
  {
   LOT_FIXED         = 0,  // Fixed Lots
   LOT_EQUITY_PCT    = 1,  // Equity Percent
   LOT_MARGIN_PCT    = 2,  // Margin Percent
   LOT_PER_XBALANCE  = 3,  // Lots Per XBalance
  };

enum ENUM_TRADE_FILTER
  {
   FILTER_NONE  = 0,  // No Trade Filter
   FILTER_MA    = 1,  // MA Filter (MA60 directional)
   FILTER_TREND = 2,  // Trend Filter (MA30/50/100 alignment)
  };

enum ENUM_TRADE_DIR
  {
   DIR_BOTH,
   DIR_BUY_ONLY,
   DIR_SELL_ONLY,
   DIR_NONE
  };

//+------------------------------------------------------------------+
//| Input parameters                                                  |
//+------------------------------------------------------------------+

input group "---------- LOTS MANAGEMENT ----------"
input ENUM_LOTS_TYPE  InpLotsType        = LOT_PER_XBALANCE; // Initial Lots Type
input double          InpEquityPercent   = 5.0;               // Equity Percentage
input double          InpFixedLots       = 0.01;              // Fixed Lots
input double          InpUseMarginPct    = 100.0;             // Max Margin Use (%)
input double          InpXBalance        = 100.0;             // XBalance
input double          InpLotPerXBalance  = 0.01;              // Lot Size Per XBalance
input double          InpMaxLots         = 0.0;               // Max Lots (0 = Disable)

input group "---------- EA CONFIGURATIONS ----------"
input ENUM_TRADE_FILTER InpTradeFilter   = FILTER_NONE;       // Filter Trade
input int             InpTakeProfit      = 1320;               // Take Profit (points)
input int             InpStopLoss        = 45;                 // Stop Loss (points)
input int             InpAskPriceShift   = 12;                 // Ask Price Shift (points)
input int             InpBidPriceShift   = 55;                 // Bid Price Shift (points)
input double          InpATRPeriod       = 2.0;                // ATR Period
input int             InpSignalFrequency = 9;                  // Signal Frequency (bars)
input double          InpVolatilityScale = 19.2;               // Volatility Scale

input group "---------- BREAK-EVEN SETTINGS ----------"
input bool            InpBreakEvenOn     = false;              // Break Even On
input int             InpBreakEvenStart  = 1512;               // Break Even Start (points)
input int             InpBreakEvenStep   = 411;                // Break Even Step (points)

input group "---------- TRAILING STOP SETTINGS ----------"
input bool            InpTrailingOn      = true;               // Trailing On
input int             InpTrailingStart   = 40;                 // Trailing Start (points)
input int             InpTrailingStopPct = 23;                 // Trailing Stop (%)

input group "---------- SPLIT LOT SIZE SETTINGS ----------"
input bool            InpSplitLots       = true;               // Split Profit Lots
input int             InpSplitStart      = 723;                // Start Split In Points
input int             InpSplitPercent    = 38;                 // Split Lot Percentage

input group "---------- TIME CONFIGURATIONS ----------"
input string          InpSessionStart    = "05:00";            // Session Start Time
input string          InpSessionEnd      = "19:00";            // Session End (Mon-Thu)
input string          InpFridayEnd       = "18:00";            // Friday End Time
input bool            InpMondayTrade     = true;               // Monday Trade
input bool            InpTuesdayTrade    = true;               // Tuesday Trade
input bool            InpWednesdayTrade  = true;               // Wednesday Trade
input bool            InpThursdayTrade   = true;               // Thursday Trade
input bool            InpFridayTrade     = true;               // Friday Trade

input group "---------- BASIC CONFIGURATIONS ----------"
input int             InpMaxSpread       = 189;                // Maximum Spread (points)
input bool            InpCloseOnSpread   = true;               // Close Orders On Spread
input double          InpDailyMaxProfit  = 9.6;                // Daily Max Profit (%)
input int             InpMagicNumber     = 121212121;          // Magic Number
input string          InpTradeComment    = "GoldScalper";      // Trade Comment
input bool            InpDisplayInfo     = true;               // Display Info Panel
input bool            InpEnableLogging   = true;               // Enable Logging

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade   g_trade;
datetime g_lastBarTime       = 0;
double   g_dailyStartBalance = 0.0;
datetime g_dailyResetDate    = 0;

int      g_atrHandle         = INVALID_HANDLE;
int      g_ma60Handle        = INVALID_HANDLE;
int      g_ma30Handle        = INVALID_HANDLE;
int      g_ma50Handle        = INVALID_HANDLE;
int      g_ma100Handle       = INVALID_HANDLE;

// Session times parsed once at init (minutes since midnight)
int      g_sessionStartMins  = 0;
int      g_sessionEndMins    = 0;
int      g_fridayEndMins     = 0;

ulong    g_splitTickets[];

//+------------------------------------------------------------------+
//| Logging helper                                                    |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   if(InpEnableLogging) Print(msg);
  }

//+------------------------------------------------------------------+
//| Initialisation                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(3);
   g_trade.LogLevel(InpEnableLogging ? LOG_LEVEL_ALL : LOG_LEVEL_ERRORS);

   // Auto-detect the filling mode the broker supports for this symbol.
   // Hardcoding FOK can silently cause every order to be rejected if the
   // broker requires IOC or RETURN instead.
   int fillFlags = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   ENUM_ORDER_TYPE_FILLING fill;
   if((fillFlags & SYMBOL_FILLING_FOK) != 0)
      fill = ORDER_FILLING_FOK;
   else if((fillFlags & SYMBOL_FILLING_IOC) != 0)
      fill = ORDER_FILLING_IOC;
   else
      fill = ORDER_FILLING_RETURN;
   g_trade.SetTypeFilling(fill);

   int atrPeriod = (int)MathMax(1, MathRound(InpATRPeriod));
   g_atrHandle = iATR(_Symbol, _Period, atrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle");
      return INIT_FAILED;
     }

   if(InpTradeFilter == FILTER_MA)
      g_ma60Handle = iMA(_Symbol, _Period, 60, 0, MODE_SMA, PRICE_CLOSE);

   if(InpTradeFilter == FILTER_TREND)
     {
      g_ma30Handle  = iMA(_Symbol, _Period, 30,  0, MODE_SMA, PRICE_CLOSE);
      g_ma50Handle  = iMA(_Symbol, _Period, 50,  0, MODE_SMA, PRICE_CLOSE);
      g_ma100Handle = iMA(_Symbol, _Period, 100, 0, MODE_SMA, PRICE_CLOSE);
     }

   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyResetDate    = TimeCurrent();

   // Parse session time strings once rather than on every tick
   int h, m;
   ParseTime(InpSessionStart, h, m); g_sessionStartMins = h * 60 + m;
   ParseTime(InpSessionEnd,   h, m); g_sessionEndMins   = h * 60 + m;
   ParseTime(InpFridayEnd,    h, m); g_fridayEndMins    = h * 60 + m;

   ArrayResize(g_splitTickets, 0);

   Log(StringFormat("GoldScalper v1.01 init | magic=%d | session=%s-%s (Fri:%s) | "
                    "filter=%s | filling=%s | ATR period=%d | balance=%.2f",
       InpMagicNumber, InpSessionStart, InpSessionEnd, InpFridayEnd,
       EnumToString(InpTradeFilter), EnumToString(fill), atrPeriod,
       g_dailyStartBalance));

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinitialisation                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle   != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_ma60Handle  != INVALID_HANDLE) IndicatorRelease(g_ma60Handle);
   if(g_ma30Handle  != INVALID_HANDLE) IndicatorRelease(g_ma30Handle);
   if(g_ma50Handle  != INVALID_HANDLE) IndicatorRelease(g_ma50Handle);
   if(g_ma100Handle != INVALID_HANDLE) IndicatorRelease(g_ma100Handle);
   DeleteAllPendingOrders("EA deactivated");
   Comment("");
   Log(StringFormat("GoldScalper deactivated, reason code=%d", reason));
  }

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDailyBalance();
   CleanSplitTickets();
   ManagePositions();

   // Cache these once — both are used multiple times below
   int    posCount = CountPositions();
   double spread   = GetSpreadPoints();

   // Position is open: cancel any remaining pending order and wait
   if(posCount > 0)
     {
      // Only call the delete loop when there is actually something to delete
      if(OrdersTotal() > 0)
         DeleteAllPendingOrders("position open");
      if(InpDisplayInfo) UpdateDisplay(posCount, spread);
      return;
     }

   // Spread guard: cancel pending orders if spread spikes
   if(InpCloseOnSpread && spread > InpMaxSpread)
     {
      if(OrdersTotal() > 0)
        {
         Log(StringFormat("Spread guard: %.0f pts > max %d — deleting orders", spread, InpMaxSpread));
         DeleteAllPendingOrders("spread spike");
        }
      return;
     }

   if(!IsNewBar()) return;

   // New bar: always refresh pending orders at updated price levels
   Log(StringFormat("New bar: %s | spread=%.0f | session=%s",
       TimeToString(g_lastBarTime, TIME_DATE|TIME_MINUTES),
       spread, IsSessionActive() ? "ACTIVE" : "closed"));

   DeleteAllPendingOrders("new bar refresh");

   if(!IsSessionActive())
     {
      Log("Skip: session not active");
      return;
     }
   if(IsDailyMaxProfitReached())
     {
      Log("Skip: daily max profit reached");
      return;
     }
   if(spread > InpMaxSpread)
     {
      Log(StringFormat("Skip: spread %.0f > max %d", spread, InpMaxSpread));
      return;
     }
   if(!CheckVolatility())
      return; // CheckVolatility logs its own reason

   PlacePendingOrders();

   if(InpDisplayInfo) UpdateDisplay(posCount, spread);
  }

//+------------------------------------------------------------------+
//| New-bar detection                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Spread in points                                                  |
//+------------------------------------------------------------------+
double GetSpreadPoints()
  {
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
  }

//+------------------------------------------------------------------+
//| Session active check (uses times pre-parsed at init)             |
//+------------------------------------------------------------------+
bool IsSessionActive()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int dow = dt.day_of_week; // 0=Sun … 6=Sat
   if(dow == 0 || dow == 6)           return false;
   if(dow == 1 && !InpMondayTrade)    return false;
   if(dow == 2 && !InpTuesdayTrade)   return false;
   if(dow == 3 && !InpWednesdayTrade) return false;
   if(dow == 4 && !InpThursdayTrade)  return false;
   if(dow == 5 && !InpFridayTrade)    return false;

   int nowMins = dt.hour * 60 + dt.min;
   int endMins = (dow == 5) ? g_fridayEndMins : g_sessionEndMins;

   return (nowMins >= g_sessionStartMins && nowMins < endMins);
  }

//+------------------------------------------------------------------+
//| Parse "HH:MM" string                                             |
//+------------------------------------------------------------------+
void ParseTime(const string t, int &h, int &m)
  {
   h = (int)StringToInteger(StringSubstr(t, 0, 2));
   m = (int)StringToInteger(StringSubstr(t, 3, 2));
  }

//+------------------------------------------------------------------+
//| Daily max-profit guard                                            |
//+------------------------------------------------------------------+
bool IsDailyMaxProfitReached()
  {
   if(InpDailyMaxProfit <= 0.0)    return false;
   if(g_dailyStartBalance <= 0.0)  return false;
   double pct = (AccountInfoDouble(ACCOUNT_BALANCE) - g_dailyStartBalance)
                / g_dailyStartBalance * 100.0;
   return pct >= InpDailyMaxProfit;
  }

//+------------------------------------------------------------------+
//| Reset daily start balance at midnight                             |
//+------------------------------------------------------------------+
void ResetDailyBalance()
  {
   MqlDateTime now, last;
   TimeToStruct(TimeCurrent(),    now);
   TimeToStruct(g_dailyResetDate, last);
   if(now.day != last.day)
     {
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyResetDate    = TimeCurrent();
      Log(StringFormat("Daily balance reset: %.2f", g_dailyStartBalance));
     }
  }

//+------------------------------------------------------------------+
//| Count open positions owned by this EA                            |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (int)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Volatility gate: ATR must be >= VolatilityScale (in points)      |
//+------------------------------------------------------------------+
bool CheckVolatility()
  {
   if(g_atrHandle == INVALID_HANDLE) return true;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1)
     {
      Log("Warning: ATR buffer unavailable — skipping volatility filter");
      return true;
     }
   double atrPoints = buf[0] / _Point;
   if(atrPoints < InpVolatilityScale)
     {
      Log(StringFormat("Skip: ATR %.1f pts < min %.1f", atrPoints, InpVolatilityScale));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Trade direction from active filter                                |
//+------------------------------------------------------------------+
ENUM_TRADE_DIR GetTradeDirection()
  {
   if(InpTradeFilter == FILTER_NONE) return DIR_BOTH;

   if(InpTradeFilter == FILTER_MA)
     {
      if(g_ma60Handle == INVALID_HANDLE) return DIR_BOTH;
      double ma[];
      ArraySetAsSeries(ma, true);
      if(CopyBuffer(g_ma60Handle, 0, 1, 1, ma) < 1) return DIR_BOTH;
      double close1 = iClose(_Symbol, _Period, 1);
      if(close1 > ma[0]) return DIR_BUY_ONLY;
      if(close1 < ma[0]) return DIR_SELL_ONLY;
      return DIR_BOTH;
     }

   if(InpTradeFilter == FILTER_TREND)
     {
      if(g_ma30Handle  == INVALID_HANDLE ||
         g_ma50Handle  == INVALID_HANDLE ||
         g_ma100Handle == INVALID_HANDLE) return DIR_BOTH;
      double m30[], m50[], m100[];
      ArraySetAsSeries(m30,  true);
      ArraySetAsSeries(m50,  true);
      ArraySetAsSeries(m100, true);
      if(CopyBuffer(g_ma30Handle,  0, 1, 1, m30)  < 1) return DIR_BOTH;
      if(CopyBuffer(g_ma50Handle,  0, 1, 1, m50)  < 1) return DIR_BOTH;
      if(CopyBuffer(g_ma100Handle, 0, 1, 1, m100) < 1) return DIR_BOTH;
      if(m30[0] > m50[0] && m50[0] > m100[0]) return DIR_BUY_ONLY;
      if(m30[0] < m50[0] && m50[0] < m100[0]) return DIR_SELL_ONLY;
      return DIR_BOTH;
     }

   return DIR_BOTH;
  }

//+------------------------------------------------------------------+
//| Lot size calculation                                              |
//+------------------------------------------------------------------+
double CalculateLotSize()
  {
   double lots    = InpFixedLots;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   switch(InpLotsType)
     {
      case LOT_FIXED:
         lots = InpFixedLots;
         break;

      case LOT_EQUITY_PCT:
        {
         double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tv > 0 && ts > 0 && InpStopLoss > 0)
           {
            double risk   = equity * InpEquityPercent / 100.0;
            double slCost = InpStopLoss * _Point / ts * tv;
            lots = (slCost > 0) ? risk / slCost : InpFixedLots;
           }
         break;
        }

      case LOT_MARGIN_PCT:
        {
         double marginPerLot;
         if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0,
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginPerLot))
           {
            double availMargin = equity * InpUseMarginPct / 100.0;
            lots = (marginPerLot > 0) ? availMargin / marginPerLot : InpFixedLots;
           }
         break;
        }

      case LOT_PER_XBALANCE:
         lots = MathFloor(balance / InpXBalance) * InpLotPerXBalance;
         break;
     }

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(InpMaxLots > 0.0) maxLot = MathMin(maxLot, InpMaxLots);
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / stepLot) * stepLot;

   return lots;
  }

//+------------------------------------------------------------------+
//| Place Buy Stop and/or Sell Stop                                   |
//+------------------------------------------------------------------+
void PlacePendingOrders()
  {
   ENUM_TRADE_DIR dir = GetTradeDirection();
   if(dir == DIR_NONE) return;

   // Breakout levels: high/low of last InpSignalFrequency completed bars
   int hiIdx = iHighest(_Symbol, _Period, MODE_HIGH, InpSignalFrequency, 1);
   int loIdx = iLowest (_Symbol, _Period, MODE_LOW,  InpSignalFrequency, 1);

   double highLevel = iHigh(_Symbol, _Period, hiIdx);
   double lowLevel  = iLow (_Symbol, _Period, loIdx);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double buyPrice  = NormalizeDouble(highLevel + InpAskPriceShift * _Point, _Digits);
   double sellPrice = NormalizeDouble(lowLevel  - InpBidPriceShift * _Point, _Digits);

   // Enforce broker minimum stop distance
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(buyPrice  <= ask + stopLevel)
      buyPrice  = NormalizeDouble(ask + stopLevel + _Point, _Digits);
   if(sellPrice >= bid - stopLevel)
      sellPrice = NormalizeDouble(bid - stopLevel - _Point, _Digits);

   double lots = CalculateLotSize();
   double tp   = InpTakeProfit * _Point;
   double sl   = InpStopLoss  * _Point;

   Log(StringFormat("PlaceOrders: dir=%s ask=%.5f bid=%.5f high=%.5f low=%.5f lots=%.2f stopLvl=%.5f",
       EnumToString(dir), ask, bid, highLevel, lowLevel, lots, stopLevel));

   if(dir == DIR_BUY_ONLY || dir == DIR_BOTH)
     {
      double buySL = NormalizeDouble(buyPrice - sl, _Digits);
      double buyTP = NormalizeDouble(buyPrice + tp, _Digits);
      if(g_trade.BuyStop(lots, buyPrice, _Symbol, buySL, buyTP,
                         ORDER_TIME_GTC, 0, InpTradeComment))
         Log(StringFormat("BuyStop OK: ticket=%d price=%.5f SL=%.5f TP=%.5f",
             (int)g_trade.ResultOrder(), buyPrice, buySL, buyTP));
      else
         Log(StringFormat("BuyStop FAILED: retcode=%d [%s] price=%.5f SL=%.5f TP=%.5f lots=%.2f",
             g_trade.ResultRetcode(), g_trade.ResultComment(),
             buyPrice, buySL, buyTP, lots));
     }

   if(dir == DIR_SELL_ONLY || dir == DIR_BOTH)
     {
      double sellSL = NormalizeDouble(sellPrice + sl, _Digits);
      double sellTP = NormalizeDouble(sellPrice - tp, _Digits);
      if(g_trade.SellStop(lots, sellPrice, _Symbol, sellSL, sellTP,
                          ORDER_TIME_GTC, 0, InpTradeComment))
         Log(StringFormat("SellStop OK: ticket=%d price=%.5f SL=%.5f TP=%.5f",
             (int)g_trade.ResultOrder(), sellPrice, sellSL, sellTP));
      else
         Log(StringFormat("SellStop FAILED: retcode=%d [%s] price=%.5f SL=%.5f TP=%.5f lots=%.2f",
             g_trade.ResultRetcode(), g_trade.ResultComment(),
             sellPrice, sellSL, sellTP, lots));
     }
  }

//+------------------------------------------------------------------+
//| Cancel all pending orders owned by this EA                       |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders(const string reason = "")
  {
   if(OrdersTotal() == 0) return; // fast path — nothing to do

   int deleted = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)           != _Symbol)        continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)      continue;

      if(g_trade.OrderDelete(ticket))
         deleted++;
      else
         Log(StringFormat("OrderDelete FAILED: ticket=%d retcode=%d",
             (int)ticket, g_trade.ResultRetcode()));
     }

   if(deleted > 0)
      Log(StringFormat("Deleted %d pending order(s) [%s]", deleted,
          reason == "" ? "unspecified" : reason));
  }

//+------------------------------------------------------------------+
//| Manage open positions: split, break-even, trailing               |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)          != _Symbol)        continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)     continue;

      ENUM_POSITION_TYPE posType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);

      double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double curPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
      double profitPts = (posType == POSITION_TYPE_BUY)
                         ? (bid - openPrice) / _Point
                         : (openPrice - ask) / _Point;

      // --- Partial close (split lots) ---
      if(InpSplitLots && profitPts >= InpSplitStart && !IsTicketSplit(ticket))
        {
         double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double closeVol = MathFloor(volume * InpSplitPercent / 100.0 / lotStep) * lotStep;
         if(closeVol >= minLot && closeVol < volume)
           {
            if(g_trade.PositionClosePartial(ticket, closeVol))
              {
               MarkTicketSplit(ticket);
               Log(StringFormat("Split: ticket=%d closed %.2f of %.2f lots at +%.1f pts",
                   (int)ticket, closeVol, volume, profitPts));
              }
            else
               Log(StringFormat("Split FAILED: ticket=%d retcode=%d profit=%.1f pts",
                   (int)ticket, g_trade.ResultRetcode(), profitPts));
           }
        }

      // --- Break-even ---
      if(InpBreakEvenOn && profitPts >= InpBreakEvenStart)
        {
         double newSL = (posType == POSITION_TYPE_BUY)
                        ? NormalizeDouble(openPrice + InpBreakEvenStep * _Point, _Digits)
                        : NormalizeDouble(openPrice - InpBreakEvenStep * _Point, _Digits);
         bool improved = (posType == POSITION_TYPE_BUY)
                         ? (newSL > currentSL + _Point)
                         : (currentSL == 0.0 || newSL < currentSL - _Point);
         if(improved)
           {
            if(g_trade.PositionModify(ticket, newSL, currentTP))
               Log(StringFormat("BreakEven: ticket=%d newSL=%.5f profit=%.1f pts",
                   (int)ticket, newSL, profitPts));
            else
               Log(StringFormat("BreakEven FAILED: ticket=%d retcode=%d",
                   (int)ticket, g_trade.ResultRetcode()));
           }
        }

      // --- Trailing stop ---
      if(InpTrailingOn && profitPts >= InpTrailingStart)
        {
         double step = InpTrailingStart * InpTrailingStopPct / 100.0 * _Point;
         double newSL;
         bool   improved;
         if(posType == POSITION_TYPE_BUY)
           {
            newSL    = NormalizeDouble(curPrice - step, _Digits);
            improved = (newSL > currentSL + _Point);
           }
         else
           {
            newSL    = NormalizeDouble(curPrice + step, _Digits);
            improved = (currentSL == 0.0 || newSL < currentSL - _Point);
           }
         if(improved)
           {
            if(g_trade.PositionModify(ticket, newSL, currentTP))
               Log(StringFormat("Trailing: ticket=%d newSL=%.5f profit=%.1f pts",
                   (int)ticket, newSL, profitPts));
            else
               Log(StringFormat("Trailing FAILED: ticket=%d retcode=%d",
                   (int)ticket, g_trade.ResultRetcode()));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Split-ticket tracking helpers                                     |
//+------------------------------------------------------------------+
bool IsTicketSplit(ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_splitTickets); i++)
      if(g_splitTickets[i] == ticket) return true;
   return false;
  }

void MarkTicketSplit(ulong ticket)
  {
   if(IsTicketSplit(ticket)) return;
   int n = ArraySize(g_splitTickets);
   ArrayResize(g_splitTickets, n + 1);
   g_splitTickets[n] = ticket;
  }

void CleanSplitTickets()
  {
   if(ArraySize(g_splitTickets) == 0) return;
   // Rebuild array keeping only tickets whose position still exists
   ulong keep[];
   ArrayResize(keep, 0);
   for(int i = 0; i < ArraySize(g_splitTickets); i++)
      if(PositionSelectByTicket(g_splitTickets[i]))
        {
         int n = ArraySize(keep);
         ArrayResize(keep, n + 1);
         keep[n] = g_splitTickets[i];
        }
   ArrayFree(g_splitTickets);
   ArrayResize(g_splitTickets, ArraySize(keep));
   if(ArraySize(keep) > 0)
      ArrayCopy(g_splitTickets, keep);
  }

//+------------------------------------------------------------------+
//| Display info panel                                                |
//+------------------------------------------------------------------+
void UpdateDisplay(const int posCount, const double spread)
  {
   double atrPts = 0.0;
   if(g_atrHandle != INVALID_HANDLE)
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1)
         atrPts = buf[0] / _Point;
     }

   double dailyPct = 0.0;
   if(g_dailyStartBalance > 0.0)
      dailyPct = (AccountInfoDouble(ACCOUNT_BALANCE) - g_dailyStartBalance)
                 / g_dailyStartBalance * 100.0;

   string s = "=== Gold Scalper v1.01 ===\n";
   s += StringFormat("Balance  : %.2f\n",   AccountInfoDouble(ACCOUNT_BALANCE));
   s += StringFormat("Equity   : %.2f\n",   AccountInfoDouble(ACCOUNT_EQUITY));
   s += StringFormat("Day P&L  : %+.2f%%\n", dailyPct);
   s += StringFormat("Spread   : %.0f pts\n", spread);
   s += StringFormat("ATR      : %.1f pts\n", atrPts);
   s += StringFormat("Session  : %s\n",      IsSessionActive() ? "ACTIVE" : "closed");
   s += StringFormat("Filter   : %s\n",      EnumToString(GetTradeDirection()));
   s += StringFormat("Positions: %d\n",      posCount);
   s += StringFormat("Pending  : %d\n",      OrdersTotal());
   if(IsDailyMaxProfitReached())
      s += ">>> Daily profit target reached <<<\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
