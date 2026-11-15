-- Lump sum vs monthly DCA on the S&P 500: SQL queries (PostgreSQL)
-- Source: Yahoo Finance, ^GSPC, daily data 1996-11-18 to 2026-11-09, loaded in a table called sp500
-- (columns: date, open, high, low, close). Only the close is used.
-- Scenarios: lump sum $12,000 vs $100 a month for 120 months.
--   1 = start 2007-01-03 (before the crisis), valuation 2017-01-03
--   2 = start 2008-10-01 (during the crisis), valuation 2018-10-01
--   3 = start 2010-01-04 (after the crisis),  valuation 2020-01-02

-- =========================================================
-- 1. Data quality checks
-- =========================================================
SELECT COUNT(*) AS n_rows, MIN(date) AS first_date, MAX(date) AS last_date FROM sp500;
SELECT date, COUNT(*) FROM sp500 GROUP BY date HAVING COUNT(*) > 1;          -- duplicates
SELECT * FROM sp500 WHERE close IS NULL OR close = 0;                          -- nulls / zeros
SELECT * FROM sp500 WHERE high < low;                                          -- high below low
SELECT * FROM sp500 WHERE close < low OR close > high;                         -- close outside range (2025-09-25)
-- rows of days when the market was closed (open = high = low = close)
SELECT * FROM sp500 WHERE open = high AND high = low AND low = close ORDER BY date;

-- =========================================================
-- 2. Clean table: the raw table stays untouched
--    9 rows of closed-market days removed (2012-11-30 and 2012-12-31 were open and are kept)
-- =========================================================
CREATE TABLE sp500_clean AS
SELECT *
FROM sp500
WHERE date NOT IN (
  '2001-09-11', '2012-07-04', '2012-09-03', '2012-10-29', '2012-10-30',
  '2012-11-22', '2012-12-25', '2013-01-01', '2013-01-21'
);
-- check: 7,528 rows
SELECT COUNT(*) FROM sp500_clean;

-- =========================================================
-- 3. Peak and low of the 2008 crisis (closes)
-- =========================================================
SELECT date, close FROM sp500_clean WHERE date BETWEEN '2006-01-01' AND '2008-12-31' ORDER BY close DESC LIMIT 1;  -- peak 2007-10-09, 1,565.15
SELECT date, close FROM sp500_clean WHERE date BETWEEN '2008-01-01' AND '2010-12-31' ORDER BY close ASC LIMIT 1;   -- low 2009-03-09, 676.53

-- =========================================================
-- 4. Purchase dates and prices (scenario 1)
--    first trading day of each month; purchases are before the valuation month: 120 rows
--    scenario 2: '2008-10-01' to '2018-09-30'; scenario 3: '2010-01-04' to '2019-12-31'
-- =========================================================
WITH first_days AS (
  SELECT MIN(date) AS first_date
  FROM sp500_clean
  WHERE date BETWEEN '2007-01-03' AND '2016-12-31'
  GROUP BY TO_CHAR(date, 'YYYY-MM')
)
SELECT fd.first_date, sc.close
FROM first_days AS fd
JOIN sp500_clean AS sc ON sc.date = fd.first_date
ORDER BY fd.first_date;

-- =========================================================
-- 5. Lump sum: units, final value, total return, ROI (scenario 1)
--    the units use the close of the PURCHASE date; the final value uses the close of the valuation date
-- =========================================================
WITH purchase AS (
  SELECT 12000.0 / close AS units FROM sp500_clean WHERE date = '2007-01-03'
),
valuation AS (
  SELECT close FROM sp500_clean WHERE date = '2017-01-03'
)
SELECT
  ROUND(p.units::numeric, 4) AS units,
  ROUND((p.units * v.close)::numeric, 2) AS final_value,
  ROUND((p.units * v.close - 12000)::numeric, 2) AS total_return,
  ROUND(((p.units * v.close - 12000) / 12000 * 100)::numeric, 2) AS roi_pct
FROM purchase AS p
CROSS JOIN valuation AS v;

-- =========================================================
-- 6. DCA: total units, final value, total return, ROI (scenario 1)
--    no rounding before the end
-- =========================================================
WITH first_days AS (
  SELECT MIN(date) AS first_date
  FROM sp500_clean
  WHERE date BETWEEN '2007-01-03' AND '2016-12-31'
  GROUP BY TO_CHAR(date, 'YYYY-MM')
),
total AS (
  SELECT SUM(100.0 / sc.close) AS units
  FROM first_days AS fd
  JOIN sp500_clean AS sc ON sc.date = fd.first_date
),
valuation AS (
  SELECT close FROM sp500_clean WHERE date = '2017-01-03'
)
SELECT
  ROUND(t.units::numeric, 4) AS total_units,
  ROUND((t.units * v.close)::numeric, 2) AS final_value,
  ROUND((t.units * v.close - 12000)::numeric, 2) AS total_return,
  ROUND(((t.units * v.close - 12000) / 12000 * 100)::numeric, 2) AS roi_pct
FROM total AS t
CROSS JOIN valuation AS v;

-- =========================================================
-- 7. Lump sum: maximum drawdown (scenario 1)
--    drawdown = value / running peak - 1; for the lump sum it only depends on prices
-- =========================================================
WITH lump_sum_purchase AS (
  SELECT 12000.0 / close AS units
  FROM sp500_clean
  WHERE date = '2007-01-03'
),
daily_values AS (
  SELECT sc.date, lp.units * sc.close AS portfolio_value
  FROM sp500_clean AS sc
  CROSS JOIN lump_sum_purchase AS lp
  WHERE sc.date BETWEEN '2007-01-03' AND '2017-01-03'
),
running_peaks AS (
  SELECT date, portfolio_value,
         MAX(portfolio_value) OVER (ORDER BY date) AS peak_value
  FROM daily_values
),
daily_drawdown AS (
  SELECT date, portfolio_value / peak_value - 1 AS drawdown
  FROM running_peaks
)
SELECT date AS max_drawdown_date, ROUND(drawdown::numeric * 100, 2) AS max_drawdown_pct
FROM daily_drawdown
ORDER BY drawdown
LIMIT 1;

-- =========================================================
-- 8. Daily views for both strategies (value and drawdown), one per scenario
--    used for the charts; the minimum of each drawdown column gives the maximum drawdown:
--    SELECT * FROM scenario_1_daily ORDER BY dca_drawdown_pct LIMIT 1;
-- =========================================================
CREATE VIEW scenario_1_daily AS
WITH all_days AS (
  SELECT date, close
  FROM sp500_clean
  WHERE date BETWEEN '2007-01-03' AND '2017-01-03'
),
buy_days AS (
  SELECT MIN(date) AS first_date
  FROM all_days
  WHERE date BETWEEN '2007-01-03' AND '2016-12-31'
  GROUP BY TO_CHAR(date, 'YYYY-MM')
),
lump_sum_purchase AS (
  SELECT 12000.0 / close AS units
  FROM all_days
  WHERE date = '2007-01-03'
),
dca_holdings AS (
  SELECT
    ad.date,
    ad.close,
    SUM(CASE WHEN bd.first_date IS NOT NULL THEN 100.0 / ad.close ELSE 0 END)
      OVER (ORDER BY ad.date) AS dca_units,
    SUM(CASE WHEN bd.first_date IS NOT NULL THEN 100 ELSE 0 END)
      OVER (ORDER BY ad.date) AS dca_invested
  FROM all_days AS ad
  LEFT JOIN buy_days AS bd ON ad.date = bd.first_date
),
daily_values AS (
  SELECT
    dh.date,
    dh.close,
    dh.dca_invested,
    ls.units * dh.close AS lump_sum_value,
    dh.dca_units * dh.close AS dca_value
  FROM dca_holdings AS dh
  CROSS JOIN lump_sum_purchase AS ls
),
running_peaks AS (
  SELECT
    *,
    MAX(lump_sum_value) OVER (ORDER BY date) AS lump_sum_peak,
    MAX(dca_value) OVER (ORDER BY date) AS dca_peak
  FROM daily_values
)
SELECT
  date,
  close,
  dca_invested,
  ROUND(lump_sum_value::numeric, 2) AS lump_sum_value,
  ROUND(dca_value::numeric, 2) AS dca_value,
  ROUND((lump_sum_value / lump_sum_peak - 1)::numeric * 100, 4) AS lump_sum_drawdown_pct,
  ROUND((dca_value / dca_peak - 1)::numeric * 100, 4) AS dca_drawdown_pct
FROM running_peaks
ORDER BY date;

CREATE VIEW scenario_2_daily AS
WITH all_days AS (
  SELECT date, close
  FROM sp500_clean
  WHERE date BETWEEN '2008-10-01' AND '2018-10-01'
),
buy_days AS (
  SELECT MIN(date) AS first_date
  FROM all_days
  WHERE date BETWEEN '2008-10-01' AND '2018-09-30'
  GROUP BY TO_CHAR(date, 'YYYY-MM')
),
lump_sum_purchase AS (
  SELECT 12000.0 / close AS units
  FROM all_days
  WHERE date = '2008-10-01'
),
dca_holdings AS (
  SELECT
    ad.date,
    ad.close,
    SUM(CASE WHEN bd.first_date IS NOT NULL THEN 100.0 / ad.close ELSE 0 END)
      OVER (ORDER BY ad.date) AS dca_units,
    SUM(CASE WHEN bd.first_date IS NOT NULL THEN 100 ELSE 0 END)
      OVER (ORDER BY ad.date) AS dca_invested
  FROM all_days AS ad
  LEFT JOIN buy_days AS bd ON ad.date = bd.first_date
),
daily_values AS (
  SELECT
    dh.date,
    dh.close,
    dh.dca_invested,
    ls.units * dh.close AS lump_sum_value,
    dh.dca_units * dh.close AS dca_value
  FROM dca_holdings AS dh
  CROSS JOIN lump_sum_purchase AS ls
),
running_peaks AS (
  SELECT
    *,
    MAX(lump_sum_value) OVER (ORDER BY date) AS lump_sum_peak,
    MAX(dca_value) OVER (ORDER BY date) AS dca_peak
  FROM daily_values
)
SELECT
  date,
  close,
  dca_invested,
  ROUND(lump_sum_value::numeric, 2) AS lump_sum_value,
  ROUND(dca_value::numeric, 2) AS dca_value,
  ROUND((lump_sum_value / lump_sum_peak - 1)::numeric * 100, 4) AS lump_sum_drawdown_pct,
  ROUND((dca_value / dca_peak - 1)::numeric * 100, 4) AS dca_drawdown_pct
FROM running_peaks
ORDER BY date;

CREATE VIEW scenario_3_daily AS
WITH all_days AS (
  SELECT date, close
  FROM sp500_clean
  WHERE date BETWEEN '2010-01-04' AND '2020-01-02'
),
buy_days AS (
  SELECT MIN(date) AS first_date
  FROM all_days
  WHERE date BETWEEN '2010-01-04' AND '2019-12-31'
  GROUP BY TO_CHAR(date, 'YYYY-MM')
),
lump_sum_purchase AS (
  SELECT 12000.0 / close AS units
  FROM all_days
  WHERE date = '2010-01-04'
),
dca_holdings AS (
  SELECT
    ad.date,
    ad.close,
    SUM(CASE WHEN bd.first_date IS NOT NULL THEN 100.0 / ad.close ELSE 0 END)
      OVER (ORDER BY ad.date) AS dca_units,
    SUM(CASE WHEN bd.first_date IS NOT NULL THEN 100 ELSE 0 END)
      OVER (ORDER BY ad.date) AS dca_invested
  FROM all_days AS ad
  LEFT JOIN buy_days AS bd ON ad.date = bd.first_date
),
daily_values AS (
  SELECT
    dh.date,
    dh.close,
    dh.dca_invested,
    ls.units * dh.close AS lump_sum_value,
    dh.dca_units * dh.close AS dca_value
  FROM dca_holdings AS dh
  CROSS JOIN lump_sum_purchase AS ls
),
running_peaks AS (
  SELECT
    *,
    MAX(lump_sum_value) OVER (ORDER BY date) AS lump_sum_peak,
    MAX(dca_value) OVER (ORDER BY date) AS dca_peak
  FROM daily_values
)
SELECT
  date,
  close,
  dca_invested,
  ROUND(lump_sum_value::numeric, 2) AS lump_sum_value,
  ROUND(dca_value::numeric, 2) AS dca_value,
  ROUND((lump_sum_value / lump_sum_peak - 1)::numeric * 100, 4) AS lump_sum_drawdown_pct,
  ROUND((dca_value / dca_peak - 1)::numeric * 100, 4) AS dca_drawdown_pct
FROM running_peaks
ORDER BY date;
