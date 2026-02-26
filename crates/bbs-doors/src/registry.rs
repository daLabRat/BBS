use anyhow::Result;
use std::path::{Path, PathBuf};

/// Scans the doors/ directory and returns available door names.
pub struct DoorRegistry {
    doors_dir: PathBuf,
}

impl DoorRegistry {
    pub fn new(doors_dir: impl AsRef<Path>) -> Self {
        Self {
            doors_dir: doors_dir.as_ref().to_owned(),
        }
    }

    pub fn list(&self) -> Result<Vec<String>> {
        let mut doors = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&self.doors_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() && path.join("main.lua").exists() {
                    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                        doors.push(name.to_owned());
                    }
                }
            }
        }
        doors.sort();
        Ok(doors)
    }

    pub fn main_lua(&self, name: &str) -> PathBuf {
        self.doors_dir.join(name).join("main.lua")
    }
}
