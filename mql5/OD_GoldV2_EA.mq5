//+------------------------------------------------------------------+
//|                                                    OD_GoldV2_EA.mq5 |
//|  OD Gold v2 — MT5 port of OD_GoldStrategy.pine (XAUUSD, M15)     |
//|                                                                  |
//|  Same rules as the Pine strategy (see README.md):                |
//|   • decisions on the CLOSED bar (shift 1), orders at the new     |
//|     bar's open → identical timing to TradingView                 |
//|   • Wilder ATR / Supertrend computed in-house (MT5 iATR is SMA)  |
//|   • ADX = iADXWilder, HTF = last closed H1 bar (shift 1)         |
//|   • sessions / news in local time (default GMT+7) converted from |
//|     broker server time (NY-aligned servers handled automatically)|
//|   • breakeven / trailing evaluated on the closed bar             |
//|   • partial close = two positions (part with TP1, rest runner)   |
//|   • push notifications to the MT5 phone app (free)               |
//+------------------------------------------------------------------+
#property copyright "OD"
#property version   "2.00"
#property description "OD Gold v2: 200 EMA + Supertrend flip, HTF trend, sessions, news, trailing exit."

#include <Trade\Trade.mqh>

//--- enums ------------------------------------------------------------
enum ENUM_OD_PRESET  { OD_IMPROVED = 0,   // Improved (use toggles)
                       OD_BASELINE = 1 }; // Baseline v1 (all v2 features off)
enum ENUM_OD_SLMODE  { OD_SL_SUPERTREND = 0, OD_SL_ATR = 1 };
enum ENUM_OD_CAPUNIT { OD_CAP_ATR = 0, OD_CAP_PRICE = 1 };
enum ENUM_OD_MAXACT  { OD_MAX_SKIP = 0, OD_MAX_CLAMP = 1 };
enum ENUM_OD_SERVER  { OD_SERVER_NY_ALIGNED = 0, // NY-aligned (GMT+2 winter / GMT+3 summer)
                       OD_SERVER_FIXED = 1 };    // Fixed GMT offset

//--- inputs (same names / defaults as the Pine script) -----------------
input group "0 · Preset"
input ENUM_OD_PRESET  InpPreset      = OD_IMPROVED;    // Preset

input group "1 · Test window (server time)"
input datetime        InpStart       = D'2000.01.01';  // New entries from
input datetime        InpEnd         = D'2100.01.01';  // No new entries from

input group "2 · Core signal (v1)"
input int             InpStLen       = 10;     // Supertrend ATR length
input double          InpStFac       = 3.0;    // Supertrend factor
input int             InpEmaLen      = 200;    // Trend EMA length
input bool            InpLong        = true;   // Allow buys
input bool            InpShort       = true;   // Allow sells

input group "3 · Stop-loss, target & size"
input ENUM_OD_SLMODE  InpSlMode      = OD_SL_SUPERTREND; // Stop-loss type
input int             InpAtrLen      = 14;     // ATR length (ATR stop, caps, trail, filters)
input double          InpSlAtrMult   = 2.0;    // ATR stop multiple
input bool            InpUseCaps     = true;   // Use min / max stop distance
input ENUM_OD_CAPUNIT InpCapUnit     = OD_CAP_ATR; // Cap units
input double          InpMinSL       = 1.0;    // Min stop distance (0 = off)
input double          InpMaxSL       = 5.0;    // Max stop distance (0 = off)
input ENUM_OD_MAXACT  InpMaxAct      = OD_MAX_SKIP; // If stop > max
input double          InpRR          = 2.0;    // Risk : Reward (fixed target)
input double          InpRiskPct     = 1.0;    // Risk % of equity per trade
input bool            InpSkipBelowMin= true;   // Skip trade if size < minimum lot (else use min lot)
input double          InpMaxRiskPct  = 3.0;    // ...when using min lot: skip if real risk > this %

input group "4 · Trade management"
input bool            InpUseBE       = false;  // Breakeven
input double          InpBeR         = 1.0;    // Breakeven at R
input double          InpBeOff       = 0.30;   // Breakeven offset ($)
input bool            InpUsePart     = false;  // Partial close (two positions)
input double          InpPartPct     = 50.0;   // Partial %
input double          InpPartR       = 1.0;    // Partial at R
input bool            InpUseTrail    = true;   // ATR trailing stop
input double          InpTrailMult   = 3.0;    // Trailing × ATR
input double          InpTrailStart  = 1.0;    // Trailing starts at R
input bool            InpTrailNoTP   = true;   // Trailing: remove the fixed target

input group "5 · Time zones"
input ENUM_OD_SERVER  InpServerMode  = OD_SERVER_NY_ALIGNED; // Broker server clock
input int             InpServerGMT   = 2;      // Fixed server GMT offset (if Fixed)
input int             InpLocalGMT    = 7;      // Local time zone of all time inputs (GMT+7 = Phnom Penh)

input group "6 · Sessions (local time, HHMM)"
input bool            InpUseSess     = true;   // Trade only inside these windows
input bool            InpUseLon      = true;   // London window
input int             InpLonStart    = 1400;   // London start
input int             InpLonEnd      = 1800;   // London end
input bool            InpUseNY       = true;   // New York window
input int             InpNYStart     = 1930;   // New York start
input int             InpNYEnd       = 2330;   // New York end
input bool            InpUseEod      = false;  // Flatten open trade in window
input int             InpEodStart    = 330;    // Flatten start
input int             InpEodEnd      = 500;    // Flatten end

input group "7 · Chop filters"
input bool            InpUseAdx      = false;  // ADX filter
input double          InpAdxMin      = 20.0;   // ADX ≥
input int             InpAdxLen      = 14;     // ADX length (Wilder)
input bool            InpUseDist     = false;  // Skip if |close − EMA| < k × ATR
input double          InpDistAtr     = 0.5;    // k

input group "8 · Higher-timeframe trend"
input bool            InpUseHtf      = true;   // Require HTF trend agreement
input ENUM_TIMEFRAMES InpHtfTF       = PERIOD_H1; // HTF
input int             InpHtfLen      = 200;    // HTF EMA length

input group "9 · Daily limits"
input int             InpMaxTrades   = 3;      // Max trades per day (0 = off)
input int             InpMaxLosses   = 2;      // Stop after X losing trades per day (0 = off)

input group "10 · News blackout (local time)"
input bool            InpUseNews     = true;   // Enable news blackout
input bool            InpNewsFlat    = false;  // Also close an open trade when a blackout starts
input bool            InpUseNfp      = true;   // NFP block (first Friday of the month)
input int             InpNfpStart    = 1900;   // NFP start
input int             InpNfpEnd      = 2130;   // NFP end
input bool            InpUseDaily    = false;  // Every Mon–Fri block
input int             InpDlyStart    = 1915;   // Daily start
input int             InpDlyEnd      = 2045;   // Daily end
input int             InpPreMin      = 30;     // One-off events: minutes before
input int             InpPostMin     = 60;     // One-off events: minutes after
input bool            InpUseE1       = false;  // Event 1 on
input datetime        InpE1          = D'2026.01.01 00:00'; // Event 1 (local time)
input bool            InpUseE2       = false;  // Event 2 on
input datetime        InpE2          = D'2026.01.01 00:00'; // Event 2 (local time)
input bool            InpUseE3       = false;  // Event 3 on
input datetime        InpE3          = D'2026.01.01 00:00'; // Event 3 (local time)
input bool            InpUseE4       = false;  // Event 4 on
input datetime        InpE4          = D'2026.01.01 00:00'; // Event 4 (local time)

input group "11 · Execution & alerts"
input long            InpMagic       = 260210; // Magic number
input int             InpDeviation   = 50;     // Max slippage (points)
input bool            InpPush        = true;   // Push notifications to MT5 phone app
input bool            InpPopup       = false;  // Pop-up alerts on the terminal
input int             InpCalcBars    = 1500;   // Bars used for Supertrend / ATR warm-up

//--- globals ------------------------------------------------------------
CTrade   trade;
int      hEma = INVALID_HANDLE, hAdx = INVALID_HANDLE, hHtfEma = INVALID_HANDLE;
datetime lastBar = 0;

// effective switches (Baseline preset forces every v2 feature off)
bool v2, mAtrSL, mCaps, mBE, mPart, mTrail, mNoTP, mSess, mEod, mAdx, mDist, mHtf, mLimits, mNews;

//+------------------------------------------------------------------+
int OnInit()
  {
   v2      = (InpPreset == OD_IMPROVED);
   mAtrSL  = v2 && InpSlMode == OD_SL_ATR;
   mCaps   = v2 && InpUseCaps;
   mBE     = v2 && InpUseBE;
   mPart   = v2 && InpUsePart;
   mTrail  = v2 && InpUseTrail;
   mNoTP   = mTrail && InpTrailNoTP;
   mSess   = v2 && InpUseSess;
   mEod    = v2 && InpUseEod;
   mAdx    = v2 && InpUseAdx;
   mDist   = v2 && InpUseDist;
   mHtf    = v2 && InpUseHtf;
   mLimits = v2;
   mNews   = v2 && InpUseNews;

   if(_Period != PERIOD_M15)
      Print("OD_GoldV2_EA: designed and tested on M15 — current chart is ", EnumToString((ENUM_TIMEFRAMES)_Period));
   if(mPart && (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("OD_GoldV2_EA: partial close needs a HEDGING account — partial close disabled.");
      mPart = false;
     }

   hEma    = iMA(_Symbol, _Period, InpEmaLen, 0, MODE_EMA, PRICE_CLOSE);
   hAdx    = iADXWilder(_Symbol, _Period, InpAdxLen);
   hHtfEma = iMA(_Symbol, InpHtfTF, InpHtfLen, 0, MODE_EMA, PRICE_CLOSE);
   if(hEma == INVALID_HANDLE || hAdx == INVALID_HANDLE || hHtfEma == INVALID_HANDLE)
     {
      Print("OD_GoldV2_EA: indicator handle error ", GetLastError());
      return(INIT_FAILED);
     }
   if(mHtf && PeriodSeconds(InpHtfTF) <= PeriodSeconds(_Period))
     {
      Print("OD_GoldV2_EA: HTF must be higher than the chart timeframe.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hEma != INVALID_HANDLE)    IndicatorRelease(hEma);
   if(hAdx != INVALID_HANDLE)    IndicatorRelease(hAdx);
   if(hHtfEma != INVALID_HANDLE) IndicatorRelease(hHtfEma);
  }

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
// n-th Sunday (n >= 1) of a month at 02:00
datetime NthSunday(int year, int month, int n)
  {
   MqlDateTime s; ZeroMemory(s);
   s.year = year; s.mon = month; s.day = 1; s.hour = 2;
   datetime t = StructToTime(s);
   TimeToStruct(t, s);
   int add = (7 - s.day_of_week) % 7;             // days to the first Sunday
   return t + (datetime)((add + 7 * (n - 1)) * 86400);
  }

// Is New York on daylight time at New York local time t?
bool IsUSDST(datetime nyLocal)
  {
   MqlDateTime s; TimeToStruct(nyLocal, s);
   return nyLocal >= NthSunday(s.year, 3, 2) && nyLocal < NthSunday(s.year, 11, 1);
  }

// Broker server time → local time of the inputs (default GMT+7)
datetime ServerToLocal(datetime srv)
  {
   datetime utc;
   if(InpServerMode == OD_SERVER_NY_ALIGNED)
     {
      datetime ny = srv - 7 * 3600;                // server 00:00 = 17:00 New York
      utc = ny + (IsUSDST(ny) ? 4 : 5) * 3600;
     }
   else
      utc = srv - InpServerGMT * 3600;
   return utc + InpLocalGMT * 3600;
  }

int HHMMtoMin(int hhmm) { return (hhmm / 100) * 60 + hhmm % 100; }

// Window [a, b) in minutes; supports windows crossing midnight
bool InWin(int m, int aHHMM, int bHHMM)
  {
   int a = HHMMtoMin(aHHMM), b = HHMMtoMin(bHHMM);
   return a <= b ? (m >= a && m < b) : (m >= a || m < b);
  }

bool NearEvent(datetime loc, bool on, datetime ev)
  {
   return on && loc >= ev - InpPreMin * 60 && loc < ev + InpPostMin * 60;
  }

//+------------------------------------------------------------------+
//| Wilder ATR + Supertrend (identical to Pine ta.atr / ta.supertrend) |
//+------------------------------------------------------------------+
void WilderATR(const MqlRates &r[], int n, int len, double &atr[])
  {
   ArrayResize(atr, n);
   ArrayInitialize(atr, EMPTY_VALUE);
   if(n < len) return;
   double sum = 0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low
                  : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < len - 1) { sum += tr; continue; }
      if(i == len - 1) { sum += tr; atr[i] = sum / len; continue; }
      atr[i] = (atr[i - 1] * (len - 1) + tr) / len;
     }
  }

void Supertrend(const MqlRates &r[], int n, double factor, int len, double &st[], double &dir[])
  {
   double atr[];
   WilderATR(r, n, len, atr);
   ArrayResize(st, n); ArrayResize(dir, n);
   double upPrev = 0, dnPrev = 0, stPrev = EMPTY_VALUE;
   for(int i = 0; i < n; i++)
     {
      double src = (r[i].high + r[i].low) / 2;
      bool   ok  = atr[i] != EMPTY_VALUE;
      double up  = ok ? src - factor * atr[i] : 0;
      double dn  = ok ? src + factor * atr[i] : 0;
      if(i > 0 && ok)
        {
         up = (up > upPrev || r[i - 1].close < upPrev) ? up : upPrev;
         dn = (dn < dnPrev || r[i - 1].close > dnPrev) ? dn : dnPrev;
        }
      double d;
      if(i == 0 || atr[i - 1] == EMPTY_VALUE) d = 1;
      else if(stPrev == dnPrev)                d = (r[i].close > dn) ? -1 : 1;
      else                                     d = (r[i].close < up) ? 1 : -1;
      st[i]  = ok ? (d == -1 ? up : dn) : EMPTY_VALUE;
      dir[i] = d;
      upPrev = up; dnPrev = dn; stPrev = st[i];
     }
  }

double Buf(int handle, int buffer, int shift)
  {
   double b[1];
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1) return EMPTY_VALUE;
   return b[0];
  }

//+------------------------------------------------------------------+
//| Positions of this EA                                             |
//+------------------------------------------------------------------+
int MyPositions(ulong &tickets[])
  {
   ArrayResize(tickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      int k = ArraySize(tickets); ArrayResize(tickets, k + 1); tickets[k] = tk;
     }
   return ArraySize(tickets);
  }

// Trade state is stored in the position comment: "OD|L|<entryRef>|<R>"
bool ReadState(ulong tk, bool &isLong, double &ref, double &R)
  {
   if(!PositionSelectByTicket(tk)) return false;
   isLong = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
   string parts[];
   if(StringSplit(PositionGetString(POSITION_COMMENT), '|', parts) == 4 && parts[0] == "OD")
     {
      ref = StringToDouble(parts[2]); R = StringToDouble(parts[3]);
      if(ref > 0 && R > 0) return true;
     }
   // fallback (comment lost): use fill price and current stop distance
   ref = PositionGetDouble(POSITION_PRICE_OPEN);
   R   = MathAbs(ref - PositionGetDouble(POSITION_SL));
   return R > 0;
  }

void Notify(const string msg)
  {
   Print(msg);
   if(InpPush && !MQLInfoInteger(MQL_TESTER)) SendNotification(msg);
   if(InpPopup && !MQLInfoInteger(MQL_TESTER)) Alert(msg);
  }

void CloseAll(const string why)
  {
   ulong tk[];
   int n = MyPositions(tk);
   for(int i = 0; i < n; i++) trade.PositionClose(tk[i]);
   if(n > 0) Notify("OD Gold " + _Symbol + " closed: " + why);
  }

//+------------------------------------------------------------------+
//| Daily counters from the deal history (restart-proof)             |
//| A "trade" = all positions opened on the same entry bar.          |
//+------------------------------------------------------------------+
void DailyCounts(datetime dayStart, int &tradesToday, int &lossesToday)
  {
   tradesToday = 0; lossesToday = 0;
   if(!HistorySelect(dayStart - 14 * 86400, TimeCurrent() + 60)) return;
   datetime keys[]; double net[]; datetime lastOut[];
   long     posId[]; datetime posKey[];
   int deals = HistoryDealsTotal();
   // pass 1: entry deals → key (entry bar time) per position id
   for(int i = 0; i < deals; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      int k = ArraySize(posId); ArrayResize(posId, k + 1); ArrayResize(posKey, k + 1);
      posId[k]  = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      posKey[k] = iTime(_Symbol, _Period, iBarShift(_Symbol, _Period, t));
     }
   // pass 2: sum net P/L per trade key
   for(int i = 0; i < deals; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      int  p = -1;
      for(int j = 0; j < ArraySize(posId); j++) if(posId[j] == pid) { p = j; break; }
      if(p < 0) continue;
      int k = -1;
      for(int j = 0; j < ArraySize(keys); j++) if(keys[j] == posKey[p]) { k = j; break; }
      if(k < 0)
        {
         k = ArraySize(keys);
         ArrayResize(keys, k + 1); ArrayResize(net, k + 1); ArrayResize(lastOut, k + 1);
         keys[k] = posKey[p]; net[k] = 0; lastOut[k] = 0;
        }
      net[k] += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION)
                + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
         lastOut[k] = MathMax(lastOut[k], (datetime)HistoryDealGetInteger(d, DEAL_TIME));
     }
   // open trades (their key must not count as finished)
   ulong tk[]; int n = MyPositions(tk);
   for(int k = 0; k < ArraySize(keys); k++)
     {
      if(keys[k] >= dayStart) tradesToday++;
      bool open = false;
      for(int i = 0; i < n; i++)
         if(PositionSelectByTicket(tk[i]) &&
            iTime(_Symbol, _Period, iBarShift(_Symbol, _Period, (datetime)PositionGetInteger(POSITION_TIME))) == keys[k]) open = true;
      if(!open && lastOut[k] >= dayStart && net[k] < 0) lossesToday++;
     }
  }

//+------------------------------------------------------------------+
//| Lot size for a stop distance (price units per 1 unit of volume)  |
//+------------------------------------------------------------------+
double LotsFor(double dist, double riskMoney)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) return 0;
   // Money lost by 1.0 lot over the stop distance, computed by the terminal itself
   // (robust to any contract size / tick-value setup of the broker).
   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID), lossPerLot = 0, pl = 0;
   if(px > 0 && OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, px, px - dist, pl) && pl < 0)
      lossPerLot = -pl;
   else if(tickSize > 0 && tickValue > 0)
      lossPerLot = dist / tickSize * tickValue;
   if(lossPerLot <= 0) return 0;
   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   if(lots < vmin)
     {
      if(InpSkipBelowMin) return 0;
      if(lossPerLot * vmin > AccountInfoDouble(ACCOUNT_EQUITY) * InpMaxRiskPct / 100) return 0;
      lots = vmin;
     }
   lots = NormalizeDouble(MathMin(lots, vmax), 2);
   PrintFormat("OD_GoldV2_EA sizing: stop %.2f | loss per 1.0 lot %.2f | lots %.2f | risk %.2f (%.2f%% of equity)",
               dist, lossPerLot, lots, lots * lossPerLot, 100 * lots * lossPerLot / AccountInfoDouble(ACCOUNT_EQUITY));
   return lots;
  }

//+------------------------------------------------------------------+
//| Main: everything runs once per new bar on the closed bar (shift 1) |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime bar0 = iTime(_Symbol, _Period, 0);
   if(bar0 == 0 || bar0 == lastBar) return;

   int need = (int)MathMax(InpCalcBars, InpStLen * 20);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, _Period, 1, need, r);     // closed bars only, oldest → newest
   if(n < 300) return;                                   // wait for history
   lastBar = bar0;
   int i1 = n - 1, i2 = n - 2;                            // shift 1 (signal bar), shift 2

   //--- indicators on the closed bar
   double st[], dir[], atr[];
   Supertrend(r, n, InpStFac, InpStLen, st, dir);
   WilderATR(r, n, InpAtrLen, atr);
   double ema   = Buf(hEma, 0, 1);
   double adx   = Buf(hAdx, 0, 1);
   double htfE  = Buf(hHtfEma, 0, 1);
   double htfC  = iClose(_Symbol, InpHtfTF, 1);
   double c1    = r[i1].close;
   double atr1  = atr[i1];
   if(ema == EMPTY_VALUE || atr1 == EMPTY_VALUE || st[i1] == EMPTY_VALUE) return;

   bool stUp   = dir[i1] < dir[i2];                       // Pine: ta.change(dir) < 0
   bool stDown = dir[i1] > dir[i2];

   //--- time filters, evaluated at the entry time = this new bar's open
   datetime loc = ServerToLocal(bar0);
   MqlDateTime ls; TimeToStruct(loc, ls);
   int  m        = ls.hour * 60 + ls.min;
   bool inSess   = !mSess || (InpUseLon && InWin(m, InpLonStart, InpLonEnd)) || (InpUseNY && InWin(m, InpNYStart, InpNYEnd));
   bool firstFri = ls.day_of_week == 5 && ls.day <= 7;
   bool monFri   = ls.day_of_week >= 1 && ls.day_of_week <= 5;
   bool inNews   = mNews && ((InpUseNfp && firstFri && InWin(m, InpNfpStart, InpNfpEnd)) ||
                             (InpUseDaily && monFri && InWin(m, InpDlyStart, InpDlyEnd)) ||
                             NearEvent(loc, InpUseE1, InpE1) || NearEvent(loc, InpUseE2, InpE2) ||
                             NearEvent(loc, InpUseE3, InpE3) || NearEvent(loc, InpUseE4, InpE4));
   bool eodNow   = mEod && InWin(m, InpEodStart, InpEodEnd);
   bool inRange  = r[i1].time >= InpStart && r[i1].time < InpEnd;

   //--- open trade: management on the closed bar (BE / trailing), forced exits
   ulong tk[];
   int npos = MyPositions(tk);
   if(npos > 0)
     {
      bool isLong; double ref, R;
      if(ReadState(tk[0], isLong, ref, R))
        {
         // best price since entry over CLOSED bars (fill bar included)
         datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
         int sh = iBarShift(_Symbol, _Period, openT);
         double best = isLong ? r[i1].high : r[i1].low;
         for(int k = 1; k <= sh && k <= n; k++)
            best = isLong ? MathMax(best, r[n - k].high) : MathMin(best, r[n - k].low);
         double moveR = (isLong ? best - ref : ref - best) / R;
         double curSL = PositionGetDouble(POSITION_SL);
         double newSL = curSL;
         if(mBE && moveR >= InpBeR)
           {
            double be = isLong ? ref + InpBeOff : ref - InpBeOff;
            if(isLong ? be > newSL : be < newSL) newSL = be;
           }
         if(mTrail && moveR >= InpTrailStart)
           {
            double tr = isLong ? c1 - InpTrailMult * atr1 : c1 + InpTrailMult * atr1;
            if(isLong ? tr > newSL : tr < newSL) newSL = tr;
           }
         newSL = NormalizeDouble(newSL, _Digits);
         if(newSL != NormalizeDouble(curSL, _Digits))
           {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
            bool beyond = isLong ? newSL >= bid - lvl : newSL <= ask + lvl;
            if(beyond)
               CloseAll(StringFormat("stop %.2f already reached at the open", newSL));   // Pine fills at the open
            else
               for(int k = 0; k < npos; k++)
                  if(PositionSelectByTicket(tk[k]))
                     trade.PositionModify(tk[k], newSL, PositionGetDouble(POSITION_TP));
           }
        }
      if(MyPositions(tk) > 0 && (eodNow || (inNews && InpNewsFlat)))
         CloseAll(eodNow ? "EOD flatten" : "news blackout");
      return;                                             // one trade at a time
     }

   //--- new entries
   int tradesToday = 0, lossesToday = 0;
   DailyCounts(iTime(_Symbol, PERIOD_D1, 0), tradesToday, lossesToday);
   bool limitsOk = !mLimits || ((InpMaxTrades == 0 || tradesToday < InpMaxTrades) && (InpMaxLosses == 0 || lossesToday < InpMaxLosses));
   if(!inRange || !inSess || inNews || eodNow || !limitsOk) return;

   bool adxOk  = !mAdx  || (adx != EMPTY_VALUE && adx >= InpAdxMin);
   bool distOk = !mDist || MathAbs(c1 - ema) >= InpDistAtr * atr1;
   bool htfL   = !mHtf  || (htfC > 0 && htfE != EMPTY_VALUE && htfC > htfE);
   bool htfS   = !mHtf  || (htfC > 0 && htfE != EMPTY_VALUE && htfC < htfE);
   bool longSetup  = InpLong  && stUp   && c1 > ema && htfL && adxOk && distOk;
   bool shortSetup = InpShort && stDown && c1 < ema && htfS && adxOk && distOk;
   if(!longSetup && !shortSetup) return;

   bool   lng  = longSetup;
   double raw  = mAtrSL ? (lng ? c1 - InpSlAtrMult * atr1 : c1 + InpSlAtrMult * atr1) : st[i1];
   double dist = lng ? c1 - raw : raw - c1;
   double unit = InpCapUnit == OD_CAP_ATR ? atr1 : 1.0;
   if(dist <= 0) return;
   if(mCaps)
     {
      if(InpMinSL > 0 && dist < InpMinSL * unit) dist = InpMinSL * unit;
      if(InpMaxSL > 0 && dist > InpMaxSL * unit)
        {
         if(InpMaxAct == OD_MAX_SKIP) { Print("OD_GoldV2_EA: stop wider than max cap — trade skipped"); return; }
         dist = InpMaxSL * unit;
        }
     }
   double sl  = NormalizeDouble(lng ? c1 - dist : c1 + dist, _Digits);
   double tp  = mNoTP ? 0 : NormalizeDouble(lng ? c1 + dist * InpRR : c1 - dist * InpRR, _Digits);
   double tp1 = NormalizeDouble(lng ? c1 + dist * InpPartR : c1 - dist * InpPartR, _Digits);

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100;
   double lots = LotsFor(dist, riskMoney);
   if(lots <= 0)
     {
      Notify(StringFormat("OD Gold %s %s signal SKIPPED: stop $%.2f needs less than the minimum lot for %.2f%% risk",
                          _Symbol, lng ? "BUY" : "SELL", dist, InpRiskPct));
      return;
     }
   string cmt = StringFormat("OD|%s|%.3f|%.3f", lng ? "L" : "S", c1, dist);

   bool ok;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double l1 = mPart ? NormalizeDouble(MathFloor(lots * InpPartPct / 100 / step) * step, 2) : 0;
   double l2 = NormalizeDouble(lots - l1, 2);
   if(mPart && l1 >= vmin && l2 >= vmin)
     {
      ok = lng ? trade.Buy(l1, _Symbol, 0, sl, tp1, cmt) : trade.Sell(l1, _Symbol, 0, sl, tp1, cmt);
      ok = (lng ? trade.Buy(l2, _Symbol, 0, sl, tp, cmt) : trade.Sell(l2, _Symbol, 0, sl, tp, cmt)) && ok;
     }
   else
      ok = lng ? trade.Buy(lots, _Symbol, 0, sl, tp, cmt) : trade.Sell(lots, _Symbol, 0, sl, tp, cmt);

   Notify(StringFormat("OD Gold %s %s | Entry≈%.2f | SL %.2f (%.2f) | TP %s | %.2f lot%s",
                       _Symbol, lng ? "BUY" : "SELL", c1, sl, dist,
                       tp > 0 ? DoubleToString(tp, 2) : "trailing", lots, ok ? "" : " | ORDER FAILED " + IntegerToString(trade.ResultRetcode())));
  }

//+------------------------------------------------------------------+
//| Push a message when a position of this EA closes                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic || HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   long e = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY) return;
   double pl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
               + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   Notify(StringFormat("OD Gold %s exit at %.2f | P/L %.2f %s", _Symbol, HistoryDealGetDouble(trans.deal, DEAL_PRICE),
                       pl, AccountInfoString(ACCOUNT_CURRENCY)));
  }
//+------------------------------------------------------------------+
