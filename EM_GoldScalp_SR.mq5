//+------------------------------------------------------------------+
//|                                              EM_GoldScalp_SR.mq5 |
//|  H1 swing-level breakout scalper for XAUUSD.                     |
//|  Clean rebuild of the "Breakout Support/Resistance" entry used   |
//|  by EM_ScalpH1_C.set. Rules were calibrated against the original |
//|  EA's tester orders (133/133 placements reproduced).             |
//+------------------------------------------------------------------+
#property copyright "EM"
#property version   "1.10"
#property description "Pending stop orders at the most recent unbroken H1 swing high/low,"
#property description "fixed SL/TP, per-tick trailing stop and an NFP news filter."

#include <Trade\Trade.mqh>

//--- Distances are in "pips" exactly like the original EA: 1 pip = InpPipSize in price.
//--- On 2-digit gold 1 pip = 0.01, so 300 pips = $3.00.

   enum     RiskMode          {Fixed_Lots=0, Risk_Percent=1};

input group "=== General ==="
   input    long              InpMagic             = 2103;           // Magic number
   input    string            InpComment           = "Gold_Scalp_C"; // Trade comment
   input    bool              InpAllowBuy          = true;           // Allow buy trades
   input    bool              InpAllowSell         = true;           // Allow sell trades
   input    double            InpPipSize           = 0.01;           // Price value of 1 pip (0.01 on 2-digit gold)
   input    bool              InpLogFills          = true;           // Live only: log fill slippage to Common\Files

input group "=== Position size ==="
   input    RiskMode          InpRiskMode          = Fixed_Lots;     // Fixed lots or % of balance
   input    double            InpLots              = 0.1;            // Fixed lot size
   input    double            InpRiskPercent       = 1.0;            // Risk per trade (% of balance)
   input    double            InpRiskBufferPips    = 50;             // Extra pips added to the stop for sizing (slippage)
   input    double            InpMaxLots           = 5.0;            // Maximum lot size

input group "=== Support/Resistance entry ==="
   input    ENUM_TIMEFRAMES   InpLevelTF           = PERIOD_H1;      // Timeframe for swing highs/lows
   input    ENUM_TIMEFRAMES   InpCheckTF           = PERIOD_M5;      // Entry timing (check on each new bar)
   input    int               InpLeftBars          = 20;             // Inferior candles LEFT of high/low
   input    int               InpRightBars         = 1;              // Inferior candles RIGHT of high/low
   input    int               InpCountback         = 50;             // Max candles in history to look at
   input    double            InpMinDistPips       = 2000;           // Min distance price -> high/low (pips)
   input    double            InpBuyOffsetPips     = -200;           // Extra pips above high for buy entry
   input    double            InpSellOffsetPips    = -200;           // Extra pips below low for sell entry
   input    int               InpExpiryHours       = 205;            // Pending order expiry in hours (0 = none)

input group "=== Session filter ==="
   input    bool              InpUseSession        = false;          // Only hold pending orders inside session
   input    int               InpSessionStartHour  = 10;             // Session start hour (server time)
   input    int               InpSessionEndHour    = 20;             // Session end hour (server time, exclusive)

input group "=== Exits ==="
   input    double            InpStopPips          = 300;            // Initial stop loss (pips)
   input    double            InpTakePips          = 1000;           // Initial take profit (pips)
   input    double            InpTrailStartPips    = 80;             // Trailing starts at profit (pips, 0 = off)
   input    double            InpTrailDistPips     = 80;             // Trailing distance (pips)
   input    double            InpTrailStepPips     = 10;             // Trailing step (pips)

input group "=== NFP filter ==="
   input    bool              InpNfpFilter         = true;           // Enable NFP filter
   input    string            InpNfpServerTime     = "15:30";        // NFP release time in server time (HH:MM)
   input    int               InpNfpMinsBefore     = 50;             // Minutes before NFP
   input    int               InpNfpMinsAfter      = 30;             // Minutes after NFP
   input    bool              InpNfpCloseTrades    = true;           // Close open trades in NFP window
   input    bool              InpNfpDeletePending  = true;           // Delete pending orders in NFP window
   input    string            InpNfpCacheFile      = "EM_NFP_Dates.csv"; // NFP date cache (Common\Files)

input group "=== Optimisation (Custom max, 0 = ignore) ==="
   input    double            InpOptMinPayoff      = 0;              // Min expected payoff
   input    double            InpOptMinRecovery    = 0;              // Min recovery factor
   input    int               InpOptMinTrades      = 0;              // Min number of trades

struct Swing
{
   double   price;
   datetime time;
};

CTrade   trade;

double   g_pip, g_minDist, g_buyOff, g_sellOff, g_sl, g_tp, g_trStart, g_trDist, g_trStep, g_halfTick;
bool     g_tester;
datetime g_lastCheckBar  = 0;
datetime g_lastLevelBar  = 0;
Swing    g_highs[], g_lows[];          // candidate swings, most recent first, unbroken by closed bars

ulong    g_posTicket     = 0;          // our open position (MaxTrades = 1)
double   g_posPeakSL     = 0;          // best trailing stop computed for it

datetime g_nfpStart[], g_nfpEnd[];
int      g_nfpIdx        = 0;
int      g_nfpMinute     = 0;
datetime g_nfpLoadedDay  = 0;
bool     g_nfpHandled    = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPipSize<=0 || InpLeftBars<1 || InpRightBars<1 || InpCountback<=InpRightBars || InpStopPips<=0 ||
      (InpRiskMode==Fixed_Lots ? InpLots<=0 : (InpRiskPercent<=0 || InpRiskBufferPips<0)) || InpMaxLots<=0)
   {
      Print("Invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_tester   = (bool)MQLInfoInteger(MQL_TESTER) || (bool)MQLInfoInteger(MQL_OPTIMIZATION);
   g_pip      = InpPipSize;
   g_minDist  = InpMinDistPips    * g_pip;
   g_buyOff   = InpBuyOffsetPips  * g_pip;
   g_sellOff  = InpSellOffsetPips * g_pip;
   g_sl       = InpStopPips       * g_pip;
   g_tp       = InpTakePips       * g_pip;
   g_trStart  = InpTrailStartPips * g_pip;
   g_trDist   = InpTrailDistPips  * g_pip;
   g_trStep   = InpTrailStepPips  * g_pip;
   g_halfTick = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)*0.5;

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   string hm[];
   if(StringSplit(InpNfpServerTime,':',hm)!=2) { Print("InpNfpServerTime must be HH:MM"); return INIT_PARAMETERS_INCORRECT; }
   g_nfpMinute = (int)StringToInteger(hm[0])*60 + (int)StringToInteger(hm[1]);

   if(InpNfpFilter) LoadNfpSchedule();
   RefreshPosition();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(!g_tester) Comment("");
}

//+------------------------------------------------------------------+
//| Tick: exits every tick (only while a position is open),          |
//| entries once per new InpCheckTF bar.                              |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   bool     nfp = InpNfpFilter && InNfpWindow(now);

   if(nfp && !g_nfpHandled)
   {
      if(InpNfpDeletePending) DeleteAllPending();
      g_nfpHandled = true;
   }
   else if(!nfp) g_nfpHandled = false;

   if(g_posTicket!=0) ManagePosition(nfp);

   datetime cb = iTime(_Symbol,InpCheckTF,0);
   if(cb==g_lastCheckBar) return;
   g_lastCheckBar = cb;

   OnCheckBar(now,nfp);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.symbol==_Symbol)
   {
      if(!HistoryDealSelect(trans.deal) || HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic) return;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN)
      {
         g_posTicket = trans.position; g_posPeakSL = 0;
         if(InpLogFills && !g_tester) LogFill(trans.deal);
      }
      else if(trans.position==g_posTicket)           { g_posTicket = 0;              g_posPeakSL = 0; }
   }
   else if(trans.type==TRADE_TRANSACTION_ORDER_DELETE)
      GlobalVariableDel(SwingKey(trans.order));
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void OnCheckBar(datetime now,bool nfp)
{
   if(InpNfpFilter && !g_tester && TimeDay(now)!=g_nfpLoadedDay) LoadNfpSchedule();

   datetime lb = iTime(_Symbol,InpLevelTF,0);
   if(lb!=g_lastLevelBar && BuildSwings()) g_lastLevelBar = lb;

   if(InpUseSession && !InSession(now)) { DeleteAllPending(); return; }   // pending orders only live inside the session

   RefreshPosition();
   if(nfp || g_posTicket!=0) return;            // no new orders during NFP or while in a trade

   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(InpAllowBuy)  ManageSide(true, bid,now);
   if(InpAllowSell) ManageSide(false,bid,now);

   if(!g_tester) Comment(StringFormat("EM GoldScalp SR  |  next NFP window: %s",NextNfpText(now)));
}

//--- Collect swing highs/lows that are still unbroken by the closed bars after them.
//--- Rebuilt once per new InpLevelTF bar.
bool BuildSwings()
{
   int need = InpCountback + InpLeftBars + 1;
   double   hi[], lo[];
   datetime tm[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(tm,true);
   if(CopyHigh(_Symbol,InpLevelTF,0,need,hi)<need || CopyLow(_Symbol,InpLevelTF,0,need,lo)<need ||
      CopyTime(_Symbol,InpLevelTF,0,need,tm)<need)
      return false;

   ArrayResize(g_highs,0,InpCountback);
   ArrayResize(g_lows,0,InpCountback);

   double maxAfter = -DBL_MAX, minAfter = DBL_MAX;     // extremes of closed bars newer than shift s
   for(int s=1; s<=InpCountback; s++)
   {
      // "price > every newer closed bar" covers both the RIGHT-side rule and the unbroken rule
      if(s>InpRightBars)
      {
         if(hi[s]>maxAfter && IsExtreme(hi,s,true))  Push(g_highs,hi[s],tm[s]);
         if(lo[s]<minAfter && IsExtreme(lo,s,false)) Push(g_lows, lo[s],tm[s]);
      }
      maxAfter = MathMax(maxAfter,hi[s]);
      minAfter = MathMin(minAfter,lo[s]);
   }
   return true;
}

bool IsExtreme(const double &v[],int s,bool high)
{
   for(int k=1; k<=InpLeftBars; k++)
      if(high ? v[s+k]>=v[s] : v[s+k]<=v[s]) return false;
   return true;
}

void Push(Swing &arr[],double price,datetime time)
{
   int n = ArraySize(arr);
   ArrayResize(arr,n+1,InpCountback);
   arr[n].price = price;
   arr[n].time  = time;
}

//--- Most recent swing not broken by the forming bar and at least MinDist away from price.
bool PickSwing(bool buy,double bid,Swing &out)
{
   if(buy)
   {
      double formHigh = iHigh(_Symbol,InpLevelTF,0);
      for(int i=0; i<ArraySize(g_highs); i++)
         if(g_highs[i].price>formHigh && g_highs[i].price-bid>=g_minDist-g_halfTick) { out = g_highs[i]; return true; }
   }
   else
   {
      double formLow = iLow(_Symbol,InpLevelTF,0);
      for(int i=0; i<ArraySize(g_lows); i++)
         if(g_lows[i].price<formLow && bid-g_lows[i].price>=g_minDist-g_halfTick) { out = g_lows[i]; return true; }
   }
   return false;
}

//--- One pending stop per side. A pending order is only replaced by a NEWER swing.
void ManageSide(bool buy,double bid,datetime now)
{
   ENUM_ORDER_TYPE type = buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   ulong  ticket = 0;
   double price  = 0;
   datetime setup = 0;

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic || OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         OrderGetInteger(ORDER_TYPE)!=type) continue;
      ticket = t;
      price  = OrderGetDouble(ORDER_PRICE_OPEN);
      setup  = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      break;
   }

   if(ticket!=0 && InpExpiryHours>0 && now-setup>=(datetime)InpExpiryHours*3600)
   {
      if(trade.OrderDelete(ticket)) ticket = 0;
   }

   Swing sw;
   if(!PickSwing(buy,bid,sw)) return;
   double entry = Norm(buy ? sw.price+g_buyOff : sw.price-g_sellOff);

   if(ticket!=0)
   {
      if(MathAbs(entry-price)<g_halfTick) return;
      datetime curSwing = GlobalVariableCheck(SwingKey(ticket)) ? (datetime)GlobalVariableGet(SwingKey(ticket)) : 0;
      if(sw.time<=curSwing) return;
      if(PlacePending(buy,entry,sw.time)) trade.OrderDelete(ticket);     // new order first, then old (as original)
      return;
   }
   PlacePending(buy,entry,sw.time);
}

bool PlacePending(bool buy,double entry,datetime swingTime)
{
   double ask   = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double stops = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(buy ? entry<=ask+stops : entry>=bid-stops) return false;

   double lots = CalcLots(buy,entry);
   if(lots<=0) return false;

   double margin;
   if(!OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,lots,entry,margin) ||
      margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return false;

   double sl = Norm(buy ? entry-g_sl : entry+g_sl);
   double tp = InpTakePips>0 ? Norm(buy ? entry+g_tp : entry-g_tp) : 0;
   bool ok = buy ? trade.BuyStop (lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,InpComment)
                 : trade.SellStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,InpComment);
   if(ok) GlobalVariableSet(SwingKey(trade.ResultOrder()),(double)swingTime);
   return ok;
}

//--- Fixed lots, or lots that lose InpRiskPercent of balance if the stop (plus a slippage buffer) is hit.
//--- Size is set when the pending order is placed. Returns 0 if even the minimum lot risks too much.
double CalcLots(bool buy,double entry)
{
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),InpMaxLots);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double lots   = InpLots;

   if(InpRiskMode==Risk_Percent)
   {
      double dist = g_sl + InpRiskBufferPips*g_pip;
      double loss1;                                               // loss of 1 lot over dist, in account currency
      if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,1.0,entry,buy ? entry-dist : entry+dist,loss1) || loss1>=0)
         return 0;
      double risk = AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskPercent/100.0;
      lots = MathFloor(risk/-loss1/step+1e-9)*step;
      if(lots<minLot)
      {
         static datetime warned = 0;
         if(TimeCurrent()-warned>=86400)
         {
            PrintFormat("Risk %.2f%% is below the minimum lot (%.2f) for a %.0f-pip stop: orders skipped",InpRiskPercent,minLot,InpStopPips+InpRiskBufferPips);
            warned = TimeCurrent();
         }
         return 0;
      }
   }
   lots = MathMax(minLot,MathMin(maxLot,lots));
   return NormalizeDouble(MathRound(lots/step)*step,8);
}

//--- Live only: one CSV line per fill so slippage can be compared between brokers.
void LogFill(ulong deal)
{
   ulong  order = (ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
   if(!HistoryOrderSelect(order)) return;
   bool   buy   = HistoryDealGetInteger(deal,DEAL_TYPE)==DEAL_TYPE_BUY;
   double req   = HistoryOrderGetDouble(order,ORDER_PRICE_OPEN);
   double fill  = HistoryDealGetDouble(deal,DEAL_PRICE);
   double slip  = buy ? fill-req : req-fill;                      // positive = worse than requested

   string file = "EM_GoldScalp_Fills_"+AccountInfoString(ACCOUNT_COMPANY)+".csv";
   StringReplace(file," ","_");
   int h = FileOpen(file,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0) FileWrite(h,"time","side","requested","filled","slippage","lots");
   FileSeek(h,0,SEEK_END);
   FileWrite(h,TimeToString((datetime)HistoryDealGetInteger(deal,DEAL_TIME),TIME_DATE|TIME_SECONDS),buy ? "buy" : "sell",
             DoubleToString(req,_Digits),DoubleToString(fill,_Digits),DoubleToString(slip,_Digits),DoubleToString(HistoryDealGetDouble(deal,DEAL_VOLUME),2));
   FileClose(h);
}

void DeleteAllPending()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC)==InpMagic && OrderGetString(ORDER_SYMBOL)==_Symbol) trade.OrderDelete(t);
   }
}

//+------------------------------------------------------------------+
//| Exit logic (every tick while a position is open)                 |
//+------------------------------------------------------------------+
void RefreshPosition()
{
   ulong found = 0;
   for(int i=PositionsTotal()-1; i>=0 && found==0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==InpMagic && PositionGetString(POSITION_SYMBOL)==_Symbol) found = t;
   }
   if(found!=g_posTicket) g_posPeakSL = 0;
   g_posTicket = found;
}

void ManagePosition(bool nfp)
{
   if(!PositionSelectByTicket(g_posTicket)) { RefreshPosition(); return; }

   if(nfp && InpNfpCloseTrades) { trade.PositionClose(g_posTicket); return; }

   bool   buy  = PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double px   = buy ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   // internal stop: initial stop from the actual fill price, or the best trailing stop seen
   double stop = buy ? open-g_sl : open+g_sl;
   if(g_posPeakSL!=0) stop = buy ? MathMax(stop,g_posPeakSL) : MathMin(stop,g_posPeakSL);
   if(buy ? px<=stop : px>=stop) { trade.PositionClose(g_posTicket); return; }

   if(g_trStart<=0) return;
   double profit = buy ? px-open : open-px;
   if(profit<g_trStart) return;

   double want = Norm(buy ? px-g_trDist : px+g_trDist);
   if(g_posPeakSL==0 || (buy ? want>g_posPeakSL : want<g_posPeakSL)) g_posPeakSL = want;
   if(sl!=0 && (buy ? want<sl+g_trStep : want>sl-g_trStep)) return;
   trade.PositionModify(g_posTicket,want,tp);
}

//+------------------------------------------------------------------+
//| NFP schedule                                                      |
//| Live: dates come from the MQL5 calendar and are cached to         |
//| Common\Files. Tester: dates are read from that cache. Without a   |
//| cache the first Friday of each month is used.                     |
//+------------------------------------------------------------------+
void LoadNfpSchedule()
{
   datetime dates[];
   ReadNfpCache(dates);
   if(!g_tester && FetchNfpCalendar(dates)) WriteNfpCache(dates);

   if(ArraySize(dates)==0)
   {
      Print("NFP: no calendar cache found, falling back to first Friday of each month. ",
            "Run the EA once on a live chart to build ",InpNfpCacheFile);
      MqlDateTime m; TimeToStruct(TimeCurrent(),m);
      for(int y=m.year-1; y<=m.year+15; y++)
         for(int mo=1; mo<=12; mo++)
         {
            datetime d = StringToTime(StringFormat("%04d.%02d.01",y,mo));
            MqlDateTime dd; TimeToStruct(d,dd);
            AddDate(dates,d+(datetime)(((5-dd.day_of_week+7)%7)*86400));
         }
   }

   ArraySort(dates);
   int n = ArraySize(dates);
   ArrayResize(g_nfpStart,n); ArrayResize(g_nfpEnd,n);
   for(int i=0; i<n; i++)
   {
      datetime t   = dates[i]+(datetime)g_nfpMinute*60;
      g_nfpStart[i] = t-(datetime)InpNfpMinsBefore*60;
      g_nfpEnd[i]   = t+(datetime)InpNfpMinsAfter*60;
   }
   g_nfpIdx       = 0;
   g_nfpLoadedDay = TimeDay(TimeCurrent());
}

bool FetchNfpCalendar(datetime &dates[])
{
   MqlCalendarEvent ev[];
   if(CalendarEventByCountry("US",ev)<=0) return false;
   ulong id = 0;
   for(int i=0; i<ArraySize(ev); i++)
      if(ev[i].event_code=="nonfarm-payrolls") { id = ev[i].id; break; }
   if(id==0) return false;

   MqlCalendarValue v[];
   datetime now = TimeTradeServer();
   if(CalendarValueHistoryByEvent(id,v,now-400*86400,now+60*86400)<=0) return false;
   for(int i=0; i<ArraySize(v); i++) AddDate(dates,TimeDay(v[i].time));
   return true;
}

void ReadNfpCache(datetime &dates[])
{
   int h = FileOpen(InpNfpCacheFile,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      string s = FileReadString(h);
      if(StringLen(s)>=10) AddDate(dates,StringToTime(s));
   }
   FileClose(h);
}

void WriteNfpCache(datetime &dates[])
{
   ArraySort(dates);
   int h = FileOpen(InpNfpCacheFile,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return;
   for(int i=0; i<ArraySize(dates); i++) FileWrite(h,TimeToString(dates[i],TIME_DATE));
   FileClose(h);
}

void AddDate(datetime &dates[],datetime d)
{
   int n = ArraySize(dates);
   for(int i=0; i<n; i++) if(dates[i]==d) return;
   ArrayResize(dates,n+1,64);
   dates[n] = d;
}

bool InNfpWindow(datetime now)
{
   int n = ArraySize(g_nfpEnd);
   if(g_nfpIdx>0 && now<g_nfpEnd[g_nfpIdx-1]) g_nfpIdx = 0;     // clock moved back (new test pass)
   while(g_nfpIdx<n && now>=g_nfpEnd[g_nfpIdx]) g_nfpIdx++;
   return g_nfpIdx<n && now>=g_nfpStart[g_nfpIdx];
}

string NextNfpText(datetime now)
{
   InNfpWindow(now);
   return g_nfpIdx<ArraySize(g_nfpStart) ? TimeToString(g_nfpStart[g_nfpIdx],TIME_DATE|TIME_MINUTES) : "none";
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
datetime TimeDay(datetime t)  { return t-(t%86400); }

bool InSession(datetime t)
{
   int h = (int)((t%86400)/3600);
   return InpSessionStartHour<=InpSessionEndHour ? (h>=InpSessionStartHour && h<InpSessionEndHour)
                                                 : (h>=InpSessionStartHour || h<InpSessionEndHour);   // overnight session
}
string   SwingKey(ulong order){ return StringFormat("EMGS_%I64d_%I64u",InpMagic,order); }

double Norm(double price)
{
   double tick = g_halfTick*2;
   return NormalizeDouble(tick>0 ? MathRound(price/tick)*tick : price,_Digits);
}

//+------------------------------------------------------------------+
//| Custom optimisation criterion ("Custom max")                     |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double rf     = TesterStatistics(STAT_RECOVERY_FACTOR);
   double ep     = TesterStatistics(STAT_EXPECTED_PAYOFF);
   if(trades<InpOptMinTrades) return 0;
   if(InpOptMinRecovery>0 && rf<InpOptMinRecovery) return 0;
   if(InpOptMinPayoff>0   && ep<InpOptMinPayoff)   return 0;
   if(rf<=0 || ep<=0) return 0;
   return rf*rf*ep*MathSqrt(trades);       // recovery factor weighted highest
}
//+------------------------------------------------------------------+
