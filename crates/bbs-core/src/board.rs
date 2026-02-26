use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Board {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub newsgroup_name: Option<String>,
}
