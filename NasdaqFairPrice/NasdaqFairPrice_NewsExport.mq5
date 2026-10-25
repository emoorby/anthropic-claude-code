//+------------------------------------------------------------------+
//|                                   NasdaqFairPrice_NewsExport.mq5 |
//|  Script: exports high-impact USD events from the MT5 economic    |
//|  calendar to the NasdaqFairPrice news CSV (New York time).       |
//|  Run it on any chart in a LIVE/DEMO terminal (the calendar is    |
//|  not available inside the Strategy Tester).                      |
//+------------------------------------------------------------------+
#property copyright "emoorby"
#property version   "1.00"
#property script_show_inputs

enum ENUM_TZ_MODE
  {
   TZ_NY_PLUS7  = 0, // Server = New York + 7h (IC Markets, Vantage)
   TZ_FIXED_GMT = 1  // Fixed GMT offset (no DST on server)
  };

input datetime     InpFrom            = D'2024.01.01';               // Export from (server date)
input datetime     InpTo              = D'2026.12.31';               // Export to (server date)
input string       InpCurrency        = "USD";                       // Currency
input ENUM_CALENDAR_EVENT_IMPORTANCE InpMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum importance
input string       InpExclude         = "";                          // Exclude events containing (comma separated)
input bool         InpSkipCancelled   = true;                        // Skip past events with no actual value
input ENUM_TZ_MODE InpTZMode          = TZ_NY_PLUS7;                 // Broker server time model
input int          InpServerGMTOffset = 2;                           // Server GMT offset (Fixed GMT mode only)
input string       InpFile            = "NasdaqFairPrice_news.csv";  // Output file (Common\Files)

//+------------------------------------------------------------------+
void OnStart()
  {
   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, InpFrom, InpTo, NULL, InpCurrency))
     {
      PrintFormat("CalendarValueHistory failed, error %d. Open the Calendar tab once and make sure you are connected.",
                  GetLastError());
      return;
     }

   string excl[];
   int nExcl = 0;
   if(StringLen(InpExclude) > 0)
      nExcl = StringSplit(InpExclude, ',', excl);
   for(int i = 0; i < nExcl; i++)
     {
      StringTrimLeft(excl[i]);
      StringTrimRight(excl[i]);
      StringToLower(excl[i]);
     }

   datetime nyTimes[];
   string   labels[];
   string   names[];
   int      nameCounts[];
   datetime now = TimeTradeServer();

   for(int i = 0; i < ArraySize(values); i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance < InpMinImportance || ev.time_mode != CALENDAR_TIMEMODE_DATETIME)
         continue;
      if(InpSkipCancelled && values[i].time < now && !values[i].HasActualValue())
         continue;

      string lname = ev.name;
      StringToLower(lname);
      bool skip = false;
      for(int k = 0; k < nExcl && !skip; k++)
         skip = (StringLen(excl[k]) > 0 && StringFind(lname, excl[k]) >= 0);
      if(skip)
         continue;

      AddName(names, nameCounts, ev.name);

      datetime ny = ToNY(values[i].time);
      int found = -1;
      for(int j = 0; j < ArraySize(nyTimes); j++)
         if(nyTimes[j] == ny)
           {
            found = j;
            break;
           }
      string label = ev.name;
      StringReplace(label, ",", " ");
      if(found < 0)
        {
         int n = ArraySize(nyTimes);
         ArrayResize(nyTimes, n + 1);
         ArrayResize(labels, n + 1);
         nyTimes[n] = ny;
         labels[n]  = label;
        }
      else
         if(StringFind(labels[found], label) < 0 && StringLen(labels[found]) < 80)
            labels[found] += " / " + label;
     }

   //--- sort by time
   for(int i = 1; i < ArraySize(nyTimes); i++)
     {
      datetime t = nyTimes[i];
      string   l = labels[i];
      int j = i - 1;
      while(j >= 0 && nyTimes[j] > t)
        {
         nyTimes[j + 1] = nyTimes[j];
         labels[j + 1]  = labels[j];
         j--;
        }
      nyTimes[j + 1] = t;
      labels[j + 1]  = l;
     }

   int h = FileOpen(InpFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("Cannot write %s, error %d", InpFile, GetLastError());
      return;
     }
   FileWriteString(h, "# NasdaqFairPrice news file, exported from the MT5 economic calendar\r\n");
   FileWriteString(h, StringFormat("# %s %s+ events, %s to %s, times in New York time\r\n", InpCurrency,
                                   EnumToString(InpMinImportance), TimeToString(InpFrom, TIME_DATE),
                                   TimeToString(InpTo, TIME_DATE)));
   FileWriteString(h, "date,time,label\r\n");
   int preOpen = 0;
   for(int i = 0; i < ArraySize(nyTimes); i++)
     {
      MqlDateTime d;
      TimeToStruct(nyTimes[i], d);
      if(d.hour * 60 + d.min < 9 * 60 + 30)
         preOpen++;
      FileWriteString(h, StringFormat("%04d-%02d-%02d,%02d:%02d,%s\r\n", d.year, d.mon, d.day, d.hour, d.min, labels[i]));
     }
   FileClose(h);

   PrintFormat("Wrote %d event times (%d before 09:30 NY) to Common\\Files\\%s", ArraySize(nyTimes), preOpen, InpFile);
   Print("Events included (name: count). Use the Exclude input to drop any you don't want:");
   for(int i = 0; i < ArraySize(names); i++)
      PrintFormat("  %s: %d", names[i], nameCounts[i]);
  }

//+------------------------------------------------------------------+
void AddName(string &names[], int &counts[], string name)
  {
   for(int i = 0; i < ArraySize(names); i++)
      if(names[i] == name)
        {
         counts[i]++;
         return;
        }
   int n = ArraySize(names);
   ArrayResize(names, n + 1);
   ArrayResize(counts, n + 1);
   names[n]  = name;
   counts[n] = 1;
  }

//+------------------------------------------------------------------+
//| Same conversion as the EA                                        |
//+------------------------------------------------------------------+
datetime ToNY(datetime server)
  {
   if(InpTZMode == TZ_FIXED_GMT)
      return(GMTtoNY(server - InpServerGMTOffset * 3600));
   return(server - 7 * 3600);
  }

datetime GMTtoNY(datetime gmt)
  {
   MqlDateTime g;
   TimeToStruct(gmt, g);
   datetime dstStart = NthSundayUTC(g.year, 3, 2, 7);
   datetime dstEnd   = NthSundayUTC(g.year, 11, 1, 6);
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
//+------------------------------------------------------------------+
