use std::env;

pub struct Settings {
    pub store_backend: String,
    pub port: u16,
    pub pg_host: String,
    pub pg_port: u16,
    pub pg_database: String,
    pub pg_user: String,
    pub pg_password: String,
    pub flush_interval_s: u64,
    pub flush_batch_size: usize,
}

fn var(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_string())
}

impl Settings {
    pub fn from_env() -> Self {
        Self {
            store_backend: var("STORE_BACKEND", "memory"),
            port: var("PORT", "8000").parse().expect("PORT must be a number"),
            pg_host: var("PG_HOST", ""),
            pg_port: var("PG_PORT", "5432").parse().expect("PG_PORT must be a number"),
            pg_database: var("PG_DATABASE", "databricks_postgres"),
            pg_user: var("PG_USER", ""),
            pg_password: var("PG_PASSWORD", ""),
            flush_interval_s: var("FLUSH_INTERVAL_S", "5").parse().expect("FLUSH_INTERVAL_S must be a number"),
            flush_batch_size: var("FLUSH_BATCH_SIZE", "100").parse().expect("FLUSH_BATCH_SIZE must be a number"),
        }
    }
}
