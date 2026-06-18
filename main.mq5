#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;


// =============================================================================
// H4 EMA Pullback — Next Level Expert Advisor
//
// Strategy: Trade pullbacks to the EMA50 zone in the direction of the EMA50/200
// trend. Entry on a candle that touches the zone, closes bullish/bearish, and
// reclaims the EMA21. Take-profit targets the nearest swing high/low (fractal)
// beyond the entry; falls back to a fixed RR multiple if no valid level exists.
//
// Risk is sized from account balance with hard lot caps. Multiple optional
// filters (ADX, body ratio, EMA slope, break-of-previous-candle, reclaim
// buffer) can be enabled independently via inputs.
// =============================================================================


// ============================================================
// INPUTS
// ============================================================

// ── Risk Management ──────────────────────────────────────────
input double RiskPercent    = 0.50;   // Risk per trade (% of balance)
input double MaxLot         = 0.10;   // Hard cap on lot size
input double MinLot         = 0.10;   // Minimum lot size to trade

// ── Timeframe ────────────────────────────────────────────────
input ENUM_TIMEFRAMES TF    = PERIOD_H4;

// ── Indicator Periods ────────────────────────────────────────
input int AtrPeriod         = 14;
input int EmaFastPeriod     = 50;
input int EmaSlowPeriod     = 200;
input int EmaMidPeriod      = 21;

// ── Zone & Stop Loss ─────────────────────────────────────────
input double ZoneAtrMult    = 0.40;   // Pullback must reach EMA50 ± (ATR × mult)
input double SlBufferAtr    = 0.20;   // SL placed beyond pullback extreme by (ATR × mult)
input double MinSlAtr       = 1.00;   // Minimum SL distance in ATR units

// ── ADX Filter ───────────────────────────────────────────────
input bool   UseAdxFilter   = false;
input int    AdxPeriod      = 14;
input double MinAdx         = 20.0;

// ── Trade Controls ───────────────────────────────────────────
input double MaxSpreadPrice    = 0.40;   // Maximum allowable spread (price units)
input int    MaxTradesPerDay   = 1;      // Daily trade limit
input double MaxDailyLossPct   = 3.0;   // Daily drawdown limit (% of start equity)

// ── Trading Window (server time) ─────────────────────────────
input int  TradeStartHour    = 0;    // Window open  (00 = midnight)
input int  TradeEndHour      = 0;    // Window close (00 = midnight, wrap = always on)
input bool ForceCloseAtEnd   = false; // Close open position when outside window

// ── Take-Profit: Next Swing Level ────────────────────────────
input int    SwingLeft         = 2;
input int    SwingRight        = 2;
input int    LevelLookbackBars = 300;
input double MinTpAtr          = 1.2;   // TP must be at least (ATR × mult) from entry
input double FallbackRR        = 3.0;   // Fallback TP = risk × RR if no level found

// ── Safety Patch ─────────────────────────────────────────────
input bool StrictRiskSizing  = false;   // Skip trade if raw lots < MinLot
input bool ValidateStops     = true;    // Enforce broker stops/freeze level
input bool LogTradeFailures  = true;    // Print failed order details

// ── Optional False-Break Filters ─────────────────────────────

// 1. Signal candle body/range commitment
input bool   UseBodyRatioFilter       = false;
input double MinBodyRatio             = 0.55;   // Body must be ≥ 55% of candle range

// 2. Signal candle must break previous candle high/low
input bool   UseBreakOfPreviousCandle = false;
input double BreakBufferAtr           = 0.00;   // Extra buffer beyond H2/L2 (ATR units)

// 3. Close must clear EMA21 by a buffer (avoid barely reclaiming)
input bool   UseReclaimBuffer         = false;
input double ReclaimBufferAtr         = 0.10;   // Close > EMA21 + (ATR × mult) for longs

// 4. EMA50 slope must align with trade direction
input bool UseEmaSlopeFilter          = false;
input int  EmaSlopeBars               = 4;       // Compare EMA50[1] vs EMA50[1 + bars]


// ============================================================
// GLOBALS
// ============================================================

datetime lastBarTime     = 0;

int atrHandle            = INVALID_HANDLE;
int ema50Handle          = INVALID_HANDLE;
int ema200Handle         = INVALID_HANDLE;
int ema21Handle          = INVALID_HANDLE;
int adxHandle            = INVALID_HANDLE;

int    dayOfYearStored   = -1;
double dayStartEquity    = 0.0;
int    tradesToday       = 0;


// ============================================================
// TIME HELPERS
// ============================================================

bool InHourWindow(datetime t, int startHour, int endHour)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);

   // Straight window (e.g. 08:00 – 17:00)
   if(startHour < endHour)
      return (dt.hour >= startHour && dt.hour < endHour);

   // Wrap-around window (e.g. 22:00 – 06:00) or start == end (always on)
   return (dt.hour >= startHour || dt.hour < endHour);
}

bool IsTradeTimeNow()
{
   return InHourWindow(TimeCurrent(), TradeStartHour, TradeEndHour);
}


// ============================================================
// GENERIC HELPERS
// ============================================================

int DayOfYear(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_year;
}

void ResetDailyIfNeeded()
{
   int doy = DayOfYear(TimeCurrent());
   if(doy != dayOfYearStored)
   {
      dayOfYearStored = doy;
      dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      tradesToday     = 0;
   }
}

bool HitDailyLossLimit()
{
   if(dayStartEquity <= 0.0) return false;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (dayStartEquity - eq) / dayStartEquity * 100.0;
   return ddPct >= MaxDailyLossPct;
}

bool SpreadOk()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ask - bid) <= MaxSpreadPrice;
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, TF, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

// Read a single value from an indicator buffer at a given shift
double GetBuf(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0.0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
}

double GetATR(int shift)   { return GetBuf(atrHandle,   shift); }
double GetEMA50(int shift)  { return GetBuf(ema50Handle,  shift); }
double GetEMA200(int shift) { return GetBuf(ema200Handle, shift); }
double GetEMA21(int shift)  { return GetBuf(ema21Handle,  shift); }
double GetADX(int shift)    { return GetBuf(adxHandle,    shift); }


// ============================================================
// SAFETY: STOPS / FREEZE LEVEL VALIDATION
// ============================================================

double MinStopDistancePrice()
{
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopsLevel   = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long lvl          = (stopsLevel > freezeLevel) ? stopsLevel : freezeLevel;
   return (double)lvl * point;
}

bool IsSlTpValidForEntry(bool isLong, double entry, double sl, double tp)
{
   if(!ValidateStops) return true;

   double minDist = MinStopDistancePrice();
   if(minDist <= 0.0) return true;

   if(isLong)
   {
      if(!(sl < entry && tp > entry)) return false;
      if((entry - sl) < minDist)      return false;
      if((tp - entry) < minDist)      return false;
   }
   else
   {
      if(!(sl > entry && tp < entry)) return false;
      if((sl - entry) < minDist)      return false;
      if((entry - tp) < minDist)      return false;
   }

   return true;
}

void LogFail(string context)
{
   if(!LogTradeFailures) return;
   Print(context,
         " failed. retcode=",        trade.ResultRetcode(),
         " desc=",                   trade.ResultRetcodeDescription(),
         " lastError=",              GetLastError());
}


// ============================================================
// LOT SIZING
// ============================================================

double NormalizeLot(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(minLot, MathMin(lots, maxLot));
   lots = MathFloor(lots / step) * step;
   if(lots < minLot) lots = minLot;
   return lots;
}

double LotsFromRisk(double slDistancePrice, bool &skipDueToStrictRisk)
{
   skipDueToStrictRisk = false;
   if(slDistancePrice <= 0.0) return 0.0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (RiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   double moneyPerLot = (slDistancePrice / tickSize) * tickValue;
   if(moneyPerLot <= 0.0) return 0.0;

   double rawLots = riskMoney / moneyPerLot;

   if(StrictRiskSizing && rawLots < MinLot)
   {
      skipDueToStrictRisk = true;
      return 0.0;
   }

   double lots = MathMin(rawLots, MaxLot);
   lots        = MathMax(lots,    MinLot);
   return NormalizeLot(lots);
}


// ============================================================
// FRACTAL SWING LEVEL DETECTION
// ============================================================

bool IsSwingHigh(int i)
{
   int bars = Bars(_Symbol, TF);
   if(i - SwingLeft  < 0)    return false;
   if(i + SwingRight >= bars) return false;

   double hi = iHigh(_Symbol, TF, i);
   if(hi == 0.0) return false;

   for(int k = 1; k <= SwingLeft;  k++)
      if(iHigh(_Symbol, TF, i - k) >= hi) return false;

   for(int k = 1; k <= SwingRight; k++)
      if(iHigh(_Symbol, TF, i + k) >  hi) return false;

   return true;
}

bool IsSwingLow(int i)
{
   int bars = Bars(_Symbol, TF);
   if(i - SwingLeft  < 0)    return false;
   if(i + SwingRight >= bars) return false;

   double lo = iLow(_Symbol, TF, i);
   if(lo == 0.0) return false;

   for(int k = 1; k <= SwingLeft;  k++)
      if(iLow(_Symbol, TF, i - k) <= lo) return false;

   for(int k = 1; k <= SwingRight; k++)
      if(iLow(_Symbol, TF, i + k) <  lo) return false;

   return true;
}

// Returns the nearest swing high (long) or swing low (short) beyond entry
double FindNextLevelTP(bool isLong, double entry)
{
   int bars  = Bars(_Symbol, TF);
   int start = SwingRight + 5;
   int end   = MathMin(LevelLookbackBars, bars - SwingLeft - SwingRight - 5);
   if(end <= start) return 0.0;

   double best = 0.0;

   for(int i = start; i <= end; i++)
   {
      if(isLong)
      {
         if(!IsSwingHigh(i)) continue;
         double lvl = iHigh(_Symbol, TF, i);
         if(lvl <= entry) continue;
         if(best == 0.0 || lvl < best) best = lvl;   // closest level above entry
      }
      else
      {
         if(!IsSwingLow(i)) continue;
         double lvl = iLow(_Symbol, TF, i);
         if(lvl >= entry) continue;
         if(best == 0.0 || lvl > best) best = lvl;   // closest level below entry
      }
   }

   return best;
}


// ============================================================
// OPTIONAL FALSE-BREAK FILTER HELPERS
// ============================================================

// Filter 1 — Candle body/range ratio (commitment filter)
bool PassBodyRatioFilter()
{
   if(!UseBodyRatioFilter) return true;

   double o1    = iOpen(_Symbol,  TF, 1);
   double c1    = iClose(_Symbol, TF, 1);
   double h1    = iHigh(_Symbol,  TF, 1);
   double l1    = iLow(_Symbol,   TF, 1);
   double range = h1 - l1;
   if(range <= 0.0) return false;

   double body  = MathAbs(c1 - o1);
   return (body / range) >= MinBodyRatio;
}

// Filter 2 — EMA50 slope aligned with trade direction
bool PassEmaSlopeFilter(bool isLong)
{
   if(!UseEmaSlopeFilter) return true;

   int    shift2  = 1 + MathMax(1, EmaSlopeBars);
   double emaNow  = GetEMA50(1);
   double emaPast = GetEMA50(shift2);
   if(emaNow == 0.0 || emaPast == 0.0) return false;

   return isLong ? (emaNow > emaPast) : (emaNow < emaPast);
}

// Filter 3 — Signal candle closes beyond previous candle H/L
bool PassBreakOfPreviousCandle(bool isLong, double atr)
{
   if(!UseBreakOfPreviousCandle) return true;

   double c1  = iClose(_Symbol, TF, 1);
   double h2  = iHigh(_Symbol,  TF, 2);
   double l2  = iLow(_Symbol,   TF, 2);
   double buf = BreakBufferAtr * atr;

   return isLong ? (c1 > h2 + buf) : (c1 < l2 - buf);
}

// Filter 4 — Close clears EMA21 by an ATR buffer (not just barely reclaiming)
bool PassReclaimBuffer(bool isLong, double atr, double ema21)
{
   if(!UseReclaimBuffer) return true;

   double c1  = iClose(_Symbol, TF, 1);
   double buf = ReclaimBufferAtr * atr;

   return isLong ? (c1 > ema21 + buf) : (c1 < ema21 - buf);
}


// ============================================================
// SIGNAL LOGIC
// ============================================================

bool LongSignal(double atr, double ema50, double ema200, double ema21)
{
   // Trend filter: EMA50 must be above EMA200 (uptrend)
   if(ema50 <= ema200) return false;

   double o1 = iOpen(_Symbol,  TF, 1);
   double c1 = iClose(_Symbol, TF, 1);
   double l1 = iLow(_Symbol,   TF, 1);

   bool touchedZone = l1 <= (ema50 + ZoneAtrMult * atr);   // Wick reached EMA50 zone
   bool bullClose   = c1 > o1;                              // Candle closed bullish
   bool reclaim     = c1 > ema21;                           // Close above EMA21

   if(UseAdxFilter && GetADX(1) < MinAdx) return false;

   if(!PassBodyRatioFilter())                  return false;
   if(!PassEmaSlopeFilter(true))               return false;
   if(!PassBreakOfPreviousCandle(true, atr))   return false;
   if(!PassReclaimBuffer(true, atr, ema21))    return false;

   return touchedZone && bullClose && reclaim;
}

bool ShortSignal(double atr, double ema50, double ema200, double ema21)
{
   // Trend filter: EMA50 must be below EMA200 (downtrend)
   if(ema50 >= ema200) return false;

   double o1 = iOpen(_Symbol,  TF, 1);
   double c1 = iClose(_Symbol, TF, 1);
   double h1 = iHigh(_Symbol,  TF, 1);

   bool touchedZone = h1 >= (ema50 - ZoneAtrMult * atr);   // Wick reached EMA50 zone
   bool bearClose   = c1 < o1;                              // Candle closed bearish
   bool reclaim     = c1 < ema21;                           // Close below EMA21

   if(UseAdxFilter && GetADX(1) < MinAdx) return false;

   if(!PassBodyRatioFilter())                  return false;
   if(!PassEmaSlopeFilter(false))              return false;
   if(!PassBreakOfPreviousCandle(false, atr))  return false;
   if(!PassReclaimBuffer(false, atr, ema21))   return false;

   return touchedZone && bearClose && reclaim;
}


// ============================================================
// INIT / DEINIT
// ============================================================

int OnInit()
{
   atrHandle   = iATR(_Symbol, TF, AtrPeriod);
   if(atrHandle == INVALID_HANDLE) return INIT_FAILED;

   ema50Handle  = iMA(_Symbol, TF, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   ema200Handle = iMA(_Symbol, TF, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   ema21Handle  = iMA(_Symbol, TF, EmaMidPeriod,  0, MODE_EMA, PRICE_CLOSE);

   if(ema50Handle  == INVALID_HANDLE ||
      ema200Handle == INVALID_HANDLE ||
      ema21Handle  == INVALID_HANDLE)
      return INIT_FAILED;

   if(UseAdxFilter)
   {
      adxHandle = iADX(_Symbol, TF, AdxPeriod);
      if(adxHandle == INVALID_HANDLE) return INIT_FAILED;
   }

   ResetDailyIfNeeded();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle   != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(ema50Handle  != INVALID_HANDLE) IndicatorRelease(ema50Handle);
   if(ema200Handle != INVALID_HANDLE) IndicatorRelease(ema200Handle);
   if(ema21Handle  != INVALID_HANDLE) IndicatorRelease(ema21Handle);
   if(adxHandle   != INVALID_HANDLE) IndicatorRelease(adxHandle);
}


// ============================================================
// ONTICK — MAIN EXECUTION
// ============================================================

void OnTick()
{
   // Force-close if outside trade window (optional)
   if(ForceCloseAtEnd && PositionSelect(_Symbol) && !IsTradeTimeNow())
   {
      trade.PositionClose(_Symbol);
      return;
   }

   // Only act on new bar close — strategy is bar-based, not tick-based
   if(!IsNewBar()) return;

   // ── Daily reset & guards ───────────────────────────────────
   ResetDailyIfNeeded();
   if(HitDailyLossLimit())            return;
   if(tradesToday >= MaxTradesPerDay) return;
   if(!SpreadOk())                    return;
   if(!IsTradeTimeNow())              return;
   if(PositionSelect(_Symbol))        return;   // one trade at a time

   // ── Read indicators ───────────────────────────────────────
   double atr1    = GetATR(1);
   if(atr1 <= 0.0) return;

   double ema50_1  = GetEMA50(1);
   double ema200_1 = GetEMA200(1);
   double ema21_1  = GetEMA21(1);
   if(ema50_1 == 0.0 || ema200_1 == 0.0 || ema21_1 == 0.0) return;

   // ── Signal evaluation ─────────────────────────────────────
   bool goLong  = LongSignal(atr1, ema50_1, ema200_1, ema21_1);
   bool goShort = ShortSignal(atr1, ema50_1, ema200_1, ema21_1);
   if(goLong == goShort) return;   // both true or both false — no clean signal

   // ── Price data ────────────────────────────────────────────
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double h1  = iHigh(_Symbol, TF, 1);
   double l1  = iLow(_Symbol,  TF, 1);

   // ── Entry price ───────────────────────────────────────────
   double entry = goLong ? ask : bid;

   // ── Stop loss ─────────────────────────────────────────────
   double minSlDist = MathMax(MinSlAtr * atr1, 10 * point);
   double sl        = goLong
                        ? (l1 - SlBufferAtr * atr1)   // below candle low
                        : (h1 + SlBufferAtr * atr1);  // above candle high
   double slDist    = MathAbs(entry - sl);

   // Enforce minimum SL distance
   if(slDist < minSlDist)
   {
      sl     = goLong ? (entry - minSlDist) : (entry + minSlDist);
      slDist = minSlDist;
   }

   // ── Take profit ───────────────────────────────────────────
   double next = FindNextLevelTP(goLong, entry);
   double tp   = 0.0;

   if(goLong)
      tp = (next > entry && (next - entry) >= MinTpAtr * atr1)
             ? next
             : (entry + slDist * FallbackRR);
   else
      tp = (next < entry && (entry - next) >= MinTpAtr * atr1)
             ? next
             : (entry - slDist * FallbackRR);

   // ── Validate SL/TP against broker stops level ─────────────
   if(!IsSlTpValidForEntry(goLong, entry, sl, tp)) return;

   // ── Lot sizing ────────────────────────────────────────────
   bool   skipped = false;
   double lots    = LotsFromRisk(slDist, skipped);
   if(skipped || lots <= 0.0) return;

   // ── Place order ───────────────────────────────────────────
   trade.SetDeviationInPoints(30);

   bool ok = goLong
               ? trade.Buy( lots, _Symbol, entry, sl, tp, "H4 NextLevel LONG")
               : trade.Sell(lots, _Symbol, entry, sl, tp, "H4 NextLevel SHORT");

   if(!ok)
   {
      LogFail(goLong ? "Buy" : "Sell");
      return;
   }

   tradesToday++;
}
