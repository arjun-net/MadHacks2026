
use serde_json::Value;

#[tokio::test]
#[ignore = "Requires running API and Databricks connection"]
async fn test_morgridge_hall_story() {
    let client = reqwest::Client::new();

    let building = "morgridge_hall";

    // Construct and URL-encode the building name automatically.
    let url = format!(
        "http://localhost:8000/api/v1/buildings/{}/story",
        building
            .as_bytes()
            .iter()
            .map(|b| {
                if b.is_ascii_alphanumeric() || b"-._~".contains(b) {
                    (*b as char).to_string()
                } else {
                    format!("%{:02X}", b)
                }
            })
            .collect::<String>()
    );

    let response = client
        .get(&url)
        .query(&[
            ("weekday", "saturday"),
            ("time", "14:30"),
            ("weeks", "8"),
        ])
        .send()
        .await
        .expect("Failed to connect to Rust API");

    let status = response.status();
    let body = response.text().await.expect("Failed to read response");

    assert!(
        status.is_success(),
        "API returned HTTP {}: {}",
        status,
        body
    );

    let data: Value = serde_json::from_str(&body)
        .expect("Invalid JSON response");

    println!(
        "\n=== MORGRIDGE HALL STORY ===\n{}",
        serde_json::to_string_pretty(&data).unwrap()
    );

    assert_eq!(data["building"].as_str(), Some(building));
    assert!(data["story"].as_str().is_some_and(|s| !s.is_empty()));

    assert!(data.get("current").is_some());
    assert!(data.get("historical_same_weekday").is_some());
    assert!(data.get("this_week").is_some());
}
