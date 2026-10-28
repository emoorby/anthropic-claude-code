//+------------------------------------------------------------------+
//|                                           BB_SymbolSelector.mq5  |
//|  Script: builds a clean Market Watch for Break & Bounce testing. |
//|   1. Picks server symbols by name suffix (e.g. .NYSE,.NAS) and   |
//|      drops names containing e.g. "-24".                          |
//|   2. Forces the history download and checks it covers the whole  |
//|      test period - drops delisted, stale and patchy symbols and  |
//|      those without real ticks.                                   |
//|   3. Optional trade-mode / price / volatility / liquidity filters|
//|   4. Shows the passed symbols in Market Watch, hides the rest,   |
//|      and writes MQL5\Files\BB_symbol_check.csv (every symbol and |
//|      why it failed) + BB_symbols.txt (passed list, for the EA's  |
//|      InpSymbolsFile basket mode).                                |
//|  Run it on the terminal you test with, before the optimisation.  |
//+------------------------------------------------------------------+
#property copyright "Break & Bounce EA"
#property version   "1.00"
#property script_show_inputs

input string   InpInclude       = ".NYSE,.NAS";   // Keep names ending with (comma separated, empty = all)
input string   InpExclude       = "-24";          // Drop names containing (comma separated)
input datetime InpFrom          = D'2026.01.01';  // Test period start
input datetime InpTo            = D'2026.10.17';  // Test period end
input int      InpEdgeDays      = 7;              // First/last bar must be within x days of start/end
input double   InpMinCoverPct   = 95;             // Min daily bars vs best symbol (%)
input bool     InpCheckTicks    = true;           // Require real ticks on first and last day
input bool     InpFullTradeOnly = true;           // Drop close-only / disabled symbols
input double   InpMinPrice      = 20;             // Min average price (0=off)
input double   InpMinADRPct     = 1.5;            // Min average daily range % (0=off)
input double   InpMaxADRPct     = 6.0;            // Max average daily range % (0=off)
input int      InpTopN          = 0;              // Keep top N by average traded value (0=all)
input bool     InpApply         = true;           // Update Market Watch (show passed, hide others)
input int      InpTimeoutSec    = 15;             // Max wait for history per request (sec)

struct Res
{
   string   sym, reason;
   long     mode;
   datetime first, last;
   int      bars;
   double   cover, price, adr, value;
   bool     realVol, ticks;
};

int SplitTrim(string s, string &out[])
{
   int n = (StringLen(s) == 0) ? 0 : StringSplit(s, ',', out);
   for(int i = 0; i < n; i++) { StringTrimLeft(out[i]); StringTrimRight(out[i]); }
   return n;
}

bool EndsWithAny(string s, const string &list[])
{
   int ls = StringLen(s);
   for(int i = ArraySize(list) - 1; i >= 0; i--)
   {
      int lx = StringLen(list[i]);
      if(lx > 0 && ls >= lx && StringSubstr(s, ls - lx) == list[i]) return true;
   }
   return false;
}

bool ContainsAny(string s, const string &list[])
{
   for(int i = ArraySize(list) - 1; i >= 0; i--)
      if(StringLen(list[i]) > 0 && StringFind(s, list[i]) >= 0) return true;
   return false;
}

string ModeName(long m)
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

// CopyRates with a wait for the server download; gives up quickly once the
// series is synchronised but empty (no data on the server).
int WaitRates(string s, ENUM_TIMEFRAMES tf, datetime from, datetime to, MqlRates &r[])
{
   uint t0 = GetTickCount();
   while(true)
   {
      int  n    = CopyRates(s, tf, from, to, r);
      bool sync = (bool)SeriesInfoInteger(s, tf, SERIES_SYNCHRONIZED);
      if(n > 0 && sync) return n;
      uint el = GetTickCount() - t0;
      if(IsStopped() || el > (uint)InpTimeoutSec * 1000 || (sync && el > 3000)) return n;
      Sleep(200);
   }
}

bool HasTicks(string s, datetime day)
{
   MqlTick t[];
   uint t0 = GetTickCount();
   while(true)
   {
      int n = CopyTicksRange(s, t, COPY_TICKS_ALL, (ulong)day * 1000, (ulong)(day + 86400) * 1000);
      if(n > 0) return true;
      uint el = GetTickCount() - t0;
      if(IsStopped() || el > (uint)InpTimeoutSec * 1000 || (n == 0 && el > 3000)) return false;
      Sleep(200);
   }
}

void CheckSymbol(string s, Res &r)
{
   r.sym = s; r.reason = ""; r.first = 0; r.last = 0; r.bars = 0;
   r.cover = 0; r.price = 0; r.adr = 0; r.value = 0; r.realVol = false; r.ticks = false;
   SymbolSelect(s, true);                       // needed to download history
   r.mode = SymbolInfoInteger(s, SYMBOL_TRADE_MODE);

   MqlRates d[];
   int n = WaitRates(s, PERIOD_D1, InpFrom, InpTo, d);
   if(n <= 0) { r.reason = "no_data"; return; }
   r.bars = n; r.first = d[0].time; r.last = d[n - 1].time;

   double sp = 0, sa = 0, sv = 0, srv = 0;
   for(int k = 0; k < n; k++)
   {
      double c = d[k].close;
      sp += c;
      if(c > 0) sa += (d[k].high - d[k].low) / c;
      sv  += (double)d[k].tick_volume * c;
      srv += (double)d[k].real_volume * c;
   }
   r.price   = sp / n;
   r.adr     = 100.0 * sa / n;
   r.realVol = srv > 0;
   r.value   = (r.realVol ? srv : sv) / n;     // traded value (tick-volume proxy if no real volume)

   MqlRates m[];                                // the tester builds its ticks from M1 history
   if(WaitRates(s, PERIOD_M1, r.first, r.first + 86400, m) <= 0) { r.reason = "no_M1_at_start"; return; }
   if(InpCheckTicks) r.ticks = HasTicks(s, r.first) && HasTicks(s, r.last);
}

void OnStart()
{
   string inc[], exc[];
   SplitTrim(InpInclude, inc);
   SplitTrim(InpExclude, exc);

   //--- 1. name filter over every symbol on the server
   string cand[];
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string s = SymbolName(i, false);
      if((ArraySize(inc) > 0 && !EndsWithAny(s, inc)) || ContainsAny(s, exc)) continue;
      int k = ArraySize(cand);
      ArrayResize(cand, k + 1, 1024);
      cand[k] = s;
   }
   int n = ArraySize(cand);
   PrintFormat("%d of %d server symbols match the name filters", n, total);
   if(n == 0) return;

   //--- 2. history checks
   Res res[];
   ArrayResize(res, n);
   int maxBars = 0;
   for(int i = 0; i < n && !IsStopped(); i++)
   {
      Comment(StringFormat("BB_SymbolSelector: checking %d / %d  %s", i + 1, n, cand[i]));
      CheckSymbol(cand[i], res[i]);
      maxBars = MathMax(maxBars, res[i].bars);
   }
   Comment("");

   datetime end = (InpTo < TimeCurrent()) ? InpTo : TimeCurrent();
   int edge = InpEdgeDays * 86400;
   for(int i = 0; i < n; i++)
   {
      if(res[i].reason != "") continue;
      res[i].cover = maxBars > 0 ? 100.0 * res[i].bars / maxBars : 0;
      string why = "";
      if(InpFullTradeOnly && res[i].mode != SYMBOL_TRADE_MODE_FULL) why = "trade_mode_" + ModeName(res[i].mode);
      else if(res[i].first > InpFrom + edge)                         why = "starts_late";
      else if(res[i].last < end - edge)                              why = "ends_early_delisted";
      else if(res[i].cover < InpMinCoverPct)                         why = "patchy_history";
      else if(InpCheckTicks && !res[i].ticks)                        why = "no_real_ticks";
      else if(InpMinPrice > 0 && res[i].price < InpMinPrice)         why = "price_low";
      else if(InpMinADRPct > 0 && res[i].adr < InpMinADRPct)         why = "adr_low";
      else if(InpMaxADRPct > 0 && res[i].adr > InpMaxADRPct)         why = "adr_high";
      res[i].reason = why;
   }

   //--- 3. optional top-N by traded value
   if(InpTopN > 0)
   {
      double key[][2];
      int m = 0;
      for(int i = 0; i < n; i++)
         if(res[i].reason == "") { ArrayResize(key, m + 1); key[m][0] = -res[i].value; key[m][1] = i; m++; }
      if(m > InpTopN)
      {
         ArraySort(key);                        // ascending on -value = descending value
         for(int j = InpTopN; j < m; j++) res[(int)key[j][1]].reason = "below_top_n";
      }
   }

   //--- 4. outputs
   int ok = 0;
   string list = "";
   int h = FileOpen("BB_symbol_check.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h != INVALID_HANDLE)
      FileWrite(h, "symbol", "status", "trade_mode", "first_d1", "last_d1", "d1_bars", "coverage_pct",
                "avg_price", "adr_pct", "avg_traded_value", "volume_type", "real_ticks");
   for(int i = 0; i < n; i++)
   {
      bool pass = (res[i].reason == "");
      if(pass) { ok++; list += (list == "" ? "" : ",") + res[i].sym; }
      if(h != INVALID_HANDLE)
         FileWrite(h, res[i].sym, pass ? "OK" : res[i].reason, ModeName(res[i].mode),
                   res[i].first > 0 ? TimeToString(res[i].first, TIME_DATE) : "",
                   res[i].last > 0 ? TimeToString(res[i].last, TIME_DATE) : "",
                   res[i].bars, DoubleToString(res[i].cover, 1), DoubleToString(res[i].price, 2),
                   DoubleToString(res[i].adr, 2), DoubleToString(res[i].value, 0),
                   res[i].realVol ? "real" : "tick", res[i].ticks ? "yes" : "no");
   }
   if(h != INVALID_HANDLE) FileClose(h);

   h = FileOpen("BB_symbols.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) { FileWriteString(h, list); FileClose(h); }

   //--- 5. Market Watch: hide everything that didn't pass, show what did
   if(InpApply)
   {
      string shown[];
      int ns = SymbolsTotal(true);
      ArrayResize(shown, ns);
      for(int i = 0; i < ns; i++) shown[i] = SymbolName(i, true);
      for(int i = 0; i < ns; i++)
      {
         bool keep = false;
         for(int j = 0; j < n && !keep; j++) keep = (res[j].sym == shown[i] && res[j].reason == "");
         if(!keep) SymbolSelect(shown[i], false);   // fails (harmlessly) for symbols with charts/positions
      }
      for(int i = 0; i < n; i++)
         SymbolSelect(res[i].sym, res[i].reason == "");
   }

   PrintFormat("BB_SymbolSelector: %d of %d candidates passed. Details: MQL5\\Files\\BB_symbol_check.csv, list: BB_symbols.txt", ok, n);
   if(InpApply) PrintFormat("Market Watch now shows %d symbols (symbols with open charts/positions can't be hidden)", SymbolsTotal(true));
}
