//! Shared ANSI/VT100 utilities and terminal primitives.
//! Used by bbs-telnet and bbs-ssh crates.

pub mod terminal;
pub use terminal::Terminal;

/// Named ANSI escape sequences.
pub mod ansi {
    pub const RESET: &str = "\x1b[0m";
    pub const BOLD: &str = "\x1b[1m";
    pub const DIM: &str = "\x1b[2m";
    pub const UNDERLINE: &str = "\x1b[4m";
    pub const BLINK: &str = "\x1b[5m";
    pub const REVERSE: &str = "\x1b[7m";
    pub const FG_BLACK: &str = "\x1b[30m";
    pub const FG_RED: &str = "\x1b[31m";
    pub const FG_GREEN: &str = "\x1b[32m";
    pub const FG_YELLOW: &str = "\x1b[33m";
    pub const FG_BLUE: &str = "\x1b[34m";
    pub const FG_MAGENTA: &str = "\x1b[35m";
    pub const FG_CYAN: &str = "\x1b[36m";
    pub const FG_WHITE: &str = "\x1b[37m";
    pub const FG_BRIGHT_BLACK: &str = "\x1b[90m";
    pub const FG_BRIGHT_RED: &str = "\x1b[91m";
    pub const FG_BRIGHT_GREEN: &str = "\x1b[92m";
    pub const FG_BRIGHT_YELLOW: &str = "\x1b[93m";
    pub const FG_BRIGHT_BLUE: &str = "\x1b[94m";
    pub const FG_BRIGHT_MAGENTA: &str = "\x1b[95m";
    pub const FG_BRIGHT_CYAN: &str = "\x1b[96m";
    pub const FG_BRIGHT_WHITE: &str = "\x1b[97m";
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
            "dim" => DIM,
            "underline" => UNDERLINE,
            "blink" => BLINK,
            "reverse" => REVERSE,
            "black" => FG_BLACK,
            "red" => FG_RED,
            "green" => FG_GREEN,
            "yellow" => FG_YELLOW,
            "blue" => FG_BLUE,
            "magenta" => FG_MAGENTA,
            "cyan" => FG_CYAN,
            "white" => FG_WHITE,
            "bright_black" | "dark_gray" => FG_BRIGHT_BLACK,
            "bright_red" => FG_BRIGHT_RED,
            "bright_green" => FG_BRIGHT_GREEN,
            "bright_yellow" => FG_BRIGHT_YELLOW,
            "bright_blue" => FG_BRIGHT_BLUE,
            "bright_magenta" => FG_BRIGHT_MAGENTA,
            "bright_cyan" => FG_BRIGHT_CYAN,
            "bright_white" => FG_BRIGHT_WHITE,
            "clear" => CLEAR_SCREEN,
            "hide_cursor" => HIDE_CURSOR,
            "show_cursor" => SHOW_CURSOR,
            _ => "",
        }
    }
}
