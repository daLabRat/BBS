//! Integration tests for the Database layer using an in-memory SQLite DB.

use crate::{hash_password, verify_password, Database};

async fn test_db() -> Database {
    let db = Database::connect("sqlite::memory:").await.unwrap();
    db.migrate().await.unwrap();
    db
}

// ── Auth ──────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_hash_and_verify_password() {
    let hash = hash_password("secret").unwrap();
    assert!(verify_password("secret", &hash).unwrap());
    assert!(!verify_password("wrong", &hash).unwrap());
}

// ── Users ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_create_and_find_user() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("alice", &hash).await.unwrap();
    assert_eq!(user.username, "alice");
    assert!(!user.is_sysop);
    assert!(!user.banned);

    let found = db.find_user_by_username("alice").await.unwrap().unwrap();
    assert_eq!(found.id, user.id);

    let by_id = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert_eq!(by_id.username, "alice");

    let missing = db.find_user_by_username("nobody").await.unwrap();
    assert!(missing.is_none());
}

#[tokio::test]
async fn test_duplicate_username_fails() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    db.create_user("bob", &hash).await.unwrap();
    assert!(db.create_user("bob", &hash).await.is_err());
}

#[tokio::test]
async fn test_update_last_login() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("carol", &hash).await.unwrap();
    assert!(user.last_login.is_none());
    db.update_last_login(user.id).await.unwrap();
    let updated = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert!(updated.last_login.is_some());
}

#[tokio::test]
async fn test_ban_and_unban() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("dave", &hash).await.unwrap();
    assert!(!user.banned);
    db.set_banned(user.id, true).await.unwrap();
    let banned = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert!(banned.banned);
    db.set_banned(user.id, false).await.unwrap();
    let unbanned = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert!(!unbanned.banned);
}

#[tokio::test]
async fn test_promote_and_demote() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("eve", &hash).await.unwrap();
    assert!(!user.is_sysop);
    db.set_sysop(user.id, true).await.unwrap();
    let promoted = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert!(promoted.is_sysop);
    db.set_sysop(user.id, false).await.unwrap();
    let demoted = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert!(!demoted.is_sysop);
}

#[tokio::test]
async fn test_change_password() {
    let db = test_db().await;
    let hash = hash_password("old").unwrap();
    let user = db.create_user("frank", &hash).await.unwrap();
    let new_hash = hash_password("new").unwrap();
    db.change_password(user.id, &new_hash).await.unwrap();
    let updated = db.find_user_by_id(user.id).await.unwrap().unwrap();
    assert!(verify_password("new", &updated.password_hash).unwrap());
    assert!(!verify_password("old", &updated.password_hash).unwrap());
}

#[tokio::test]
async fn test_list_users() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    db.create_user("user1", &hash).await.unwrap();
    db.create_user("user2", &hash).await.unwrap();
    let users = db.list_users().await.unwrap();
    assert_eq!(users.len(), 2);
}

#[tokio::test]
async fn test_user_stats() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("grace", &hash).await.unwrap();
    let (joined, last_login, posts, sent, received) =
        db.user_stats(user.id).await.unwrap();
    assert!(joined > 0);
    assert!(last_login.is_none());
    assert_eq!(posts, 0);
    assert_eq!(sent, 0);
    assert_eq!(received, 0);
}

// ── Boards & Messages ─────────────────────────────────────────────────────────

#[tokio::test]
async fn test_create_and_list_boards() {
    let db = test_db().await;
    let initial = db.list_boards().await.unwrap().len();
    let id = db.create_board("TestBoard", "A test board").await.unwrap();
    assert!(id > 0);
    let boards = db.list_boards().await.unwrap();
    assert_eq!(boards.len(), initial + 1);
    assert!(boards.iter().any(|b| b.name == "TestBoard"));
}

#[tokio::test]
async fn test_delete_board() {
    let db = test_db().await;
    let before = db.list_boards().await.unwrap().len();
    let id = db.create_board("Temp", "Temporary").await.unwrap();
    assert_eq!(db.list_boards().await.unwrap().len(), before + 1);
    db.delete_board(id).await.unwrap();
    assert_eq!(db.list_boards().await.unwrap().len(), before);
}

#[tokio::test]
async fn test_post_and_list_messages() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("hank", &hash).await.unwrap();
    let board_id = db.create_board("HankBoard", "").await.unwrap();

    assert!(db.list_messages(board_id).await.unwrap().is_empty());

    let msg_id = db
        .post_message(board_id, user.id, "Hello", "World")
        .await
        .unwrap();
    assert!(msg_id > 0);

    let messages = db.list_messages(board_id).await.unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].0.subject, "Hello");
    assert_eq!(messages[0].1, "hank");
}

#[tokio::test]
async fn test_message_threading() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("ivan", &hash).await.unwrap();
    let board_id = db.create_board("Threads", "").await.unwrap();

    let root_id = db
        .post_message(board_id, user.id, "Root", "Root body")
        .await
        .unwrap();
    let reply_id = db
        .post_reply(board_id, root_id, user.id, "Re: Root", "Reply body")
        .await
        .unwrap();

    let messages = db.list_messages(board_id).await.unwrap();
    assert_eq!(messages.len(), 2);
    let reply = messages.iter().find(|(m, _)| m.id == reply_id).unwrap();
    assert_eq!(reply.0.parent_id, Some(root_id));
}

#[tokio::test]
async fn test_message_counts() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("judy", &hash).await.unwrap();
    let board_id = db.create_board("Count", "").await.unwrap();
    assert_eq!(db.count_messages(board_id).await.unwrap(), 0);
    db.post_message(board_id, user.id, "S", "B").await.unwrap();
    db.post_message(board_id, user.id, "S2", "B2").await.unwrap();
    assert_eq!(db.count_messages(board_id).await.unwrap(), 2);
}

#[tokio::test]
async fn test_search_messages() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("ken", &hash).await.unwrap();
    let board_id = db.create_board("Search", "").await.unwrap();
    db.post_message(board_id, user.id, "Rust is great", "I love Rust")
        .await
        .unwrap();
    db.post_message(board_id, user.id, "Lua is fun", "Scripting with Lua")
        .await
        .unwrap();

    let results = db.search_messages("Rust").await.unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].0.subject, "Rust is great");

    let all = db.search_messages("is").await.unwrap();
    assert_eq!(all.len(), 2);

    let none = db.search_messages("Python").await.unwrap();
    assert!(none.is_empty());
}

// ── Board visits ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_board_visits_counts() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("lee", &hash).await.unwrap();
    let board_id = db.create_board("Visits", "").await.unwrap();

    // Before any posts: both counts are 0
    let rows = db.list_boards_with_counts(user.id).await.unwrap();
    let entry = rows.iter().find(|(b, _, _)| b.id == board_id).unwrap();
    assert_eq!(entry.1, 0); // total
    assert_eq!(entry.2, 0); // new

    // Post a message; not yet visited → counts as new
    db.post_message(board_id, user.id, "Hello", "World").await.unwrap();
    let rows = db.list_boards_with_counts(user.id).await.unwrap();
    let entry = rows.iter().find(|(b, _, _)| b.id == board_id).unwrap();
    assert_eq!(entry.1, 1); // total
    assert_eq!(entry.2, 1); // new (never visited)

    // Mark visited; new count should drop to 0
    db.mark_board_visited(user.id, board_id).await.unwrap();
    let rows = db.list_boards_with_counts(user.id).await.unwrap();
    let entry = rows.iter().find(|(b, _, _)| b.id == board_id).unwrap();
    assert_eq!(entry.1, 1); // total still 1
    assert_eq!(entry.2, 0); // no new messages since visit
}

// ── Mail ──────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_mail_send_and_inbox() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let alice = db.create_user("alice_m", &hash).await.unwrap();
    let bob = db.create_user("bob_m", &hash).await.unwrap();

    assert_eq!(db.mail_unread_count(bob.id).await.unwrap(), 0);
    assert!(db.mail_inbox(bob.id).await.unwrap().is_empty());

    db.mail_send(alice.id, bob.id, "Hi", "Hello there")
        .await
        .unwrap();

    assert_eq!(db.mail_unread_count(bob.id).await.unwrap(), 1);

    let inbox = db.mail_inbox(bob.id).await.unwrap();
    assert_eq!(inbox.len(), 1);
    assert_eq!(inbox[0].2, "Hi"); // subject
    assert!(!inbox[0].4);          // not read

    let sent = db.mail_sent(alice.id).await.unwrap();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].2, "Hi");
}

#[tokio::test]
async fn test_mail_mark_read() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let alice = db.create_user("alice_r", &hash).await.unwrap();
    let bob = db.create_user("bob_r", &hash).await.unwrap();

    let mail_id = db
        .mail_send(alice.id, bob.id, "Test", "Body")
        .await
        .unwrap();
    assert_eq!(db.mail_unread_count(bob.id).await.unwrap(), 1);

    db.mail_mark_read(mail_id, bob.id).await.unwrap();
    assert_eq!(db.mail_unread_count(bob.id).await.unwrap(), 0);

    let inbox = db.mail_inbox(bob.id).await.unwrap();
    assert!(inbox[0].4); // now read

    // Idempotent
    db.mail_mark_read(mail_id, bob.id).await.unwrap();
    assert_eq!(db.mail_unread_count(bob.id).await.unwrap(), 0);
}

#[tokio::test]
async fn test_mail_ownership() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let alice = db.create_user("alice_o", &hash).await.unwrap();
    let bob = db.create_user("bob_o", &hash).await.unwrap();
    let carol = db.create_user("carol_o", &hash).await.unwrap();

    let mail_id = db
        .mail_send(alice.id, bob.id, "Private", "For Bob")
        .await
        .unwrap();

    // Carol cannot mark Bob's mail read
    db.mail_mark_read(mail_id, carol.id).await.unwrap();
    assert_eq!(db.mail_unread_count(bob.id).await.unwrap(), 1);
}

// ── Bulletins ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_bulletins() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();
    let user = db.create_user("sysop_b", &hash).await.unwrap();

    assert!(db.list_bulletins().await.unwrap().is_empty());

    let id = db
        .post_bulletin(user.id, "Welcome", "Welcome to the BBS!")
        .await
        .unwrap();
    assert!(id > 0);

    let list = db.list_bulletins().await.unwrap();
    assert_eq!(list.len(), 1);

    let full = db.get_bulletin(id).await.unwrap().unwrap();
    assert_eq!(full.2, "Welcome"); // title
    assert_eq!(full.3, "Welcome to the BBS!"); // body

    db.delete_bulletin(id).await.unwrap();
    assert!(db.list_bulletins().await.unwrap().is_empty());

    // get_bulletin still returns soft-deleted entries
    assert!(db.get_bulletin(id).await.unwrap().is_some());
}

// ── Last callers ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_last_callers() {
    let db = test_db().await;
    let hash = hash_password("pass").unwrap();

    assert!(db.last_callers(10).await.unwrap().is_empty());

    let u1 = db.create_user("caller1", &hash).await.unwrap();
    let u2 = db.create_user("caller2", &hash).await.unwrap();
    db.update_last_login(u1.id).await.unwrap();
    db.update_last_login(u2.id).await.unwrap();

    let callers = db.last_callers(10).await.unwrap();
    assert_eq!(callers.len(), 2);

    let limited = db.last_callers(1).await.unwrap();
    assert_eq!(limited.len(), 1);
}
