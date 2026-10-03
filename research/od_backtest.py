"""
OD Gold v2 — Python replica of OD_GoldStrategy.pine / OD_GoldSignals.pine for multi-year research.

Same rules, same inputs, same fill model as TradingView's broker emulator (no bar magnifier):
  • decisions on the closed bar, market entry at the next bar's open
  • stop / targets: orders already crossed at the open fill at the open, then price travels
    open → nearest extreme → other extreme
  • breakeven / trailing recalculated on the bar close, active from the next bar
  • commission per oz per side (default 0.15 → $0.30 round trip)

Data: MT5 "Export Bars" CSV (tab separated, <DATE> <TIME> <OPEN> ...). Bar times are broker
server time; SERVER_MINUS_NY_HOURS converts them (NY-close-aligned servers = NY + 7 h).
"""
import math
import sys
from dataclasses import dataclass, field, replace

import numpy as np
import pandas as pd

SERVER_MINUS_NY_HOURS = 7          # server 00:00 = 17:00 New York (GMT+2 winter / GMT+3 summer)


# ───────────────────────────────────────────────────────────────────── data
def load_mt5(path):
    df = pd.read_csv(path, sep="\t")
    df.columns = [c.strip("<>").lower() for c in df.columns]
    srv = pd.to_datetime(df["date"] + " " + df["time"], format="%Y.%m.%d %H:%M:%S")
    ny = srv - pd.Timedelta(hours=SERVER_MINUS_NY_HOURS)
    loc = ny.dt.tz_localize("America/New_York", ambiguous="NaT", nonexistent="NaT")
    off = (loc.dt.tz_convert("UTC").dt.tz_localize(None) - ny).ffill().bfill()
    out = pd.DataFrame({
        "t": ny + off,                                   # bar open, UTC (naive)
        "day": srv.dt.normalize(),                       # trading day = server date (17:00 NY reset)
        "open": df["open"].astype(float), "high": df["high"].astype(float),
        "low": df["low"].astype(float), "close": df["close"].astype(float),
    })
    return out.reset_index(drop=True)


# ─────────────────────────────────────────────────────────────── indicators
def sma_seeded(x, n, alpha):
    """Pine-style recursive MA seeded with the SMA of the first n values."""
    out = np.full(len(x), np.nan)
    if len(x) < n:
        return out
    out[n - 1] = np.mean(x[:n])
    for i in range(n, len(x)):
        out[i] = alpha * x[i] + (1 - alpha) * out[i - 1]
    return out


def ema(x, n):
    return sma_seeded(x, n, 2.0 / (n + 1))


def rma(x, n):
    # skip leading NaNs
    x = np.asarray(x, float)
    first = int(np.argmax(~np.isnan(x)))
    out = np.full(len(x), np.nan)
    out[first:] = sma_seeded(np.nan_to_num(x[first:]), n, 1.0 / n)
    return out


def true_range(h, l, c, first_hl=True):
    pc = np.roll(c, 1)
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    tr[0] = h[0] - l[0] if first_hl else np.nan
    return tr


def supertrend(h, l, c, factor, period):
    atr = rma(true_range(h, l, c), period)
    src = (h + l) / 2
    n = len(c)
    st = np.full(n, np.nan)
    d = np.zeros(n)
    up_prev = dn_prev = 0.0
    st_prev = np.nan
    for i in range(n):
        up = src[i] - factor * atr[i]
        dn = src[i] + factor * atr[i]
        if i > 0:
            up = up if (up > up_prev or c[i - 1] < up_prev) else up_prev
            dn = dn if (dn < dn_prev or c[i - 1] > dn_prev) else dn_prev
        if i == 0 or np.isnan(atr[i - 1]):
            di = 1
        elif st_prev == dn_prev:
            di = -1 if c[i] > dn else 1
        else:
            di = 1 if c[i] < up else -1
        st[i] = up if di == -1 else dn
        d[i] = di
        up_prev = up if not np.isnan(up) else 0.0
        dn_prev = dn if not np.isnan(dn) else 0.0
        st_prev = st[i]
    return st, d


def adx_wilder(h, l, c, n):
    up = np.diff(h, prepend=np.nan)
    dn = -np.diff(l, prepend=np.nan)
    pdm = np.where((up > dn) & (up > 0), up, 0.0); pdm[0] = np.nan
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0); mdm[0] = np.nan
    tr = rma(true_range(h, l, c, first_hl=False), n)
    with np.errstate(invalid="ignore", divide="ignore"):
        plus = pd.Series(100 * rma(pdm, n) / tr).ffill().to_numpy()
        minus = pd.Series(100 * rma(mdm, n) / tr).ffill().to_numpy()
        s = plus + minus
        dx = np.abs(plus - minus) / np.where(s == 0, 1, s)
    return 100 * rma(dx, n)


# ───────────────────────────────────────────────────────────────── settings
@dataclass
class P:
    preset: str = "Improved"         # or "Baseline v1"
    stLen: int = 10
    stFac: float = 3.0
    emaLen: int = 200
    useLong: bool = True
    useShort: bool = True
    slMode: str = "Supertrend"       # or "ATR"
    atrLen: int = 14
    slAtrMult: float = 2.0
    useCaps: bool = True
    capUnit: str = "ATR"
    minSL: float = 1.0
    maxSL: float = 5.0
    maxAct: str = "Skip trade"       # or "Clamp to max"
    rr: float = 2.0
    riskPct: float = 1.0
    useBE: bool = False
    beR: float = 1.0
    beOff: float = 0.30
    usePart: bool = False
    partPct: float = 50.0
    partR: float = 1.0
    useTrail: bool = True
    trailMult: float = 3.0
    trailStart: float = 1.0
    trailNoTP: bool = True
    useSess: bool = True
    useLon: bool = True
    lon: tuple = (14 * 60, 18 * 60)
    useNY: bool = True
    ny: tuple = (19 * 60 + 30, 23 * 60 + 30)
    useEod: bool = False
    eod: tuple = (3 * 60 + 30, 5 * 60)
    useAdx: bool = False
    adxMin: float = 20.0
    adxLen: int = 14
    useDist: bool = False
    distAtr: float = 0.5
    useHtf: bool = True
    htfMin: int = 60
    htfLen: int = 200
    maxTrades: int = 3
    maxLosses: int = 2
    useNews: bool = True
    newsFlat: bool = False
    useNfp: bool = True
    nfp: tuple = (19 * 60, 21 * 60 + 30)
    useDaily: bool = False
    dly: tuple = (19 * 60 + 15, 20 * 60 + 45)
    tzHours: int = 7
    commission: float = 0.15         # $ per oz per side
    capital: float = 1000.0
    start: str = "1900-01-01"
    end: str = "2100-01-01"


ALL_OFF = dict(useCaps=False, useBE=False, usePart=False, useTrail=False, useSess=False, useEod=False,
               useAdx=False, useDist=False, useHtf=False, maxTrades=0, maxLosses=0, useNews=False,
               slMode="Supertrend")


def in_win(m, w):
    a, b = w
    return (m >= a) & (m < b) if a <= b else (m >= a) | (m < b)


# ─────────────────────────────────────────────────────────────── precompute
class Market:
    def __init__(self, df):
        self.df = df
        self.o = df.open.to_numpy(); self.h = df.high.to_numpy()
        self.l = df.low.to_numpy(); self.c = df.close.to_numpy()
        self.t = df.t.to_numpy()
        self.tclose = (df.t + pd.Timedelta(minutes=15))
        self.dayidx = df.day.to_numpy()
        self.newday = np.r_[True, self.dayidx[1:] != self.dayidx[:-1]]
        self.cache = {}

    def get(self, key, fn):
        if key not in self.cache:
            self.cache[key] = fn()
        return self.cache[key]

    def st(self, f, n):
        return self.get(("st", f, n), lambda: supertrend(self.h, self.l, self.c, f, n))

    def ema(self, n):
        return self.get(("ema", n), lambda: ema(self.c, n))

    def atr(self, n):
        return self.get(("atr", n), lambda: rma(true_range(self.h, self.l, self.c), n))

    def adx(self, n):
        return self.get(("adx", n), lambda: adx_wilder(self.h, self.l, self.c, n))

    def htf(self, minutes, n):
        def build():
            g = self.df.set_index("t")["close"].resample(f"{minutes}min", label="left", closed="left").last().dropna()
            hc = g.to_numpy(); he = ema(hc, n)
            hb = pd.DataFrame({"end": g.index + pd.Timedelta(minutes=minutes), "hc": hc, "he": he})
            q = pd.DataFrame({"tc": self.tclose})
            m = pd.merge_asof(q, hb, left_on="tc", right_on="end", direction="backward")  # last CLOSED HTF bar
            return m.hc.to_numpy(), m.he.to_numpy()
        return self.get(("htf", minutes, n), build)

    def local(self, tz):
        def build():
            le = self.tclose + pd.Timedelta(hours=tz)                # entry time in local tz
            return ((le.dt.hour * 60 + le.dt.minute).to_numpy(), le.dt.dayofweek.to_numpy(), le.dt.day.to_numpy())
        return self.get(("loc", tz), build)


# ─────────────────────────────────────────────────────────────── simulation
def sim_bar(lng, fill, stp, stag, t1on, t1, t1frac, tpon, tp, rem, o, h, l):
    """One bar of an open trade, TradingView broker-emulator path. Returns rem, pl/oz, hit1, tag, px."""
    dm = 1.0 if lng else -1.0
    r, p, hit1, tag, px = rem, 0.0, False, "", math.nan
    fav, adv = (h, l) if lng else (l, h)
    fav_first = lng == ((h - o) <= (o - l))
    if (o - stp) * dm <= 0:
        return 0.0, r * (o - fill) * dm, False, stag, o
    if tpon and (o - tp) * dm >= 0:
        return 0.0, r * (o - fill) * dm, False, "TP", o
    if t1on and (o - t1) * dm >= 0:
        p += t1frac * (o - fill) * dm; r -= t1frac; hit1 = True
    stop_hit = (adv - stp) * dm <= 0
    if stop_hit and not fav_first:
        return 0.0, p + r * (stp - fill) * dm, hit1, stag, stp
    if t1on and not hit1 and (fav - t1) * dm >= 0:
        p += t1frac * (t1 - fill) * dm; r -= t1frac; hit1 = True
    if tpon and (fav - tp) * dm >= 0:
        return 0.0, p + r * (tp - fill) * dm, hit1, "TP", tp
    if r > 1e-12 and stop_hit:
        return 0.0, p + r * (stp - fill) * dm, hit1, stag, stp
    return r, p, hit1, "", math.nan


def run(mk: Market, p: P):
    v2 = p.preset == "Improved"
    mAtrSL, mCaps, mBE = v2 and p.slMode == "ATR", v2 and p.useCaps, v2 and p.useBE
    mPart, mTrail = v2 and p.usePart, v2 and p.useTrail
    mNoTP = mTrail and p.trailNoTP
    mSess, mEod, mAdx, mDist = v2 and p.useSess, v2 and p.useEod, v2 and p.useAdx, v2 and p.useDist
    mHtf, mLimits, mNews = v2 and p.useHtf, v2, v2 and p.useNews

    o, h, l, c = mk.o, mk.h, mk.l, mk.c
    st, d = mk.st(p.stFac, p.stLen)
    em = mk.ema(p.emaLen); atr = mk.atr(p.atrLen); adx = mk.adx(p.adxLen)
    hc, he = mk.htf(p.htfMin, p.htfLen)
    mins, dow, dom = mk.local(p.tzHours)
    n = len(c)

    dch = np.r_[np.nan, np.diff(d)]
    stUp, stDn = dch < 0, dch > 0
    inSess = ~np.full(n, mSess) | (p.useLon & in_win(mins, p.lon)) | (p.useNY & in_win(mins, p.ny))
    firstFri = (dow == 4) & (dom <= 7)
    news = (p.useNfp & firstFri & in_win(mins, p.nfp)) | (p.useDaily & (dow <= 4) & in_win(mins, p.dly))
    inNews = news & mNews
    eodNow = in_win(mins, p.eod) & mEod
    with np.errstate(invalid="ignore"):
        adxOk = ~np.full(n, mAdx) | (adx >= p.adxMin)
        distOk = ~np.full(n, mDist) | (np.abs(c - em) >= p.distAtr * atr)
        htfL = ~np.full(n, mHtf) | (hc > he)
        htfS = ~np.full(n, mHtf) | (hc < he)
        longSetup = p.useLong & stUp & (c > em) & htfL & adxOk & distOk
        shortSetup = p.useShort & stDn & (c < em) & htfS & adxOk & distOk
    tt = mk.df.t
    inRange = ((tt >= pd.Timestamp(p.start)) & (tt < pd.Timestamp(p.end))).to_numpy()

    trades = []
    bal = p.capital
    tradesToday = lossesToday = 0
    tradeOn = pending = inPos = isLong = False
    entryRef = fill = riskR = stopPx = tp1 = tp = best = qty = math.nan
    beDone = partOn = partDone = False
    partFrac = rem = pl = 0.0
    stag = "SL"; exitQ = False; qtag = ""; sigI = fillI = -1

    for i in range(n):
        if mk.newday[i]:
            tradesToday = lossesToday = 0
        if pending:
            pending = False; inPos = True; fill = o[i]; rem = 1.0; pl = 0.0; fillI = i
        exitTag = ""; exitPx = math.nan
        if inPos and exitQ:
            pl += rem * ((o[i] - fill) if isLong else (fill - o[i])); rem = 0.0; exitTag = qtag; exitPx = o[i]
        exitQ = False
        if inPos and rem > 0:
            r, dp, hit1, tag, px = sim_bar(isLong, fill, stopPx, stag, partOn and not partDone, tp1, partFrac,
                                          not mNoTP, tp, rem, o[i], h[i], l[i])
            rem = r; pl += dp
            if hit1:
                partDone = True
            if r <= 1e-12:
                exitTag, exitPx = tag, px
        if inPos and rem <= 1e-12:
            net_oz = pl - 2 * p.commission
            usd = qty * net_oz
            bal += usd
            if net_oz < 0:
                lossesToday += 1
            trades.append(dict(sig=mk.df.t[sigI], entry=mk.df.t[fillI], exit=mk.df.t[i], side="L" if isLong else "S",
                               ref=entryRef, fill=fill, sl0=sl0, tp=tp, exitPx=exitPx, tag=exitTag,
                               R=net_oz / riskR, usd=usd, qty=qty, bal=bal, bars=i - fillI + 1))
            inPos = False; tradeOn = False
        if inPos:
            best = (h[i] if math.isnan(best) else max(best, h[i])) if isLong else (l[i] if math.isnan(best) else min(best, l[i]))
            moveR = ((best - entryRef) if isLong else (entryRef - best)) / riskR
            if mBE and not beDone and moveR >= p.beR:
                bep = entryRef + p.beOff if isLong else entryRef - p.beOff
                if (bep > stopPx) if isLong else (bep < stopPx):
                    stopPx = bep; stag = "BE"
                beDone = True
            if mTrail and moveR >= p.trailStart:
                trp = c[i] - p.trailMult * atr[i] if isLong else c[i] + p.trailMult * atr[i]
                if (trp > stopPx) if isLong else (trp < stopPx):
                    stopPx = trp; stag = "TS"
            if eodNow[i] or (inNews[i] and p.newsFlat):
                exitQ = True; qtag = "EOD" if eodNow[i] else "News"
        limitsOk = (not mLimits) or ((p.maxTrades == 0 or tradesToday < p.maxTrades) and
                                     (p.maxLosses == 0 or lossesToday < p.maxLosses))
        if (inRange[i] and not tradeOn and inSess[i] and not inNews[i] and not eodNow[i] and limitsOk
                and (longSetup[i] or shortSetup[i])):
            lng = bool(longSetup[i])
            raw = (c[i] - p.slAtrMult * atr[i] if lng else c[i] + p.slAtrMult * atr[i]) if mAtrSL else st[i]
            dist = c[i] - raw if lng else raw - c[i]
            unit = atr[i] if p.capUnit == "ATR" else 1.0
            ok = dist > 0
            if mCaps and ok:
                if p.minSL > 0 and dist < p.minSL * unit:
                    dist = p.minSL * unit
                if p.maxSL > 0 and dist > p.maxSL * unit:
                    if p.maxAct == "Skip trade":
                        ok = False
                    else:
                        dist = p.maxSL * unit
            if ok:
                isLong = lng; entryRef = c[i]; riskR = dist
                stopPx = sl0 = c[i] - dist if lng else c[i] + dist
                tp = c[i] + dist * p.rr if lng else c[i] - dist * p.rr
                tp1 = c[i] + dist * p.partR if lng else c[i] - dist * p.partR
                partOn = mPart; partFrac = p.partPct / 100 if partOn else 0.0; partDone = False
                beDone = False; best = math.nan; stag = "SL"
                qty = bal * p.riskPct / 100 / dist
                pending = True; tradeOn = True; tradesToday += 1; sigI = i
    return pd.DataFrame(trades)


# ─────────────────────────────────────────────────────────────── metrics
def stats(tr, capital=1000.0, label=""):
    if tr is None or len(tr) == 0:
        return dict(run=label, trades=0)
    eq = np.r_[capital, capital + tr.usd.cumsum().to_numpy()]
    peak = np.maximum.accumulate(eq)
    dd = (peak - eq); ddp = dd / peak
    gp = tr.usd[tr.usd > 0].sum(); gl = -tr.usd[tr.usd < 0].sum()
    losses = (tr.usd < 0).astype(int).to_numpy()
    mcl = cur = 0
    for x in losses:
        cur = cur + 1 if x else 0; mcl = max(mcl, cur)
    months = max((tr.exit.max() - tr.entry.min()).days / 30.44, 1e-9)
    return dict(run=label, trades=len(tr), net=round(eq[-1] - capital, 2), ret_pct=round(100 * (eq[-1] / capital - 1), 1),
                pf=round(gp / gl, 2) if gl > 0 else float("inf"), win_pct=round(100 * (tr.usd > 0).mean(), 1),
                avgR=round(tr.R.mean(), 3), maxdd=round(dd.max(), 2), maxdd_pct=round(100 * ddp.max(), 1),
                max_consec_loss=mcl, trades_per_month=round(len(tr) / months, 1))


if __name__ == "__main__":
    mk = Market(load_mt5(sys.argv[1]))
    for per, kw in [("in-sample", dict(start="2022-07-01", end="2025-01-01")), ("out-of-sample", dict(start="2025-01-01"))]:
        for lab, pp in [("Baseline v1", P(preset="Baseline v1", **kw)), ("v2 defaults", P(**kw))]:
            print(stats(run(mk, pp), label=f"{lab} | {per}"))
