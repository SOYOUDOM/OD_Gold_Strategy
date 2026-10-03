# OD Gold Strategy v2 (XAUUSD · OANDA · 15m)

This is a Pine Script v6 trend-following system for gold. It trades Supertrend flips in the direction of the 200 EMA. Version 2 adds filters and trade-management options, and each one can be switched on and off so you can A/B test it.

| File | Type | Use it for |
|---|---|---|
| `OD_GoldStrategy.pine` | `strategy()` | Backtesting in TradingView's Strategy Tester |
| `OD_GoldSignals.pine` | `indicator()` | Live charting: BUY/SELL labels with Entry/SL/TP, dashed level lines, exit markers, alerts |
| `mql5/OD_GoldV2_EA.mq5` | MT5 Expert Advisor | Same rules, automated trading + free phone push alerts (§6b) |
| `research/od_backtest.py` | Python | Multi-year backtest replica used for §5.6 |

Each file is a single script, so the two together fit the free plan's 2-indicators-per-chart limit. Both files use the same inputs and rules. The sections marked `(SHARED)` (inputs, indicators, time helpers, HTF trend, entry filters) are copied 1:1 between the files. **If you edit a shared section in one file, copy it to the other.**

---

## 1. Quick start

1. Open **OANDA:XAUUSD** on the **15m** chart.
2. Pine Editor → paste `OD_GoldStrategy.pine` → *Add to chart*. Open the **Strategy Tester** tab.
3. (Optional, for live use) add `OD_GoldSignals.pine` as a second script. Its inputs must match the strategy's.
4. If you will type one-off news times: chart *Settings → Symbol → Time zone → (UTC+7) Bangkok*. The date/time picker uses the chart's time zone.

**Properties tab of the strategy** (these are coded defaults, and you can change them there):
initial capital $1,000 · commission **0.15 USD per contract per side** (1 contract = 1 oz = 0.01 lot → $0.30/oz round trip ≈ spread) · slippage 0 · **margin 1%** (1:100 leverage).

> v1 used Pine's default 100% margin. At that margin a $1,000 account cannot hold 2+ oz of gold at today's prices, so the tester may have limited or margin-called some v1 trades. To compare v1 with v2, use **Preset = Baseline v1 inside this script** rather than your old screenshots.

---

## 2. The rules

### v1 rules (always on)
| # | Rule |
|---|---|
| 1 | **Trend:** buy only if the signal bar closes above EMA(200), sell only if it closes below. |
| 2 | **Trigger:** Supertrend(ATR 10, factor 3) changes direction on a **closed** bar. |
| 3 | **Entry:** market order, filled at the **open of the next bar**. |
| 4 | **Stop:** Supertrend line of the signal bar. |
| 5 | **Target:** entry ± stop distance × R:R (2.0). |
| 6 | **Size:** equity × risk % ÷ stop distance (oz). |
| 7 | One position at a time, no pyramiding. |

Every R level (SL, TP, TP1, breakeven) is measured from the **signal-bar close**, which the labels call "Entry ≈". The real fill is the next bar's open. On 15m gold the gap between the two is normally a few cents.

### v2 additions (each one toggleable)
Session filter · ADX and EMA-distance chop filters · higher-timeframe trend agreement · ATR stop option · min/max stop caps · breakeven · partial close · ATR trailing stop · daily trade and loss limits · news blackout windows · optional end-of-day flatten.

**Preset = "Baseline v1"** turns off every v2 feature in one click, whatever the individual toggles say. The only setting that still applies is *Quantity step*, which defaults to 0 (= v1 behaviour).

---

## 3. Inputs reference

### 0 · Preset
| Input | Default | What it does |
|---|---|---|
| Preset | Improved | `Baseline v1` = original rules only. `Improved` = use the toggles below. |

### 1 · Backtest window
| Input | Default | What it does |
|---|---|---|
| Start / End | 2020-01-01 / 2099-12-31 | New entries only between these dates. A trade that is already open keeps being managed. Use these dates for the in-sample/out-of-sample split (§5). |

### 2 · Core signal (v1)
| Input | Default | What it does |
|---|---|---|
| Supertrend ATR length / factor | 10 / 3.0 | Trigger settings. |
| Trend EMA length | 200 | Direction filter. |
| Allow buys / sells | on / on | Turn off one side to test longs and shorts separately. |

### 3 · Stop-loss, target & size
| Input | Default | What it does |
|---|---|---|
| Stop-loss type | Supertrend | `Supertrend` = v1. `ATR` = entry ∓ ATR × multiple. |
| ATR length | 14 | One ATR (Wilder) used for the ATR stop, caps, trailing stop and EMA-distance filter. |
| ATR stop multiple | 2.0 | Used only when the stop type is ATR. |
| Use min/max stop distance | on | Caps for both stop types. |
| Cap units | ATR | `ATR` adapts to volatility, which is more robust across years. `Price ($)` = fixed $/oz. |
| Min stop distance | 1.0 | A closer stop is **widened** to this distance (avoids noise stops and oversized positions). 0 = off. |
| Max stop distance | 5.0 | A wider stop triggers the rule below (spike or news candles). 0 = off. |
| If stop > max | Skip trade | `Skip trade`, or `Clamp to max` (tighten the stop to the cap). |
| Risk : Reward | 2.0 | Final target in R. |
| Risk % per trade | 1.0 | Position size = equity × % ÷ stop distance. |
| Quantity step (oz) | 0 | 0 = fractional oz (v1). **1 = MT5 0.01-lot steps**: rounds down, and a trade that rounds to 0 is skipped. Use 1 to see what a small account can really trade. |

### 4 · Trade management
All of these are evaluated on the bar close and take effect from the next bar, the same way in the strategy, the indicator and the EA.

| Input | Default | What it does |
|---|---|---|
| Breakeven at R | off, 1.0 | Once price has reached 1R, the stop moves to entry ± offset. It never moves the stop backwards. |
| Breakeven offset ($) | 0.30 | ≈ round-trip cost, so a breakeven exit comes out around $0 instead of a small loss. |
| Partial close % at R | off, 50% at 1.0R | A limit order closes this % at TP1. The rest runs to the final target or stop. |
| ATR trailing stop × ATR | **on, 3.0** | On each closed bar: stop = max(stop, close − ATR × mult) for buys (mirrored for sells). |
| Trailing starts at R | 1.0 | Trailing activates after this much favourable move. 0 = from entry. |
| Trailing: remove the fixed target | **on** | On = no TP. The trade exits only on the trailing stop ("let winners run"). |

### 5 · Sessions (all times in the chosen time zone, default **GMT+7**)
Windows are checked at the **entry time**, which is the open of the bar after the signal. A signal on the 13:45 bar fills at 14:00, so it is inside a window that starts at 14:00.

| Input | Default (GMT+7) | Equivalent |
|---|---|---|
| Time zone | GMT+7 | Phnom Penh. GMT+0/+2/+3 are offered for MT5 server-time comparisons. |
| Trade only inside these windows | on | Skips the Asian session. |
| London | 14:00–18:00 | 07:00–11:00 UTC |
| New York | 19:30–23:30 | 12:30–16:30 UTC (US data, London/NY overlap) |
| Flatten open trade | off, 03:30–05:00 | Closes an open trade before the 17:00 New York rollover/swap (04:00–05:00 GMT+7). |

> GMT+7 has no daylight-saving time, but London and New York do. In their winter, the real sessions start one hour later in GMT+7. The defaults sit inside both. Widen them if you want the whole session.

### 6 · Chop filters
| Input | Default | What it does |
|---|---|---|
| ADX ≥ / length | off, 20 / 14 | Trades only when ADX(14) ≥ 20. Supertrend whipsaws when there is no trend. |
| \|close − EMA\| ≥ × ATR | off, 0.5 | Skips signals while price hugs the 200 EMA. |

### 7 · Higher-timeframe trend
| Input | Default | What it does |
|---|---|---|
| Require HTF trend agreement | on | Buy only if the **last closed** HTF bar closed above its EMA. Sell only if below. |
| HTF / HTF EMA length | 60 (1H) / 200 | 1H EMA 200 ≈ 8 trading days. 1H EMA 50 would be nearly the same line as the 15m EMA 200, so it would add little. |

### 8 · Daily limits
| Input | Default | What it does |
|---|---|---|
| Max trades per day | 3 | Counted when the entry is sent. 0 = off. |
| Stop after X losing trades per day | 2 | A loss = net P/L of the whole trade (including any partial) < 0 after costs. 0 = off. |

The day resets on the symbol's daily bar. For OANDA that is 17:00 New York = 04:00/05:00 GMT+7. Your London and NY sessions therefore always fall in the same trading day, and MT5 D1 bars on NY-aligned servers reset at the same moment.

### 9 · News blackout
| Input | Default | What it does |
|---|---|---|
| Enable news blackout | on | No new entries when the entry time falls in a window. |
| Also close an open trade when a blackout starts | off | Market exit at the first bar inside the window. |
| NFP (1st Friday) | on, 19:00–21:30 | Only on the first Friday of each month. Covers the 8:30 New York release in summer (19:30) and winter (20:30). |
| Every Mon–Fri | off, 19:15–20:45 | A blunt filter for every 8:30 NY release (CPI, PPI, retail sales, claims…). |
| One-off events: minutes before / after | 30 / 60 | Window placed around each enabled event below. |
| Event 1…4 | off | Exact date/time of CPI, FOMC, etc. (set the chart time zone to UTC+7 first). |

One-off events only help in live trading. A backtest covers too many dates to type them all, which is why the recurring NFP and daily windows exist.

### 10 · Display
Status panel (trend, HTF, ADX, session, news, today's trades/losses, position) and shading of blocked bars: grey = outside session, orange = news. A shaded bar means a signal on that bar would be blocked.

### 11 · Indicator only (`OD_GoldSignals.pine`)
| Input | Default | What it does |
|---|---|---|
| Account balance for lot size | 1000 | Printed size on each label (oz and MT5 lots, rounded down to 0.01). |
| Round-trip cost per oz | 0.30 | Decides whether a finished trade counts as a loss. Keep it at 2 × the strategy's commission. |
| Labels / lines / exit markers | on | Exit markers show the reason (TP, SL, BE, TS = trailing, EOD, News) and the result in R. |
| Send alert() with the full message | on | See *Alerts* below. |

**Alerts (indicator):**
- `OD Gold BUY`, `OD Gold SELL`, `OD Gold BUY or SELL` are `alertcondition()`s. Their messages include Entry/SL/TP through `{{plot("Alert SL")}}`-style placeholders.
- Choosing **"Any alert() function call"** gives one alert for both directions, with the full label text (Entry, SL, TP1, TP, size). This uses the fewest alert slots on the free plan.
- Every alert fires only on a **closed** bar, so it never fires early or for a signal that later disappears.

---

## 4. No-repainting design
- All conditions are read on **confirmed** bars. Orders and alerts happen at the bar close, and fills happen at the next open (`process_orders_on_close = false`).
- **HTF trend:** `request.security(..., lookahead = barmerge.lookahead_off)` never returns future data. On a realtime bar, though, it returns the HTF bar that is still forming, while history shows the previous closed value. That mismatch is a form of repaint. The script therefore **latches the HTF value only on the chart bar that closes together with the HTF bar** (`time_close == time_close(htfTF)`) and holds it until the next HTF close. History and realtime see exactly the same value. It is also exactly what an EA reads with `iClose/iMA(PERIOD_H1, shift 1)` at the open of the next M15 bar.
  (TradingView's documented alternative is `expr[1]` with `lookahead_on`. It is also safe, but you asked for lookahead off.)
- Breakeven and trailing use only closed-bar highs, lows and closes.

---

## 5. Testing plan

### 5.1 Before you start
- Check the **date range** at the top of the Strategy Tester. The free plan loads a limited number of bars, so a 15m backtest may cover only a few months. Write the range down, because it limits everything below.
- The 1H EMA 200 needs about 200 hours (≈ 9 trading days) before the HTF filter can produce trades.
- With **partial close on**, TradingView can list each closed slice as its own trade. Compare *net profit, profit factor and drawdown*, not trade count or win rate, when partial is on.

### 5.2 What to record for every run
| Run | Changed vs previous | Period | Net profit | Profit factor | Max DD ($ / %) | Win % | # trades | Avg trade | Avg win / avg loss | Notes |
|---|---|---|---|---|---|---|---|---|---|---|

Paste this table back to me filled in, and I'll analyse it. Screenshots of *Performance Summary* and *List of Trades* help too.

### 5.3 Run matrix (do this on the **in-sample** period only)
**Sanity checks first:**
| Run | Settings |
|---|---|
| R0 | Preset = **Baseline v1** |
| R1 | Preset = Improved, with **every** toggle off: caps, trailing, session, HTF, news off; max trades = 0, max losses = 0 (BE, partial, ADX, EMA-distance and flatten are off by default). **Must equal R0.** If it doesn't, tell me. |

**Add one feature at a time on top of R1** (turn it off again before the next run):
| Run | Feature |
|---|---|
| R2 | Session filter (London + NY) |
| R3 | ADX ≥ 20 (also try 15 and 25) |
| R4 | EMA distance 0.5 ATR (also 0.3 and 1.0) |
| R5 | HTF 1H EMA 200 (also 4H EMA 50) |
| R6 | News: NFP only, then NFP + daily window |
| R7 | Stop caps (min 1, max 5 ATR, skip) |
| R8 | ATR stop 1.5 / 2.0 / 2.5 instead of Supertrend |
| R9 | Breakeven at 1R |
| R10 | Partial 50% at 1R |
| R11 | Trailing 2.5 ATR from 1R, keep TP |
| R12 | Trailing 2.5 ATR, **no TP** |
| R13 | Daily limits 3 trades / 2 losses |
| R14 | Flatten 03:30 GMT+7 |

**Then combine:**
| Run | Settings |
|---|---|
| R15 | Preset Improved, all defaults |
| R16 | Only the features that helped in R2–R14 |
| R17 | Leave-one-out from R16: switch each kept feature off once. If removing it doesn't hurt, drop it (fewer rules = less overfit). |

**When to keep a feature:** it raises profit factor and/or cuts max drawdown on IS, it doesn't cut trades by more than ~50%, **and** its neighbouring values give the same direction of effect (for example, ADX 15, 20 and 25 all help). If only one exact value works, that's curve-fitting. Drop it.

### 5.4 In-sample vs out-of-sample
1. Split the loaded history by date: **first ~60–70% = in-sample (IS)**, **last ~30–40% = out-of-sample (OOS)**. Set the split with *Start/End* in group 1.
2. Do **all** of §5.3 on IS only. Don't look at OOS while choosing.
3. Freeze the settings, then run OOS **once**.
4. Pass criteria (rules of thumb): OOS profit factor ≥ ~1.2 after costs, positive average trade, OOS max drawdown ≤ ~1.5× the IS drawdown (scaled for length), and at least ~30 OOS trades. Fewer than that is inconclusive, not a pass.
5. If OOS fails, don't re-tune on it, because then it becomes in-sample. Go back to IS with simpler settings, or wait for new data.
6. Repeat on a later period as new data arrives (walk-forward). After porting, the MT5 tester gives you years of 15m history for a proper walk-forward.

### 5.5 Robustness checks (on the final settings)
- **Costs:** commission 0.25/side (≈ $0.50/oz round trip). The edge must survive.
- **Parameters:** Supertrend factor 2.5 / 3.5, R:R 1.5 / 2.5. Results should degrade gently, not collapse.
- **Direction:** longs only vs shorts only. A big imbalance can simply reflect gold's trend in that period.
- **Feed:** another broker's XAUUSD on TradingView. Same rules, roughly similar results.
- **Indicator vs strategy:** labels in `OD_GoldSignals` should sit on the same bars as the strategy's entries. Small differences come from §7.

---

## 5.6 Research results (MT5 broker data, Jul 2022 – Oct 2026)

`research/od_backtest.py` is a Python copy of the Pine logic, with the same rules and the same TradingView fill model. It was run on 100,356 M15 bars exported from MT5. The broker's server clock is New York time + 7h, and the script converts it to GMT+7. On Jul–Oct 2026 it reproduces 7 of the 11 trades in the TradingView test on the same dates and with the same outcomes. The rest differ because broker prices are not identical to OANDA's. The data files are **not** in the repo.

Split: **in-sample (IS) Jul 2022 – Dec 2024** for all choices, then **out-of-sample (OOS) Jan 2025 – Oct 2026**, run once. Risk 1%, cost $0.30/oz round trip.

| Configuration | IS | OOS | OOS, cost ×1.7 |
|---|---|---|---|
| v1 baseline | PF 0.76, −57%, 471 trades | PF 1.08, +18% | PF 1.06 |
| v2 first defaults (fixed 2R target, BE, ADX) | PF 0.92, −6% | PF 1.40, +15%, 72 trades | PF 1.38 |
| **v2 new defaults: trailing 3×ATR from 1R, no fixed target, no BE, no ADX** | **PF 1.21, +37%, 280 trades** | **PF 1.39, +37%, 150 trades** | **PF 1.37** |
| same, longs only | PF 1.64, +64% | PF 1.41, +24% | PF 1.39 |

What the data says:
- **v1 has no edge** on 15m gold over these 4 years. The Jul–Oct 2026 TradingView result was a good stretch.
- **The exit matters most.** A trailing stop with no fixed target beat the fixed 2R target in almost every setting tested: trail multiples 2.0–3.5, Supertrend factors 2.5–3.5, ADX on or off. Gold trends hard, and a 2R cap cuts off the big winners (top 3% of trades ≥ 4R, best 7.8R).
- **HTF trend agreement** is the most useful filter. ADX, EMA distance, breakeven and partial close did not help.
- **Shorts** lost money in-sample, during a strong bull market (gold +45% IS, +58% OOS). Longs-only looks best on paper, but it lost in the 2026 pullback, while both directions stayed positive. The default keeps both directions, so the system doesn't depend on gold only rising.
- Trades last a median of 11 hours, and 10% last over 60 hours. Weekend holds were the best trades on average, so flattening at end of day hurt. Overnight swap is **not** modelled.
- **What to expect** (new defaults, 1% risk, Monte Carlo of the trade order): typical worst drawdown ~16%, bad case ~25%, losing streaks of 9 to 13 trades. About 7–9 trades a month, ~46% winners. Starting live at **0.5% risk** roughly halves those drawdowns.
- Losing year in the sample: 2024 (PF 0.95). Profitable years: 2022 (part year), 2023, 2025, 2026 to date.

**MT5 Strategy Tester confirmation** (EA `OD_GoldV2_EA`, MetaQuotes-Demo XAUUSD M15, 1-minute OHLC, 2022-07-01 → 2026-10-04, $10,000, 1% risk):
433 trades (Python: 430) · **net +$9,679 (+97%)** · **profit factor 1.34** · win rate 46.7% · max drawdown 11.7% balance / 13.5% equity · longest losing streak 9 trades (−$1,120) · largest loss −$203 (≈1%). Note the flat stretch from Dec 2023 to Sep 2025 (~21 months without a new high).

Reproduce: `python3 research/od_backtest.py <MT5 M15 export.csv>` (needs pandas + numpy).

---

## 6. MQL5 porting notes (OD_Signal EA)

**Engine:** in `OnTick()`, detect a new M15 bar (`iTime(_Symbol, PERIOD_M15, 0)` changed). Evaluate everything on **shift 1**, the bar that just closed, and act immediately. That is exactly Pine's "decide on bar close, fill at next open". Never use shift 0 for signals.

| Rule | Pine | MQL5 |
|---|---|---|
| Trend EMA | `ta.ema(close, 200)` | `iMA(_Symbol, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE)`, buffer shift 1. Load ≥ 1,000 bars so the EMA warm-up converges. |
| ATR | `ta.atr()` = **Wilder RMA** of true range | **Don't use `iATR`**, which is an SMA of TR and gives different values. Compute `atr = (atr_prev*(n-1) + TR)/n`, seeded with the SMA of the first n TRs. |
| Supertrend | `ta.supertrend(3, 10)` | No built-in. Port it with the Wilder ATR above, using the algorithm below. |
| Trigger | `ta.change(dir) < 0` (buy) / `> 0` (sell) | `dir[1] != dir[2]`: buy when `dir[1] == -1`, sell when `dir[1] == +1`. |
| ADX | `ta.dmi(14, 14)` (Wilder) | **`iADXWilder(_Symbol, PERIOD_M15, 14)`**, main line, shift 1. Not `iADX`, which uses different smoothing. |
| EMA distance | `abs(close − ema) ≥ k × atr` | Same, with shift-1 values. |
| HTF trend | latched lookahead-off value | At the new M15 bar: `iClose(_Symbol, PERIOD_H1, 1)` vs `iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE)` shift 1. These are the same values Pine uses. |
| Sessions / news / flatten | window check on `time_close` in GMT+7 | Check the **new bar's open time**. MT5 bar times are **server time**: `t_gmt7 = t_server − serverOffset×3600 + 7×3600`. ⚠ In the MT5 Strategy Tester `TimeGMT()` equals server time, so make `serverOffset` an input (most brokers: +2 winter / +3 summer, switching with US DST). |
| NFP rule | Friday and day-of-month ≤ 7 (GMT+7) | `TimeToStruct(t_gmt7)`: `day_of_week == 5 && day <= 7`. |
| One-off events | 4 × `input.time` ± minutes | `input datetime` (or a CSV string of times). The MQL5 economic calendar doesn't work in the tester, so keep manual times for backtests. |
| Daily reset | `timeframe.change("D")` | `iTime(_Symbol, PERIOD_D1, 0)` changed. On NY-aligned servers this is the same 17:00 NY boundary. |
| Max trades/day | counter at entry | Keep a counter (reset on the new D1 bar), or count `DEAL_ENTRY_IN` deals with your magic since the D1 open via `HistorySelect`. |
| Losses/day | net P/L of the whole trade < 0 | When a position closes (`OnTradeTransaction`), sum `DEAL_PROFIT + DEAL_COMMISSION + DEAL_SWAP` over all deals with that `POSITION_ID`. If < 0, it's a loss. |
| Stop | Supertrend[1] or close[1] ∓ k×ATR[1], then caps | Same, then `NormalizeDouble` to tick size and respect `SYMBOL_TRADE_STOPS_LEVEL`. |
| Target | `entryRef ± dist × RR`, entryRef = close[1] | For exact parity use `close[1]`. The actual fill (Ask/Bid) is slightly more realistic. The difference is ≈ the spread. |
| Size | `equity × risk% ÷ dist` (oz) | `lots = riskMoney / (dist / SYMBOL_TRADE_TICK_SIZE × SYMBOL_TRADE_TICK_VALUE)`, floor to `SYMBOL_VOLUME_STEP`, clamp to min/max. Below the minimum lot = skip (Pine: *Quantity step = 1*). |
| One position | `tradeOn` lock | Check positions with your magic/symbol, and set a flag when the order is sent. |
| Breakeven | best high/low since entry ≥ entry ± beR×R, checked on bar close | At the new bar, read the max high / min low of the closed bars since entry. Then `PositionModify(SL = entry ± offset)`. Checking every tick would trigger earlier and break parity. |
| Partial close | two `strategy.exit`s: TP1 (qty %) and runner | An MT5 position has only one TP. On a **hedging** account, open **two positions** (part% with TP = TP1, the rest with the final TP) with the same SL, and move both SLs together. That is an exact match. On **netting**, use `PositionClosePartial` when Bid/Ask crosses TP1. |
| Trailing | on bar close: `max(stop, close − k×ATR)` | At the new bar: `newSL = close[1] − k×ATR[1]`. Modify if it's better. If `newSL` is already beyond the current price, close at market. The broker rejects that SL, and Pine would fill at the open. |
| Forced exit (EOD/News) | `strategy.close_all` → next open | `PositionClose` at the new bar when its open time is inside the window. |
| Costs | commission 0.15/side models the spread | The MT5 tester uses the real spread, plus broker commission if any. Use "Every tick based on real ticks". |

**Supertrend (port of Pine's `ta.supertrend`), per closed bar i:**
```
src   = (high + low) / 2
up    = src - factor * atr          // lower band
dn    = src + factor * atr          // upper band
up    = (up > up_prev  || close_prev < up_prev) ? up : up_prev
dn    = (dn < dn_prev  || close_prev > dn_prev) ? dn : dn_prev
if (atr_prev is not ready)           dir = +1
else if (st_prev == dn_prev)         dir = (close > dn) ? -1 : +1
else                                 dir = (close < up) ? +1 : -1
st    = (dir == -1) ? up : dn       // dir -1 = up-trend (line below price)
```

---

## 6b. MT5 Expert Advisor: `mql5/OD_GoldV2_EA.mq5`

`OD_GoldV2_EA.mq5` ports the Pine strategy to MT5, with the same inputs, the same defaults and the same bar-close timing. It follows every porting note in §6:
- Wilder ATR and Supertrend are computed in the EA itself (MT5's `iATR` uses a different average).
- ADX uses `iADXWilder`. The HTF trend uses the last closed H1 bar.
- Broker server time is converted to GMT+7 automatically on NY-aligned servers, which are GMT+2 in winter and GMT+3 in summer.
- Daily limits are rebuilt from the deal history, so they survive an EA restart.
- The partial close uses two positions, which needs a hedging account.
- It sends **free push notifications** to the MT5 phone app.

**Install (demo account first):**
1. MT5 → *File → Open Data Folder* → `MQL5\Experts` → copy `OD_GoldV2_EA.mq5` there.
2. MT5 → *Tools → MetaQuotes Language Editor* (F4) → open `OD_GoldV2_EA.mq5` → **Compile** (F7). It must show *0 errors*. Send a screenshot of any errors.
3. In MT5's Navigator (Ctrl+N) → *Expert Advisors* → right-click → *Refresh*. Drag **OD_GoldV2_EA** onto an **XAUUSD M15** chart.
4. In the EA window, tick **Allow Algo Trading**, then click the **Algo Trading** button on the toolbar so it turns green.
5. Push alerts: install the MetaTrader 5 app on your phone. In the app, *Settings → Messages* shows your **MetaQuotes ID**. On the PC, go to *Tools → Options → Notifications*, tick *Enable Push Notifications*, enter the ID, and click *Test*.
6. Account size: with 1% risk, typical 2026 stops (~$31/oz) need about **$3,000+** to reach MT5's 0.01-lot minimum. On a demo you can choose the balance. Set the demo to **$10,000** so the 1% sizing works. If a trade would need less than the minimum lot, the EA skips it and tells you, unless you turn off *Skip trade if size < minimum lot*.

**Strategy Tester (MT5, free, years of data):** press *Ctrl+R*, then choose:
- Expert: OD_GoldV2_EA
- Symbol: XAUUSD
- Period: M15
- Modelling: **Every tick based on real ticks**
- Dates: 2022.07.01 to today
- Deposit: 10,000

Compare its report with §5.6. Expect small differences from the Python/TradingView results, because the tester uses real ticks and real spread.

## 7. Known differences (TradingView ↔ MT5 ↔ indicator)
- **Price feeds:** OANDA's TradingView prices and your MT5 broker's prices differ slightly. Levels won't match to the cent, and a borderline bar can flip.
- **Intrabar order:** without Bar Magnifier, TradingView assumes price goes open → nearest extreme → other extreme. MT5 "real ticks" knows the true path. When the stop and target are both inside one bar, the results can differ.
- **Indicator emulator:** the indicator replays trades with the same assumption, so it matches the strategy. It sizes with the static *Account balance* input instead of live equity, which only matters when *Quantity step* > 0.
- **Swap:** neither Pine file models overnight swap. Use the flatten window if you want to avoid it.
