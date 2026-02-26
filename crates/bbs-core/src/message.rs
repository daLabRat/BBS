use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: i64,
    pub board_id: i64,
    pub author_id: i64,
    pub subject: String,
    pub body: String,
    pub created_at: i64,
    pub parent_id: Option<i64>,
}
