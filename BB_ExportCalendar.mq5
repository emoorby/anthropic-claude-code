//+------------------------------------------------------------------+
//|                                           BB_ExportCalendar.mq5  |
//|  Script: dumps the MT5 economic calendar to MQL5\Files\BB_news.csv|
//|  for BreakAndBounce_EA backtests (the Calendar API is not         |
//|  available inside the Strategy Tester). Times are server time.   |
//|  Run it on a live/demo terminal of the SAME broker you test with.|
//+------------------------------------------------------------------+
#property copyright "Break & Bounce EA"
#property version   "1.00"
#property script_show_inputs

input datetime                       InpFrom       = D'2018.01.01';            // Export from
input string                         InpCurrencies = "USD";                    // Currencies, comma separated
input ENUM_CALENDAR_EVENT_IMPORTANCE InpMinImp     = CALENDAR_IMPORTANCE_HIGH; // Min importance

void OnStart()
{
   int h = FileOpen("BB_news.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("Cannot create BB_news.csv: ", GetLastError()); return; }
   FileWrite(h, "time", "currency", "importance", "event");

   string list[];
   int nc = StringSplit(InpCurrencies, ',', list), total = 0;
   for(int c = 0; c < nc; c++)
   {
      string cur = list[c];
      StringTrimLeft(cur); StringTrimRight(cur);
      MqlCalendarValue v[];
      int k = CalendarValueHistory(v, InpFrom, TimeTradeServer() + 30 * 86400, NULL, cur);
      for(int j = 0; j < k; j++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(v[j].event_id, ev) || ev.importance < InpMinImp) continue;
         FileWrite(h, TimeToString(v[j].time, TIME_DATE | TIME_MINUTES), cur, (int)ev.importance, ev.name);
         total++;
      }
   }
   FileClose(h);
   PrintFormat("Exported %d events to MQL5\\Files\\BB_news.csv", total);
}
