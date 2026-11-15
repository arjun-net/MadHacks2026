//! Run `cargo test simulated_story -- --nocapture` to view example response JSON.
//! All data is synthetic. This exercises the Databricks JSON result parser and
//! Rust story fallback, not a live Databricks SQL warehouse or AI endpoint.

use super::*;

/// 2026-11-14, Saturday 14:35 in America/Chicago.
fn demo_now() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-11-14T20:35:00Z")
        .unwrap()
        .with_timezone(&Utc)
}

fn demo_selection() -> Selection {
    select_dates(
        &StoryQuery {
            date: Some("2026-11-14".into()),
            time: Some("14:30".into()),
            weeks: Some(8),
            window_minutes: Some(15),
            ..Default::default()
        },
        chrono_tz::America::Chicago,
        demo_now(),
    )
    .expect("valid synthetic comparison period")
}

/// Simulates a successful Databricks SQL Statement Execution API response.
///
/// Earlier Saturdays: 12, 16, 14, 14 devices -> average 14.0.
/// Monday-Friday of this week: `week_device_count` per day.
/// Selected Saturday: `saturday_device_count` devices.
///
/// Eight previous Saturdays are requested, but only four have data; the
/// unobserved Saturdays must remain `no_data` (not counted as zero).
fn fake_databricks_response(
    selection: &Selection,
    saturday_device_count: i64,
    week_device_count: i64,
) -> Value {
    let mut counts = BTreeMap::<NaiveDate, i64>::new();
    for (date, count) in [
        ("2026-11-07", 12),
        ("2026-10-31", 16),
        ("2026-10-24", 14),
        ("2026-10-17", 14),
    ] {
        counts.insert(NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(), count);
    }
    for date in [
        "2026-11-09",
        "2026-11-10",
        "2026-11-11",
        "2026-11-12",
        "2026-11-13",
    ] {
        counts.insert(
            NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(),
            week_device_count,
        );
    }
    counts.insert(selection.day, saturday_device_count);

    // Match the 10 columns returned by activity_sql() exactly.
    let rows: Vec<Value> = selection
        .samples
        .iter()
        .map(|sample| {
            let devices = counts.get(&sample.day).copied();
            let status = if devices.is_some() { "available" } else { "no_data" };
            let as_flag = |b: bool| if b { "1" } else { "0" };
            json!([
                sample.day.to_string(),
                devices.map(|n| Value::String(n.to_string())).unwrap_or(Value::Null),
                status,
                as_flag(sample.is_week),
                as_flag(sample.is_history),
                as_flag(sample.is_target),
                "14.0", // historical mean over four measured Saturdays
                "4",    // historical sample count
                week_device_count.to_string(), // mean over five other measured weekdays
                "5",    // this-week sample count
            ])
        })
        .collect();

    json!({
        "statement_id": "synthetic-not-real",
        "status": {"state": "SUCCEEDED"},
        "result": {"data_array": rows}
    })
}

fn demo_story(saturday_devices: i64, other_weekday_devices: i64) -> BuildingStory {
    let selection = demo_selection();
    let payload = fake_databricks_response(
        &selection,
        saturday_devices,
        other_weekday_devices,
    );
    let rows = read_rows(&payload).expect("valid synthetic Databricks result");
    let aggregates = parse_activity_rows(&rows).expect("valid synthetic aggregate rows");
    construct_story("Simulation Hall".into(), &selection, demo_now(), aggregates)
}

#[test]
fn simulated_story_detects_saturday_spike_and_returns_fallback_text() {
    let story = demo_story(42, 20);

    assert_eq!(story.date, "2026-11-14");
    assert_eq!(story.weekday, "Saturday");
    assert_eq!(story.time_local, "14:30");
    assert_eq!(story.current.reporting_devices, Some(42));
    assert_eq!(story.historical_same_weekday.len(), 8);
    assert_eq!(story.weekday_samples, 4); // 4 observed, not 8 requested
    assert_eq!(story.weekday_average, Some(14.0));
    assert_eq!(story.difference_vs_weekday_average_pct, Some(200.0));
    assert_eq!(story.other_days_this_week_samples, 5);
    assert_eq!(story.other_days_this_week_average, Some(20.0));
    assert!((story.difference_vs_other_days_pct.unwrap() - 110.0).abs() < 1e-9);
    assert_eq!(story.this_week.len(), 7);
    assert_eq!(story.this_week[6].status, "future"); // Sunday has not happened
    assert!(story.story.starts_with("Potential activity spike:"));
    assert!(story.story.contains("200% higher"));
    assert!(story.story.contains("110% higher"));
    assert!(story.story.contains("not total occupancy"));
    assert_eq!(story.story_source, "databricks_sql"); // AI is intentionally not called

    println!("\n=== SYNTHETIC SPIKE (NO DATABRICKS OR AI CALL) ===\n{}",
        serde_json::to_string_pretty(&story).unwrap());
}

#[test]
fn simulated_story_normal_saturday_does_not_claim_an_anomaly() {
    let story = demo_story(14, 14);
    assert_eq!(story.current.reporting_devices, Some(14));
    assert_eq!(story.weekday_average, Some(14.0));
    assert_eq!(story.difference_vs_weekday_average_pct, Some(0.0));
    assert_eq!(story.difference_vs_other_days_pct, Some(0.0));
    assert!(!story.story.contains("Potential activity spike:"));
    assert!(!story.story.contains("Potential activity dip:"));
    assert!(story.story.contains("approximately equal"));

    println!("\n=== SYNTHETIC NORMAL DAY (NO DATABRICKS OR AI CALL) ===\n{}",
        serde_json::to_string_pretty(&story).unwrap());
}

#[test]
fn simulated_story_identifies_large_drop_without_claiming_significance() {
    let story = demo_story(6, 20);
    assert!(story.difference_vs_weekday_average_pct.unwrap() < -50.0);
    assert!(story.story.starts_with("Potential activity dip:"));
    assert!(!story.story.contains("statistically significant"));
}
