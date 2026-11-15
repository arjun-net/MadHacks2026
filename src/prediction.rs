//! Databricks SQL historical weekday forecast for ordinary (non-anomalous) activity.
//!
//! This is a *baseline estimate*, not a fitted ML model or a prediction of
//! building occupancy. It excludes missing/suppressed days and extreme past
//! values before averaging the remaining historical row counts.

use axum::extract::{Path, Query};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::{DateTime, Datelike, Duration as ChronoDuration, NaiveDate, NaiveTime, TimeZone, Timelike, Utc, Weekday};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::story::{mobile_building_name, param, Config, DbClient, SqlParameter};

const METHOD: &str = "robust_same_weekday_mean";
const METHODOLOGY: &str = "Databricks SQL counts location_events rows near the same campus-local time on completed previous matching weekdays; it does not use device_id. Every row counts even if a device sends repeated reports. Missing days and days below STORY_MIN_OBSERVATIONS are omitted, not counted as zero. With four or more usable days, an IQR rule excludes atypical historical days before estimating the mean and interquartile range. This is a descriptive baseline, not an ML forecast, confidence interval, unique visitor count, or actual occupancy; reliability is heuristic.";

#[derive(Debug, Deserialize, Default)]
pub struct PredictionQuery {
    /// Target local date, YYYY-MM-DD. May be in the past for backtesting.
    pub date: Option<String>,
    /// Next specified weekday, e.g. saturday. If date is also given, must match.
    pub weekday: Option<String>,
    /// Campus local HH:MM. Defaults to current campus local time.
    pub time: Option<String>,
    /// Completed historical matching weekdays to inspect (3..=12, default 8).
    pub weeks: Option<usize>,
    /// Half-width of historical observation window (5..=60 minutes, default 15).
    pub window_minutes: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HistoricalObservation {
    pub date: String,
    pub weekday: String,
    pub observations: Option<i64>,
    /// Legacy alias; contains observation rows rather than distinct device count.
    pub reporting_devices: Option<i64>,
    /// available, suppressed, no_data
    pub status: String,
    pub excluded_as_outlier: bool,
    pub used_for_prediction: bool,
}

#[derive(Debug, Serialize)]
pub struct PredictionEstimate {
    /// available, insufficient_history
    pub status: &'static str,
    pub expected_observations: Option<f64>,
    pub rounded_observations: Option<i64>,
    /// Legacy aliases retained for existing SwiftUI clients.
    pub expected_reporting_devices: Option<f64>,
    pub rounded_reporting_devices: Option<i64>,
    /// Observed interquartile range, NOT a prediction interval.
    pub typical_p25: Option<f64>,
    pub typical_p75: Option<f64>,
    /// low / moderate / high / insufficient, based on samples and variability.
    pub reliability: &'static str,
}

#[derive(Debug, Serialize)]
pub struct BuildingPrediction {
    pub building: String,
    pub target_date: String,
    pub weekday: String,
    pub time_local: String,
    pub timezone: String,
    pub window_minutes: i64,
    pub metric: &'static str,
    pub method: &'static str,
    pub prediction: PredictionEstimate,
    pub samples_inspected: usize,
    pub samples_used: usize,
    pub outliers_excluded: usize,
    pub historical_samples: Vec<HistoricalObservation>,
    pub summary: String,
    pub source: &'static str,
    pub methodology: &'static str,
}

#[derive(Debug, Clone)]
struct HistoricalDate {
    day: NaiveDate,
    target_epoch: i64,
}

struct Selection {
    day: NaiveDate,
    time: NaiveTime,
    timezone: Tz,
    window_minutes: i64,
    historical: Vec<HistoricalDate>,
}

fn weekday_name(weekday: Weekday) -> &'static str {
    match weekday {
        Weekday::Mon => "Monday",
        Weekday::Tue => "Tuesday",
        Weekday::Wed => "Wednesday",
        Weekday::Thu => "Thursday",
        Weekday::Fri => "Friday",
        Weekday::Sat => "Saturday",
        Weekday::Sun => "Sunday",
    }
}

fn parse_weekday(raw: &str) -> Option<Weekday> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "monday" | "mon" => Some(Weekday::Mon),
        "tuesday" | "tue" => Some(Weekday::Tue),
        "wednesday" | "wed" => Some(Weekday::Wed),
        "thursday" | "thu" => Some(Weekday::Thu),
        "friday" | "fri" => Some(Weekday::Fri),
        "saturday" | "sat" => Some(Weekday::Sat),
        "sunday" | "sun" => Some(Weekday::Sun),
        _ => None,
    }
}

fn local_time(day: NaiveDate, time: NaiveTime, tz: Tz) -> Option<DateTime<Utc>> {
    // Spring DST skips some local times. Skip such historical samples instead of
    // moving them to a different hour; choose first occurrence during fall DST.
    tz.from_local_datetime(&day.and_time(time))
        .earliest()
        .map(|dt| dt.with_timezone(&Utc))
}

fn select_history(query: &PredictionQuery, timezone: Tz, now: DateTime<Utc>) -> Result<Selection, String> {
    let today = now.with_timezone(&timezone);
    let time = match &query.time {
        Some(text) => NaiveTime::parse_from_str(text, "%H:%M")
            .map_err(|_| "time must be 24-hour HH:MM".to_string())?,
        None => today.time().with_second(0).and_then(|t| t.with_nanosecond(0)).unwrap(),
    };
    let target_weekday = query.weekday.as_deref().map(|s| {
        parse_weekday(s).ok_or_else(|| "weekday must be Monday through Sunday".to_string())
    }).transpose()?;

    let target_day = if let Some(text) = &query.date {
        let parsed = NaiveDate::parse_from_str(text, "%Y-%m-%d")
            .map_err(|_| "date must use YYYY-MM-DD".to_string())?;
        if target_weekday.is_some_and(|wd| wd != parsed.weekday()) {
            return Err("date and weekday do not match".into());
        }
        parsed
    } else if let Some(wd) = target_weekday {
        let days_ahead = (wd.num_days_from_monday() as i64
            - today.weekday().num_days_from_monday() as i64).rem_euclid(7);
        let mut target = today.date_naive() + ChronoDuration::days(days_ahead);
        if days_ahead == 0 && local_time(target, time, timezone).is_some_and(|when| when <= now) {
            target += ChronoDuration::weeks(1);
        }
        target
    } else {
        // Without a date or weekday, predict the same time tomorrow.
        today.date_naive() + ChronoDuration::days(1)
    };

    if target_day > today.date_naive() + ChronoDuration::days(30) {
        return Err("date can be at most 30 days in the future".into());
    }
    if local_time(target_day, time, timezone).is_none() {
        return Err("requested local time is invalid due to a timezone transition".into());
    }

    let weeks = query.weeks.unwrap_or(8);
    if !(3..=12).contains(&weeks) {
        return Err("weeks must be between 3 and 12".into());
    }
    let window_minutes = query.window_minutes.unwrap_or(15);
    if !(5..=60).contains(&window_minutes) {
        return Err("window_minutes must be between 5 and 60".into());
    }

    let mut historical = Vec::new();
    let mut past = target_day - ChronoDuration::weeks(1);
    // Future target dates may have intervening future weeks. Move backwards
    // until we obtain the requested number of COMPLETED, eligible weekdays.
    while historical.len() < weeks {
        if let Some(epoch) = local_time(past, time, timezone) {
            if epoch + ChronoDuration::minutes(window_minutes) <= now {
                historical.push(HistoricalDate { day: past, target_epoch: epoch.timestamp() });
            }
        }
        past = past.checked_sub_signed(ChronoDuration::weeks(1))
            .ok_or_else(|| "date is too early to obtain historical observations".to_string())?;
    }
    Ok(Selection { day: target_day, time, timezone, window_minutes, historical })
}

/// The row counting, outlier handling and final aggregates are all
/// computed on the Databricks SQL warehouse, not in Rust or on the client.
fn prediction_sql(catalog: &str, selection: &Selection, building: &str, min_observations: i64) -> (String, Vec<SqlParameter>) {
    let mut params = vec![
        param("building", building, "STRING"),
        param("min_observations", min_observations.to_string(), "BIGINT"),
    ];
    let mut sample_rows = Vec::with_capacity(selection.historical.len());
    let half_window_seconds = selection.window_minutes * 60;
    for (i, sample) in selection.historical.iter().enumerate() {
        sample_rows.push(format!(
            "(CAST(:day{i} AS DATE), CAST(:start{i} AS BIGINT), CAST(:end{i} AS BIGINT))"
        ));
        params.push(param(format!("day{i}"), sample.day.to_string(), "DATE"));
        params.push(param(format!("start{i}"), (sample.target_epoch - half_window_seconds).to_string(), "BIGINT"));
        params.push(param(format!("end{i}"), (sample.target_epoch + half_window_seconds).to_string(), "BIGINT"));
    }
    // Identifiers must be interpolated; Config::from_env validates the catalog
    // identifier. All potentially untrusted values are bound as SQL parameters.
    let sql = format!(r#"
WITH samples (sample_date, start_epoch, end_epoch) AS (
    VALUES {sample_rows}
),
counts AS (
    SELECT s.sample_date, COUNT(*) AS observations
    FROM samples s
    JOIN `{catalog}`.`public`.`location_events` e
      ON e.`time` >= timestamp_seconds(s.start_epoch)
     AND e.`time` <= timestamp_seconds(s.end_epoch)
    WHERE lower(trim(e.building)) = lower(trim(:building))
    GROUP BY s.sample_date
),
observations AS (
    SELECT s.sample_date,
           CASE WHEN c.observations >= :min_observations THEN c.observations ELSE CAST(NULL AS BIGINT) END AS observations,
           CASE WHEN c.observations IS NULL THEN 'no_data'
                WHEN c.observations < :min_observations THEN 'suppressed'
                ELSE 'available' END AS status
    FROM samples s LEFT JOIN counts c ON c.sample_date = s.sample_date
),
quartiles AS (
    SELECT COUNT(observations) AS n,
           percentile_approx(observations, 0.25) AS q25,
           percentile_approx(observations, 0.75) AS q75
    FROM observations
),
tagged AS (
    SELECT o.sample_date, o.observations, o.status,
           CASE WHEN o.observations IS NOT NULL AND q.n >= 4
                 AND (o.observations < q.q25 - 1.5 * (q.q75 - q.q25)
                      OR o.observations > q.q75 + 1.5 * (q.q75 - q.q25))
                THEN 1 ELSE 0 END AS is_outlier
    FROM observations o CROSS JOIN quartiles q
),
clean AS (
    SELECT observations FROM tagged WHERE observations IS NOT NULL AND is_outlier = 0
),
summary AS (
    SELECT AVG(observations) AS expected,
           percentile_approx(observations, 0.25) AS typical_p25,
           percentile_approx(observations, 0.75) AS typical_p75,
           STDDEV_SAMP(observations) AS variation,
           COUNT(observations) AS used_samples
    FROM clean
),
excluded AS (
    SELECT COUNT(*) AS n FROM tagged WHERE is_outlier = 1
)
SELECT CAST(t.sample_date AS STRING), t.observations, t.status, t.is_outlier,
       s.expected, s.typical_p25, s.typical_p75, s.variation,
       s.used_samples, x.n
FROM tagged t CROSS JOIN summary s CROSS JOIN excluded x
ORDER BY t.sample_date DESC
"#, sample_rows = sample_rows.join(",\n      "));
    (sql, params)
}

fn as_string(row: &[Value], pos: usize) -> Result<Option<&str>, String> {
    match row.get(pos) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(v)) => Ok(Some(v.as_str())),
        _ => Err(format!("invalid Databricks value in column {pos}")),
    }
}
fn as_integer(row: &[Value], pos: usize) -> Result<Option<i64>, String> {
    as_string(row, pos)?.map(|v| v.parse::<i64>().map_err(|_| "invalid integer result".to_string())).transpose()
}
fn as_float(row: &[Value], pos: usize) -> Result<Option<f64>, String> {
    as_string(row, pos)?.map(|v| v.parse::<f64>().map_err(|_| "invalid float result".to_string())).transpose()
}

struct Parsed {
    observations: Vec<HistoricalObservation>,
    expected: Option<f64>,
    p25: Option<f64>,
    p75: Option<f64>,
    stddev: Option<f64>,
    samples_used: usize,
    excluded: usize,
}

fn parse_prediction(rows: &[Vec<Value>]) -> Result<Parsed, String> {
    let mut observations = Vec::with_capacity(rows.len());
    let mut summary: Option<(Option<f64>, Option<f64>, Option<f64>, Option<f64>, usize, usize)> = None;
    for row in rows {
        if row.len() != 10 { return Err("unexpected Databricks prediction column count".into()); }
        let date = NaiveDate::parse_from_str(as_string(row, 0)?.ok_or("missing sample date")?, "%Y-%m-%d")
            .map_err(|_| "invalid sample date".to_string())?;
        let status = as_string(row, 2)?.ok_or("missing sample status")?;
        if !matches!(status, "available" | "suppressed" | "no_data") {
            return Err("invalid sample status".into());
        }
        let observation_count = as_integer(row, 1)?;
        if (status == "available") != observation_count.is_some() || observation_count.is_some_and(|n| n < 0) {
            return Err("inconsistent sample status and count".into());
        }
        let outlier = as_integer(row, 3)?.ok_or("missing outlier flag")?;
        if (outlier != 0 && outlier != 1) || (outlier == 1 && observation_count.is_none()) {
            return Err("invalid outlier flag".into());
        }
        let values = (
            as_float(row, 4)?, as_float(row, 5)?, as_float(row, 6)?, as_float(row, 7)?,
            as_integer(row, 8)?.ok_or("missing sample count")?.try_into()
                .map_err(|_| "negative sample count".to_string())?,
            as_integer(row, 9)?.ok_or("missing excluded count")?.try_into()
                .map_err(|_| "negative outlier count".to_string())?,
        );
        if let Some(ref prior) = summary {
            if *prior != values { return Err("inconsistent aggregate statistics".into()); }
        }
        summary = Some(values);
        observations.push(HistoricalObservation {
            date: date.to_string(),
            weekday: weekday_name(date.weekday()).to_string(),
            observations: observation_count,
            reporting_devices: observation_count,
            status: status.to_owned(),
            excluded_as_outlier: outlier == 1,
            used_for_prediction: observation_count.is_some() && outlier == 0,
        });
    }
    let (expected, p25, p75, stddev, samples_used, excluded) = summary.ok_or("empty Databricks result")?;
    if observations.iter().filter(|o| o.used_for_prediction).count() != samples_used
        || observations.iter().filter(|o| o.excluded_as_outlier).count() != excluded
    {
        return Err("Databricks aggregate counts disagree with samples".into());
    }
    for number in [expected, p25, p75, stddev].into_iter().flatten() {
        if !number.is_finite() || number < 0.0 {
            return Err("invalid Databricks aggregate value".into());
        }
    }
    Ok(Parsed { observations, expected, p25, p75, stddev, samples_used, excluded })
}

fn build_response(building: String, selection: &Selection, parsed: Parsed) -> BuildingPrediction {
    let enough = parsed.samples_used >= 3;
    let estimate = parsed.expected.filter(|_| enough);
    let cv = match (parsed.stddev, parsed.expected) {
        (Some(stddev), Some(mean)) if mean > 0.0 => Some(stddev / mean),
        _ => None,
    };
    let reliability = if !enough { "insufficient" }
        else if parsed.samples_used >= 6 && cv.is_some_and(|v| v <= 0.20) { "high" }
        else if parsed.samples_used >= 4 && cv.is_some_and(|v| v <= 0.40) { "moderate" }
        else { "low" };
    let prediction = PredictionEstimate {
        status: if enough { "available" } else { "insufficient_history" },
        expected_observations: estimate,
        rounded_observations: estimate.map(|n| n.round() as i64),
        expected_reporting_devices: estimate,
        rounded_reporting_devices: estimate.map(|n| n.round() as i64),
        typical_p25: parsed.p25.filter(|_| enough),
        typical_p75: parsed.p75.filter(|_| enough),
        reliability,
    };
    // The forecast is a typical count, NOT a percent-vs-current comparison;
    // do not claim that a location will be "busier than usual" without data.
    let name = mobile_building_name(&building);
    let summary = if let Some(n) = prediction.rounded_observations {
        format!("{name} typically has ~{n} observations.")
    } else {
        format!("{name} needs more historical data.")
    };
    BuildingPrediction {
        building,
        target_date: selection.day.to_string(),
        weekday: weekday_name(selection.day.weekday()).into(),
        time_local: selection.time.format("%H:%M").to_string(),
        timezone: selection.timezone.to_string(),
        window_minutes: selection.window_minutes,
        metric: "location_observations",
        method: METHOD,
        prediction,
        samples_inspected: parsed.observations.len(),
        samples_used: parsed.samples_used,
        outliers_excluded: parsed.excluded,
        historical_samples: parsed.observations,
        summary,
        source: "databricks_sql",
        methodology: METHODOLOGY,
    }
}

fn error(status: StatusCode, detail: impl Into<String>) -> Response {
    (status, Json(json!({"detail":detail.into()}))).into_response()
}

async fn prediction_with_client(building: String, query: PredictionQuery, now: DateTime<Utc>, client: &DbClient) -> Response {
    let selection = match select_history(&query, client.config.timezone, now) {
        Ok(v) => v,
        Err(e) => return error(StatusCode::UNPROCESSABLE_ENTITY, e),
    };
    let (sql, params) = prediction_sql(&client.config.catalog, &selection, &building, client.config.min_observations);
    let rows = match client.send_sql(&sql, params).await {
        Ok(v) => v,
        Err(e) => {
            tracing::error!("Databricks historical prediction query failed: {e}");
            return error(StatusCode::BAD_GATEWAY, "Databricks prediction query failed; check server logs");
        }
    };
    match parse_prediction(&rows) {
        Ok(parsed) if parsed.observations.len() == selection.historical.len()
            && parsed.observations.iter().all(|observation|
                selection.historical.iter().any(|date| date.day.to_string() == observation.date))
            && parsed.observations.iter().map(|x| x.date.as_str())
                .collect::<std::collections::HashSet<_>>().len() == selection.historical.len() => {
            Json(build_response(building, &selection, parsed)).into_response()
        }
        Ok(_) | Err(_) => {
            tracing::error!("Databricks returned invalid historical prediction data");
            error(StatusCode::BAD_GATEWAY, "Databricks returned an invalid prediction result")
        }
    }
}

/// GET /api/v1/buildings/{building}/prediction?date=2026-11-21&time=14:30
/// The default predicts the same campus-local time tomorrow. The historical
/// samples come from previous matching weekdays and never include future data.
pub async fn prediction_handler(Path(building): Path<String>, Query(query): Query<PredictionQuery>) -> Response {
    let building = building.trim().to_string();
    if building.is_empty() || building.chars().count() > 256 {
        return error(StatusCode::UNPROCESSABLE_ENTITY, "building must have 1–256 characters");
    }
    let config = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Databricks prediction config: {e}");
            return error(StatusCode::SERVICE_UNAVAILABLE, "Databricks prediction is not configured");
        }
    };
    let client = match DbClient::new(config) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Cannot construct Databricks client: {e}");
            return error(StatusCode::SERVICE_UNAVAILABLE, "Databricks prediction client is unavailable");
        }
    };
    prediction_with_client(building, query, Utc::now(), &client).await
}

#[cfg(test)]
#[path = "prediction_fixture_tests.rs"]
mod prediction_fixture_tests;
