//! Per-door-session user context passed into the Lua VM.

#[derive(Debug, Clone)]
pub struct DoorUser {
    pub id: i64,
    pub name: String,
    pub is_sysop: bool,
}
