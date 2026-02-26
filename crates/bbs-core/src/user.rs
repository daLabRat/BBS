use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct User {
    pub id: i64,
    pub username: String,
    pub password_hash: String,
    pub is_sysop: bool,
    pub created_at: i64,
    pub last_login: Option<i64>,
}

impl User {
    pub fn display_name(&self) -> &str {
        &self.username
    }
}
