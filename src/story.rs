//! Databricks-powered, privacy-thresholded building activity stories.
//!
//! Rust handles request validation and safe delivery; Databricks SQL calculates
//! unique reporting-device activity and statistical comparisons. The optional
//! Databricks `ai_query` call turns those aggregates into prose.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::time::{Duration, Instant};

use axum::extract::{Path, Query};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::{DateTime, Datelike, NaiveDate, NaiveTime, TimeZone, Timelike, Utc, Weekday};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Deserialize, Default)]
pub struct StoryQuery {
    /// A local calendar day (YYYY-MM-DD); if weekday is also set they must match.
    pub date: Option<String>,
    /// Most recent Monday, Tuesday, ... Sunday in the campus timezone.
    pub weekday: Option<String>,
    /// Local wall-clock time HH:MM; defaults to current campus-local time.
    pub time: Option<String>,
    /// Number of preceding matching weekdays (2..=12, default 8).
    pub weeks: Option<usize>,
    /// Minutes either side of the requested clock time (5..=60, default 15).
    pub window_minutes: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct DayActivity {
    pub date: String,
    pub weekday: String,
    /// Null means no readings, not yet reached, or privacy suppression.
    pub reporting_devices: Option<i64>,
    /// available, suppressed, no_data, or future
    pub status: String,
}

#[derive(Debug, Serialize)]
pub struct BuildingStory {
    pub building: String,
    pub date: String,
    pub weekday: String,
    pub time_local: String,
    pub timezone: String,
    pub window_minutes: i64,
    pub metric: &'static str,
    pub current: DayActivity,
    pub historical_same_weekday: Vec<DayActivity>,
    pub this_week: Vec<DayActivity>,
    pub weekday_average: Option<f64>,
    pub weekday_samples: usize,
    pub difference_vs_weekday_average_pct: Option<f64>,
    pub other_days_this_week_average: Option<f64>,
    pub other_days_this_week_samples: usize,
    pub difference_vs_other_days_pct: Option<f64>,
    pub story: String,
    pub story_source: &'static str,
    pub methodology: &'static str,
}

const METHODOLOGY: &str = "Each day's value counts distinct, identified reporting devices with a location observation within the configured time window around the same campus-local clock time. Repeated observations per device are counted once; the nearest observation is used. These are reporting devices, not actual building occupancy. Missing/suppressed days are excluded from averages; future days are not treated as zero.";

pub(crate) struct Config {
    pub(crate) host: String,
    pub(crate) token: String,
    pub(crate) warehouse_id: String,
    pub(crate) catalog: String,
    pub(crate) ai_endpoint: Option<String>,
    pub(crate) timezone: Tz,
    pub(crate) min_devices: i64,
}

impl Config {
    pub(crate) fn from_env() -> Result<Self, String> {
        let required = |key: &str| -> Result<String, String> {
            env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{key} must be configured"))
        };
        let host = required("DATABRICKS_HOST")?;
        let host = host.trim().trim_end_matches('/').to_string();
        let parsed = reqwest::Url::parse(&host)
            .map_err(|_| "DATABRICKS_HOST must be an HTTPS workspace URL".to_string())?;
        if parsed.scheme() != "https" || parsed.host_str().is_none()
            || parsed.path() != "/" || parsed.query().is_some()
            || parsed.fragment().is_some() || !parsed.username().is_empty()
        {
            return Err("DATABRICKS_HOST must be an HTTPS workspace URL without a path".into());
        }
        let warehouse_id = required("DATABRICKS_WAREHOUSE_ID")?;
        let catalog = required("DATABRICKS_CATALOG")?;
        // Identifiers cannot be bound as values; whitelist to prevent SQL injection.
        if !catalog.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err("DATABRICKS_CATALOG contains invalid characters".into());
        }
        let ai_endpoint = env::var("DATABRICKS_AI_ENDPOINT")
            .ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        if let Some(endpoint) = &ai_endpoint {
            if !endpoint.chars().all(|c| c.is_ascii_alphanumeric() || "._-/".contains(c)) {
                return Err("DATABRICKS_AI_ENDPOINT contains invalid characters".into());
            }
        }
        let timezone: Tz = env::var("CAMPUS_TIMEZONE")
            .unwrap_or_else(|_| "America/Chicago".into())
            .parse().map_err(|_| "CAMPUS_TIMEZONE must be an IANA timezone".to_string())?;
        let min_devices = env::var("STORY_MIN_DEVICES").unwrap_or_else(|_| "5".into())
            .parse::<i64>().map_err(|_| "STORY_MIN_DEVICES must be an integer".to_string())?;
        if min_devices < 1 {
            return Err("STORY_MIN_DEVICES must be at least 1".into());
        }
        Ok(Self {
            host,
            token: required("DATABRICKS_TOKEN")?,
            warehouse_id,
            catalog,
            ai_endpoint,
            timezone,
            min_devices,
        })
    }
}

#[derive(Clone, Copy)]
struct Sample {
    day: NaiveDate,
    target_epoch: i64,
    is_week: bool,
    is_history: bool,
    is_target: bool,
}

struct Selection {
    day: NaiveDate,
    time: NaiveTime,
    timezone: Tz,
    window_minutes: i64,
    forward_seconds: i64,
    samples: Vec<Sample>,
    historical_days: Vec<NaiveDate>,
    week_days: Vec<NaiveDate>,
}

fn weekday_name(weekday: Weekday) -> &'static str {
    match weekday {
        Weekday::Mon => "Monday", Weekday::Tue => "Tuesday", Weekday::Wed => "Wednesday",
        Weekday::Thu => "Thursday", Weekday::Fri => "Friday",
        Weekday::Sat => "Saturday", Weekday::Sun => "Sunday",
    }
}

fn parse_weekday(value: &str) -> Option<Weekday> {
    match value.trim().to_ascii_lowercase().as_str() {
        "mon" | "monday" => Some(Weekday::Mon),
        "tue" | "tuesday" => Some(Weekday::Tue),
        "wed" | "wednesday" => Some(Weekday::Wed),
        "thu" | "thursday" => Some(Weekday::Thu),
        "fri" | "friday" => Some(Weekday::Fri),
        "sat" | "saturday" => Some(Weekday::Sat),
        "sun" | "sunday" => Some(Weekday::Sun),
        _ => None,
    }
}

fn local_target(day: NaiveDate, time: NaiveTime, tz: Tz) -> Result<DateTime<Utc>, String> {
    let local = day.and_time(time);
    // On a fall-back DST overlap, choose the earlier occurrence consistently.
    tz.from_local_datetime(&local)
        .earliest()
        .map(|d| d.with_timezone(&Utc))
        .ok_or_else(|| "This local time does not exist because of a timezone transition".into())
}

fn select_dates(query: &StoryQuery, tz: Tz, now: DateTime<Utc>) -> Result<Selection, String> {
    let now_local = now.with_timezone(&tz);
    let time = match &query.time {
        Some(raw) => NaiveTime::parse_from_str(&format!("{raw}:00"), "%H:%M:%S")
            .map_err(|_| "time must use 24-hour HH:MM, e.g. 14:30".to_string())?,
        None => now_local.time().with_second(0).and_then(|t| t.with_nanosecond(0)).unwrap(),
    };
    let mut day = if let Some(raw) = &query.date {
        let selected = NaiveDate::parse_from_str(raw, "%Y-%m-%d")
            .map_err(|_| "date must use YYYY-MM-DD".to_string())?;
        if let Some(weekday) = query.weekday.as_deref() {
            let expected = parse_weekday(weekday)
                .ok_or_else(|| "weekday must be Monday through Sunday".to_string())?;
            if selected.weekday() != expected {
                return Err("date and weekday refer to different weekdays".into());
            }
        }
        selected
    } else if let Some(raw) = &query.weekday {
        let requested = parse_weekday(raw)
            .ok_or_else(|| "weekday must be Monday through Sunday".to_string())?;
        let days_back = (now_local.weekday().num_days_from_monday() as i64
            - requested.num_days_from_monday() as i64).rem_euclid(7);
        now_local.date_naive() - chrono::Duration::days(days_back)
    } else {
        now_local.date_naive()
    };
    // For a weekday-only request, use the last occurrence whose clock time has passed.
    if query.date.is_none() && query.weekday.is_some() && local_target(day, time, tz)? > now {
        day = day - chrono::Duration::weeks(1);
    }
    if day > now_local.date_naive() {
        return Err("date cannot be in the future".into());
    }
    if local_target(day, time, tz)? > now {
        return Err("the selected local time has not occurred yet".into());
    }
    let weeks = query.weeks.unwrap_or(8);
    if !(2..=12).contains(&weeks) {
        return Err("weeks must be between 2 and 12".into());
    }
    let window_minutes = query.window_minutes.unwrap_or(15);
    if !(5..=60).contains(&window_minutes) {
        return Err("window_minutes must be between 5 and 60".into());
    }
    let forward_seconds = if day == now_local.date_naive() {
        (now - local_target(day, time, tz)?).num_seconds().clamp(0, window_minutes * 60)
    } else {
        window_minutes * 60
    };
    let first_day_of_week = day - chrono::Duration::days(day.weekday().num_days_from_monday() as i64);
    let week_days: Vec<_> = (0..7).map(|i| first_day_of_week + chrono::Duration::days(i)).collect();
    let historical_days: Vec<_> = (1..=weeks)
        .map(|i| day - chrono::Duration::weeks(i as i64))
        .collect();

    let mut dates = BTreeSet::new();
    dates.insert(day);
    dates.extend(week_days.iter().copied());
    dates.extend(historical_days.iter().copied());

    let samples = dates.into_iter().filter_map(|candidate| {
        let target = local_target(candidate, time, tz).ok()?;
        (target <= now).then_some(Sample {
            day: candidate,
            target_epoch: target.timestamp(),
            is_week: week_days.contains(&candidate),
            is_history: historical_days.contains(&candidate),
            is_target: candidate == day,
        })
    }).collect();
    Ok(Selection { day, time, timezone: tz, window_minutes, forward_seconds, samples, historical_days, week_days })
}

#[derive(Serialize)]
pub(crate) struct SqlParameter {
    name: String,
    value: String,
    #[serde(rename = "type")]
    sql_type: &'static str,
}

pub(crate) fn param(name: impl Into<String>, value: impl Into<String>, sql_type: &'static str) -> SqlParameter {
    SqlParameter { name: name.into(), value: value.into(), sql_type }
}

/// Databricks computes both per-day counts AND averages (Rust never scans raw data).
/// Named bindings protect the building value, windows, and threshold from injection.
fn activity_sql(catalog: &str, selection: &Selection, building: &str, min_devices: i64) -> (String, Vec<SqlParameter>) {
    let mut params = vec![
        param("building", building, "STRING"),
        param("min_devices", min_devices.to_string(), "BIGINT"),
    ];
    let mut lines = Vec::new();
    let seconds = selection.window_minutes * 60;
    for (i, s) in selection.samples.iter().enumerate() {
        lines.push(format!("(CAST(:d{i} AS DATE), CAST(:t{i} AS BIGINT), CAST(:lo{i} AS BIGINT), CAST(:hi{i} AS BIGINT), {week}, {hist}, {target})",
            week = if s.is_week { 1 } else { 0 },
            hist = if s.is_history { 1 } else { 0 },
            target = if s.is_target { 1 } else { 0 }));
        params.push(param(format!("d{i}"), s.day.to_string(), "DATE"));
        params.push(param(format!("t{i}"), s.target_epoch.to_string(), "BIGINT"));
        params.push(param(format!("lo{i}"), (s.target_epoch - seconds).to_string(), "BIGINT"));
        // Compare equivalent observed portions of each window: do not give historical
        // days extra future minutes that are not available for the current day.
        params.push(param(format!("hi{i}"), (s.target_epoch + selection.forward_seconds).to_string(), "BIGINT"));
    }
    let sql = format!(r#"
WITH samples (sample_date, target_epoch, start_epoch, end_epoch, is_week, is_history, is_target) AS (
    VALUES {values}
),
ranked AS (
    SELECT s.sample_date, e.device_id,
        ROW_NUMBER() OVER (
            PARTITION BY s.sample_date, e.device_id
            ORDER BY ABS(unix_timestamp(e.`time`) - s.target_epoch), e.`time` DESC
        ) AS rn
    FROM samples s
    JOIN `{catalog}`.`public`.`location_events` e
      ON e.`time` >= timestamp_seconds(s.start_epoch)
     AND e.`time` <= timestamp_seconds(s.end_epoch)
    WHERE lower(trim(e.building)) = lower(trim(:building))
      AND e.device_id IS NOT NULL
      AND trim(e.device_id) <> ''
      AND lower(trim(e.device_id)) <> 'unknown'
),
counts AS (
    SELECT sample_date, COUNT(*) AS devices
    FROM ranked WHERE rn = 1
    GROUP BY sample_date
),
filtered AS (
    SELECT s.sample_date, s.is_week, s.is_history, s.is_target,
      CASE WHEN c.devices >= :min_devices THEN c.devices ELSE CAST(NULL AS BIGINT) END AS devices,
      CASE WHEN c.devices IS NULL THEN 'no_data'
           WHEN c.devices < :min_devices THEN 'suppressed'
           ELSE 'available' END AS status
    FROM samples s LEFT JOIN counts c ON c.sample_date = s.sample_date
),
summary AS (
    SELECT
      AVG(CASE WHEN is_history = 1 THEN devices END) AS weekday_avg,
      COUNT(CASE WHEN is_history = 1 THEN devices END) AS weekday_samples,
      AVG(CASE WHEN is_week = 1 AND is_target = 0 THEN devices END) AS week_avg,
      COUNT(CASE WHEN is_week = 1 AND is_target = 0 THEN devices END) AS week_samples
    FROM filtered
)
SELECT CAST(f.sample_date AS STRING), f.devices, f.status,
       f.is_week, f.is_history, f.is_target,
       summary.weekday_avg, summary.weekday_samples,
       summary.week_avg, summary.week_samples
FROM filtered f CROSS JOIN summary
ORDER BY f.sample_date
"#, values = lines.join(",\n        "));
    (sql, params)
}

pub(crate) struct DbClient {
    client: reqwest::Client,
    pub(crate) config: Config,
}

impl DbClient {
    pub(crate) fn new(config: Config) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(55))
            .build().map_err(|e| e.to_string())?;
        Ok(Self { client, config })
    }

    pub(crate) async fn send_sql(&self, statement: &str, parameters: Vec<SqlParameter>) -> Result<Vec<Vec<Value>>, String> {
        let body = json!({
            "statement": statement,
            "warehouse_id": self.config.warehouse_id,
            "parameters": parameters,
            "format": "JSON_ARRAY",
            "disposition": "INLINE",
            "row_limit": 100,
            "wait_timeout": "10s",
            "on_wait_timeout": "CONTINUE"
        });
        let url = format!("{}/api/2.0/sql/statements", self.config.host);
        let mut response = self.client.post(&url)
            .bearer_auth(&self.config.token)
            .json(&body)
            .send().await.map_err(|e| format!("Databricks request failed: {e}"))?;
        let mut status = response.status();
        let mut value: Value = response.json().await.map_err(|e| e.to_string())?;
        if !status.is_success() {
            return Err(format!("Databricks HTTP {status}: {}", safe_api_error(&value)));
        }
        let deadline = Instant::now() + Duration::from_secs(45);
        loop {
            match value.pointer("/status/state").and_then(Value::as_str).unwrap_or("") {
                "SUCCEEDED" => break,
                "FAILED" | "CANCELED" | "CLOSED" => {
                    return Err(format!("Databricks SQL failed: {}", safe_api_error(&value)));
                }
                "PENDING" | "RUNNING" => {
                    if Instant::now() >= deadline {
                        return Err("Databricks SQL statement timed out".into());
                    }
                    let id = value.get("statement_id").and_then(Value::as_str)
                        .ok_or("Missing Databricks statement ID")?;
                    tokio::time::sleep(Duration::from_millis(900)).await;
                    response = self.client.get(format!("{url}/{id}"))
                        .bearer_auth(&self.config.token)
                        .send().await.map_err(|e| e.to_string())?;
                    status = response.status();
                    value = response.json().await.map_err(|e| e.to_string())?;
                    if !status.is_success() {
                        return Err(format!("Databricks HTTP {status}: {}", safe_api_error(&value)));
                    }
                }
                other => return Err(format!("Unexpected Databricks statement state: {other}")),
            }
        }
        if value.pointer("/manifest/truncated").and_then(Value::as_bool).unwrap_or(false) {
            return Err("Databricks truncated the SQL result".into());
        }
        let mut rows = Vec::new();
        let mut next = value.pointer("/result/next_chunk_index").and_then(Value::as_i64);
        let mut first_chunk_rows = read_rows(&value)?;
        rows.append(&mut first_chunk_rows);
        let statement_id = value.get("statement_id").and_then(Value::as_str).unwrap_or("").to_string();
        let mut chunks_seen = 0;
        while let Some(index) = next {
            if chunks_seen >= 8 || statement_id.is_empty() {
                return Err("Databricks result contains too many chunks".into());
            }
            let chunk_url = format!("{url}/{statement_id}/result/chunks/{index}");
            let fetched: Value = self.client.get(chunk_url)
                .bearer_auth(&self.config.token)
                .send().await.map_err(|e| e.to_string())?
                .error_for_status().map_err(|e| e.to_string())?
                .json().await.map_err(|e| e.to_string())?;
            let mut new_rows = read_rows(&fetched)?;
            rows.append(&mut new_rows);
            next = fetched.pointer("/next_chunk_index").and_then(Value::as_i64);
            chunks_seen += 1;
        }
        Ok(rows)
    }

    async fn annotate(&self, prompt: String) -> Result<Option<String>, String> {
        let Some(endpoint) = &self.config.ai_endpoint else { return Ok(None) };
        // ai_query requires a literal endpoint name; the config has a strict whitelist.
        let sql = format!("SELECT CAST(ai_query('{endpoint}', :prompt) AS STRING)");
        let rows = self.send_sql(&sql, vec![param("prompt", prompt, "STRING")]).await?;
        Ok(rows.first().and_then(|r| r.first()).and_then(Value::as_str)
            .map(str::trim).filter(|s| !s.is_empty()).map(str::to_string))
    }
}

fn read_rows(value: &Value) -> Result<Vec<Vec<Value>>, String> {
    if let Some(items) = value.pointer("/result/data_array").or_else(|| value.get("data_array")) {
        return serde_json::from_value(items.clone()).map_err(|_| "Invalid Databricks data_array".into());
    }
    Ok(vec![])
}

fn safe_api_error(value: &Value) -> String {
    value.pointer("/status/error/message")
        .or_else(|| value.pointer("/error/message"))
        .or_else(|| value.get("message"))
        .and_then(Value::as_str).unwrap_or("Unknown Databricks error").chars().take(500).collect()
}

fn cell<'a>(row: &'a [Value], idx: usize) -> Result<Option<&'a str>, String> {
    match row.get(idx) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        _ => Err(format!("Databricks returned an invalid cell in column {idx}")),
    }
}
fn number(row: &[Value], idx: usize) -> Result<Option<f64>, String> {
    cell(row, idx)?.map(|s| s.parse().map_err(|_| "Invalid numeric Databricks response".to_string())).transpose()
}
fn whole(row: &[Value], idx: usize) -> Result<Option<i64>, String> {
    cell(row, idx)?.map(|s| s.parse().map_err(|_| "Invalid integer Databricks response".to_string())).transpose()
}

struct AggregateResult {
    days: BTreeMap<NaiveDate, DayActivity>,
    historical_average: Option<f64>,
    historical_count: usize,
    other_week_average: Option<f64>,
    other_week_count: usize,
}

fn parse_activity_rows(rows: &[Vec<Value>]) -> Result<AggregateResult, String> {
    let mut days = BTreeMap::new();
    let mut historical_average = None;
    let mut historical_count = 0;
    let mut other_week_average = None;
    let mut other_week_count = 0;
    for row in rows {
        if row.len() != 10 { return Err("Unexpected Databricks result column count".into()) }
        let day = NaiveDate::parse_from_str(cell(row, 0)?.ok_or("Missing date")?, "%Y-%m-%d")
            .map_err(|_| "Invalid Databricks date".to_string())?;
        let status = cell(row, 2)?.ok_or("Missing status")?;
        if !["available", "suppressed", "no_data"].contains(&status) {
            return Err("Invalid Databricks status".into());
        }
        let count = whole(row, 1)?;
        if (status == "available") != count.is_some() { return Err("Inconsistent Databricks row".into()); }
        days.insert(day, DayActivity {
            date: day.to_string(),
            weekday: weekday_name(day.weekday()).into(),
            reporting_devices: count,
            status: status.into(),
        });
        historical_average = number(row, 6)?;
        historical_count = whole(row, 7)?.unwrap_or(0).try_into()
            .map_err(|_| "Invalid historical sample count".to_string())?;
        other_week_average = number(row, 8)?;
        other_week_count = whole(row, 9)?.unwrap_or(0).try_into()
            .map_err(|_| "Invalid current week sample count".to_string())?;
    }
    Ok(AggregateResult { days, historical_average, historical_count, other_week_average, other_week_count })
}

fn delta(count: Option<i64>, avg: Option<f64>) -> Option<f64> {
    match (count, avg) {
        (Some(n), Some(a)) if a > 0.0 => Some(((n as f64 / a) - 1.0) * 100.0),
        _ => None,
    }
}

fn day_activity(day: NaiveDate, recorded: &BTreeMap<NaiveDate, DayActivity>, now: DateTime<Utc>, time: NaiveTime, tz: Tz) -> DayActivity {
    if local_target(day, time, tz).is_ok_and(|d| d > now) {
        return DayActivity { date: day.to_string(), weekday: weekday_name(day.weekday()).into(), reporting_devices: None, status: "future".into() };
    }
    recorded.get(&day).cloned().unwrap_or_else(|| DayActivity {
        date: day.to_string(), weekday: weekday_name(day.weekday()).into(), reporting_devices: None, status: "no_data".into()
    })
}

// Use a recognizable building name in compact mobile text; the full official
// name remains in the structured `building` field. Parenthetical qualifiers
// can make a one-line mobile status unreasonably long.
pub(crate) fn mobile_building_name(building: &str) -> String {
    let short = building.split_once(" (").map_or(building, |(name, _)| name).trim();
    let mut chars = short.chars();
    let prefix: String = chars.by_ref().take(36).collect();
    if chars.next().is_some() { format!("{}…", prefix.trim_end()) } else { prefix }
}

const MAX_STORY_CHARS: usize = 96;

fn fallback_story(
    building: &str,
    selected: &DayActivity,
    _time: NaiveTime,
    weekday_avg: Option<f64>,
    prior_weeks: usize,
    week_avg: Option<f64>,
    other_days: usize,
) -> String {
    let name = mobile_building_name(building);
    let Some(count) = selected.reporting_devices else {
        return format!("{name} has no activity data for this time.");
    };

    if let Some(pct) = weekday_avg.filter(|_| prior_weeks >= 2)
        .and_then(|avg| delta(Some(count), Some(avg))) {
        if pct.abs() < 10.0 {
            return format!("{name} is about as busy as usual.");
        }
        if pct > 0.0 {
            return format!("{name} is {:.0}% busier than usual.", pct);
        }
        return format!("{name} is {:.0}% less busy than usual.", pct.abs());
    }

    // Only use a "this week" comparison when the same-weekday baseline is
    // unavailable. Do not misleadingly describe it as the usual weekday level.
    if let Some(pct) = week_avg.filter(|_| other_days >= 1)
        .and_then(|avg| delta(Some(count), Some(avg))) {
        if pct.abs() < 10.0 {
            return format!("{name} is near this week's activity level.");
        }
        if pct > 0.0 {
            return format!("{name} is {:.0}% busier than other days this week.", pct);
        }
        return format!("{name} is {:.0}% less busy than other days this week.", pct.abs());
    }

    format!("{name} has no historical comparison yet.")
}

/// AI may rewrite the short story, but may not invent counts, causes, or a
/// change in the direction/magnitude of the verified comparison.
fn annotation_prompt(out: &BuildingStory) -> String {
    let name = mobile_building_name(&out.building);
    let comparison = if out.weekday_samples >= 2 {
        out.difference_vs_weekday_average_pct
            .map(|pct| format!("{pct:.0}% relative to earlier matching weekdays"))
    } else if out.other_days_this_week_samples >= 1 {
        out.difference_vs_other_days_pct
            .map(|pct| format!("{pct:.0}% relative to other measured days this week"))
    } else { None }.unwrap_or_else(|| "insufficient historical data".to_owned());
    format!(
        "Write ONE short, factual activity status for a mobile card (at most {MAX_STORY_CHARS} characters).\n\
         Use this exact short building name: {name}\n\
         VERIFIED INPUT: date {date}, local time {time}, {count} distinct reporting devices.\n\
         VERIFIED COMPARISON: {comparison}.\n\
         Rephrase this verified sentence, if you can do so without changing its meaning:\n\
         {verified}\n\
         Use only the verified rounded percent (when provided), the correct direction,\n\
         and the correct comparison group. The percent measures reporting-device activity,\n\
         NOT measured occupancy. Do not mention other numbers, students, causes, forecasts,\n\
         events, crowds, or actual occupancy. Output only ONE sentence, no extra commentary\n\
         and no Markdown.",
        verified = out.story,
        date = out.date,
        time = out.time_local,
        count = out.current.reporting_devices.map(|n| n.to_string()).unwrap_or_else(|| "unavailable".into()),
    )
}

/// Checks *meaning* and trusted numbers instead of one exact phrasing.
/// The result is canonically prefixed with our own building name, never an
/// unverified name supplied by the model.
fn validate_ai_annotation(text: &str, data: &BuildingStory) -> Result<String, &'static str> {
    // Language models sometimes wrap their only sentence in quotes or line breaks.
    let cleaned = text.trim().trim_matches(|c: char| matches!(c, '"' | '\'' | '“' | '”')).trim();
    if cleaned.is_empty() { return Err("empty response"); }
    if cleaned.contains('\n') || cleaned.contains('\r') {
        return Err("multi-line response");
    }
    if cleaned.contains('<') || cleaned.contains('{') || cleaned.contains('}')
        || cleaned.contains('*') || cleaned.contains('`')
    { return Err("markup or structured output"); }
    if !cleaned.ends_with('.') || cleaned[..cleaned.len() - 1].chars().any(|c| matches!(c, '.' | '!' | '?')) {
        return Err("not a single complete sentence");
    }

    let name = mobile_building_name(&data.building);
    // Some models remove the synthetic '__DEMO__' tag while retaining the name.
    // Permit that alias only for demo buildings; canonicalize the output below.
    let alias = name.strip_prefix("__DEMO__ ");
    let matched_prefix = [Some(name.as_str()), alias].into_iter().flatten()
        .find(|candidate| cleaned.get(..candidate.len())
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(candidate)));
    let Some(prefix) = matched_prefix else { return Err("missing or changed building name"); };
    if !cleaned[prefix.len()..].starts_with(' ') {
        return Err("building name not followed by a space");
    }
    let remainder = cleaned[prefix.len()..].trim();
    if !["is ", "has ", "shows ", "reports ", "sees ", "experiences "]
        .iter().any(|word| remainder.to_ascii_lowercase().starts_with(word)) {
        return Err("building name not followed by an activity statement");
    }
    let lower = remainder.to_ascii_lowercase();
    let forbidden = [
        "because", "due to", "caused", "students", "people", "occupancy",
        "attendance", "headcount", "significant", "event", "crowd",
        "will be", "predicted", "forecast", "probably", "likely",
        "not busier", "not less busy", "no longer",
    ];
    if forbidden.iter().any(|word| lower.contains(word)) {
        return Err("unsupported causal, occupancy, or forecast claim");
    }

    let comparison = if data.weekday_samples >= 2 {
        data.difference_vs_weekday_average_pct.map(|pct| (pct, true))
    } else if data.other_days_this_week_samples >= 1 {
        data.difference_vs_other_days_pct.map(|pct| (pct, false))
    } else { None };
    let more = ["busier", "more active", "higher", "greater", "increased", "above"]
        .iter().any(|word| lower.contains(word));
    let less = ["less busy", "less active", "lower", "fewer", "decreased", "below"]
        .iter().any(|word| lower.contains(word));

    match comparison {
        Some((pct, same_weekday)) if pct.abs() >= 10.0 => {
            let expected_number = format!("{:.0}", pct.abs());
            let expected_percent = format!("{expected_number}%");
            // Require exactly the verified percent; reject additional quantities
            // even if the model has invented a plausible second statistic.
            let numbers: Vec<&str> = remainder.split(|ch: char| !ch.is_ascii_digit())
                .filter(|part| !part.is_empty()).collect();
            if numbers.len() != 1 || numbers[0] != expected_number.as_str()
                || !lower.contains(expected_percent.as_str())
                || remainder.matches('%').count() != 1
            { return Err("number does not match verified percentage"); }
            if (pct > 0.0 && (!more || less)) || (pct < 0.0 && (!less || more)) {
                return Err("direction does not match verified activity change");
            }
            if same_weekday {
                if !["usual", "normal", "typical", "average"]
                    .iter().any(|word| lower.contains(word)) {
                    return Err("missing matching-weekday comparison");
                }
            } else if !lower.contains("this week") || !lower.contains("other days") {
                return Err("missing other-days-this-week comparison");
            }
        }
        Some((_, same_weekday)) => {
            if remainder.contains('%') || remainder.chars().any(|c| c.is_ascii_digit())
                || more || less { return Err("invented change for stable activity"); }
            if same_weekday {
                if !["usual", "normal", "typical", "average"]
                    .iter().any(|word| lower.contains(word)) {
                    return Err("missing usual-level comparison");
                }
            } else if !lower.contains("this week") {
                return Err("missing this-week comparison");
            }
            if !["busy", "activity", "level", "active"]
                .iter().any(|word| lower.contains(word)) {
                return Err("not an activity statement");
            }
        }
        None => {
            if remainder.contains('%') || remainder.chars().any(|c| c.is_ascii_digit())
                || more || less { return Err("invented comparison without history"); }
            if !["history", "historical", "comparison", "data"]
                .iter().any(|word| lower.contains(word)) {
                return Err("did not acknowledge missing history");
            }
        }
    }
    let output = format!("{name} {remainder}");
    if output.chars().count() > MAX_STORY_CHARS {
        return Err("too long for mobile card");
    }
    Ok(output)
}

fn accept_ai_annotation(text: &str, data: &BuildingStory) -> Option<String> {
    validate_ai_annotation(text, data).ok()
}

/// The endpoint keeps the stats computed by Databricks SQL even when the AI
/// endpoint is unavailable, rate-limited, or produces an ungrounded result.
async fn with_optional_ai(response: &mut BuildingStory, client: &DbClient) {
    if client.config.ai_endpoint.is_none() || response.current.reporting_devices.is_none() {
        return;
    }
    match client.annotate(annotation_prompt(response)).await {
        Ok(Some(text)) => match validate_ai_annotation(&text, response) {
            Ok(checked) => {
                response.story = checked;
                response.story_source = "databricks_ai_query";
            }
            Err(reason) => {
                tracing::warn!(reason, "Databricks AI story rejected; using deterministic text");
                // Debug mode only: inspection of short AI text can reveal why
                // the model failed to follow the prompt. Never log SQL tokens.
                tracing::debug!(model_reply = %text.chars().take(160).collect::<String>(),
                    "Rejected Databricks AI story (first 160 chars)");
            }
        },
        Ok(None) => tracing::warn!("Databricks AI returned an empty story; using deterministic text"),
        Err(e) => tracing::warn!("Databricks AI unavailable: {e}; using deterministic text"),
    }
}

fn construct_story(building: String, selection: &Selection, now: DateTime<Utc>, result: AggregateResult) -> BuildingStory {
    let current = day_activity(selection.day, &result.days, now, selection.time, selection.timezone);
    let history: Vec<_> = selection.historical_days.iter().map(|&d| day_activity(d, &result.days, now, selection.time, selection.timezone)).collect();
    let week: Vec<_> = selection.week_days.iter().map(|&d| day_activity(d, &result.days, now, selection.time, selection.timezone)).collect();
    // One matching weekday can be extremely noisy; require at least two.
    let weekday_average = result.historical_average.filter(|_| result.historical_count >= 2);
    let other_week_average = result.other_week_average.filter(|_| result.other_week_count >= 1);
    let story = fallback_story(&building, &current, selection.time, weekday_average,
        result.historical_count, other_week_average, result.other_week_count);
    BuildingStory {
        building,
        date: selection.day.to_string(),
        weekday: weekday_name(selection.day.weekday()).into(),
        time_local: selection.time.format("%H:%M").to_string(),
        timezone: selection.timezone.to_string(),
        window_minutes: selection.window_minutes,
        metric: "distinct_reporting_devices",
        difference_vs_weekday_average_pct: delta(current.reporting_devices, weekday_average),
        difference_vs_other_days_pct: delta(current.reporting_devices, other_week_average),
        current,
        historical_same_weekday: history,
        this_week: week,
        weekday_average,
        weekday_samples: result.historical_count,
        other_days_this_week_average: other_week_average,
        other_days_this_week_samples: result.other_week_count,
        story,
        story_source: "databricks_sql",
        methodology: METHODOLOGY,
    }
}

fn error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, Json(json!({"detail": message.into()}))).into_response()
}

/// The same implementation is used by the production route and offline tests.
/// `now` is explicit so tests can construct a stable calendar date and clock.
async fn story_with_client(
    building: String,
    query: StoryQuery,
    now: DateTime<Utc>,
    client: &DbClient,
) -> Response {
    let selection = match select_dates(&query, client.config.timezone, now) {
        Ok(s) => s,
        Err(e) => return error(StatusCode::UNPROCESSABLE_ENTITY, e),
    };
    let (sql, parameters) = activity_sql(
        &client.config.catalog,
        &selection,
        &building,
        client.config.min_devices,
    );
    let rows = match client.send_sql(&sql, parameters).await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("Databricks activity query failed: {e}");
            return error(StatusCode::BAD_GATEWAY, "Databricks activity query failed; check server logs");
        }
    };
    let result = match parse_activity_rows(&rows) {
        Ok(r) if !r.days.is_empty() => r,
        Ok(_) => return error(StatusCode::BAD_GATEWAY, "Databricks returned no activity rows"),
        Err(e) => {
            tracing::error!("Databricks response parsing failed: {e}");
            return error(StatusCode::BAD_GATEWAY, "Databricks returned an invalid activity result");
        }
    };
    let mut response = construct_story(building, &selection, now, result);
    with_optional_ai(&mut response, client).await;
    Json(response).into_response()
}

/// GET /api/v1/buildings/{building}/story?date=2026-11-14&time=14:30
/// Returns Databricks SQL statistics and optional Databricks AI narration.
pub async fn story_handler(Path(building): Path<String>, Query(query): Query<StoryQuery>) -> Response {
    let building = building.trim().to_string();
    if building.is_empty() || building.chars().count() > 256 {
        return error(StatusCode::UNPROCESSABLE_ENTITY, "building must have 1–256 characters");
    }
    if let Some(ref weekday) = query.weekday {
        if parse_weekday(weekday).is_none() {
            return error(StatusCode::UNPROCESSABLE_ENTITY, "weekday must be Monday through Sunday");
        }
    }
    let cfg = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Databricks story configuration: {e}");
            return error(StatusCode::SERVICE_UNAVAILABLE, "Databricks storytelling is not configured");
        }
    };
    let client = match DbClient::new(cfg) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Databricks HTTP client setup failed: {e}");
            return error(StatusCode::SERVICE_UNAVAILABLE, "Databricks client initialization failed");
        }
    };
    story_with_client(building, query, Utc::now(), &client).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        // 2026-11-14 14:35 CST (Saturday)
        DateTime::parse_from_rfc3339("2026-11-14T20:35:00Z").unwrap().with_timezone(&Utc)
    }
    #[test]
    fn compares_saturday_with_prior_saturdays_and_monday_sunday_this_week() {
        let query = StoryQuery { weekday: Some("Saturday".into()), time: Some("14:30".into()), ..Default::default() };
        let s = select_dates(&query, chrono_tz::America::Chicago, now()).unwrap();
        assert_eq!(s.day.to_string(), "2026-11-14");
        assert_eq!(s.week_days[0].to_string(), "2026-11-09");
        assert_eq!(s.week_days[6].to_string(), "2026-11-15");
        assert_eq!(s.historical_days[0].to_string(), "2026-11-07");
        assert!(s.samples.iter().all(|x| x.day.to_string() != "2026-11-15"));
        assert_eq!(s.samples.iter().find(|x| x.is_target).unwrap().target_epoch, 1794688200);
        assert_eq!(s.forward_seconds, 300);
    }
    #[test]
    fn same_local_time_accounts_for_daylight_savings() {
        let tz = chrono_tz::America::Chicago;
        let time = NaiveTime::from_hms_opt(14,30,0).unwrap();
        let before = local_target(NaiveDate::from_ymd_opt(2026,10,31).unwrap(), time, tz).unwrap();
        let after = local_target(NaiveDate::from_ymd_opt(2026,11,7).unwrap(), time, tz).unwrap();
        assert_eq!((after - before).num_hours(), 169);
    }
    #[test]
    fn query_never_interpolates_building_into_sql() {
        let s = select_dates(&StoryQuery::default(), chrono_tz::America::Chicago, now()).unwrap();
        let name = "O'Brien's Union'; DROP TABLE location_events; --";
        let (sql, params) = activity_sql("campus_lakebase", &s, name, 5);
        assert!(!sql.contains(name));
        assert!(sql.contains("COUNT(*) AS devices"));
        assert!(sql.contains("ROW_NUMBER()"));
        assert!(params.iter().any(|p| p.name == "building" && p.value == name));
    }
    #[test]
    fn missing_and_suppressed_observations_do_not_count_as_zero() {
        let rows = vec![
            vec![json!("2026-11-14"), Value::Null, json!("suppressed"), json!("1"), json!("0"), json!("1"), Value::Null, json!("0"), Value::Null, json!("0")],
        ];
        let result = parse_activity_rows(&rows).unwrap();
        assert_eq!(result.days[&NaiveDate::from_ymd_opt(2026,11,14).unwrap()].reporting_devices, None);
        let s = select_dates(&StoryQuery::default(), chrono_tz::America::Chicago, now()).unwrap();
        let story = construct_story("Memorial Union".into(), &s, now(), result);
        assert!(story.story.to_ascii_lowercase().contains("not enough"));
        assert_eq!(story.difference_vs_weekday_average_pct, None);
    }

    #[test]
    fn parses_databricks_averages_and_computes_percentages() {
        let selection = select_dates(&StoryQuery { weekday: Some("Saturday".into()), time: Some("14:30".into()), ..Default::default() },
            chrono_tz::America::Chicago, now()).unwrap();
        let rows = vec![vec![json!("2026-11-14"), json!("40"), json!("available"),
            json!("1"), json!("0"), json!("1"), json!("25.0"), json!("4"), json!("30.0"), json!("3")]];
        let story = construct_story("Memorial Union".into(), &selection, now(), parse_activity_rows(&rows).unwrap());
        assert_eq!(story.weekday_average, Some(25.0));
        assert_eq!(story.weekday_samples, 4);
        assert!((story.difference_vs_weekday_average_pct.unwrap() - 60.0).abs() < 1e-8);
        assert_eq!(story.other_days_this_week_average, Some(30.0));
        assert!(story.difference_vs_other_days_pct.unwrap() > 33.0);
        assert_eq!(story.current.reporting_devices, Some(40));
    }
    #[test]
    fn chooses_last_week_if_requested_weekday_time_is_in_future() {
        let selection = select_dates(&StoryQuery { weekday: Some("saturday".into()), time: Some("23:00".into()), ..Default::default() },
            chrono_tz::America::Chicago, now()).unwrap();
        assert_eq!(selection.day.to_string(), "2026-11-07");
    }

    #[test]
    fn selects_most_recent_weekday() {
        let s = select_dates(&StoryQuery { weekday: Some("Sunday".into()), ..Default::default() }, chrono_tz::America::Chicago, now()).unwrap();
        assert_eq!(s.day.to_string(), "2026-11-08");
    }
}

// Synthetic Databricks-style fixture tests; no workspace, token, or database is used.
#[cfg(test)]
#[path = "story_fixture_tests.rs"]
mod story_fixture_tests;
