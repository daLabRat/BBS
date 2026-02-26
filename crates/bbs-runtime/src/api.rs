//! Registers the `bbs.*` Lua API into a Lua VM.
//!
//! API surface:
//!   bbs.write(text)          -- send text/ANSI to current user's terminal
//!   bbs.writeln(text)
//!   bbs.read_line(prompt)    -- prompt + blocking line read
//!   bbs.read_key()           -- single keypress
//!   bbs.clear()
//!   bbs.menu(definition)     -- render a menu, return selection
//!   bbs.pager(text)          -- scrollable text viewer
//!   bbs.user.name            -- current username
//!   bbs.user.id
//!   bbs.user.is_sysop
//!   bbs.boards.list()
//!   bbs.boards.post(board_id, subject, body)
//!   bbs.boards.read(board_id)
//!   bbs.doors.list()
//!   bbs.doors.launch(name)
//!   bbs.ansi(name)
//!   bbs.time()

// TODO: implement using mlua UserData and async Lua functions
