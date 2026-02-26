//! Shared ANSI/VT100 utilities and terminal primitives.
//! Used by bbs-telnet and bbs-ssh crates.

/// Named ANSI escape sequences.
pub mod ansi {
    pub const RESET: &str = "\x1b[0m";
    pub const BOLD: &str = "\x1b[1m";
    pub const CLEAR_SCREEN: &str = "\x1b[2J\x1b[H";
    pub const HIDE_CURSOR: &str = "\x1b[?25l";
    pub const SHOW_CURSOR: &str = "\x1b[?25h";

    pub fn fg(r: u8, g: u8, b: u8) -> String {
        format!("\x1b[38;2;{r};{g};{b}m")
    }

    pub fn bg(r: u8, g: u8, b: u8) -> String {
        format!("\x1b[48;2;{r};{g};{b}m")
    }

    pub fn named(name: &str) -> &'static str {
        match name {
            "reset" => RESET,
            "bold" => BOLD,
            "clear" => CLEAR_SCREEN,
            "hide_cursor" => HIDE_CURSOR,
            "show_cursor" => SHOW_CURSOR,
            _ => RESET,
        }
    }
}
