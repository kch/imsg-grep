#!/usr/bin/swift
import SQLite3
import Foundation
import ObjectiveC
import Darwin.C

func getTime() -> Double {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  let time = mach_absolute_time()
  return Double(time) * Double(timebase.numer) / Double(timebase.denom) / Double(NSEC_PER_SEC)
}

// MARK: - Command Line Args
let args          = CommandLine.arguments.dropFirst()
var useRawLike    = false
var contentPattern: String = ""
var since:         String?
var to:            String?
var from:          String?
var with:          String?
var sender:        String?
var chat:          String?

var i = args.startIndex
while i < args.endIndex {
  switch args[i] {
  case "--since":  i += 1; since  = i < args.endIndex ? args[i] : nil  // ISO date filter
  case "--to":     i += 1; to     = i < args.endIndex ? args[i] : nil  // Match chat name or participants
  case "--from":   i += 1; from   = i < args.endIndex ? args[i] : nil  // Match sender or chat name
  case "--with":   i += 1; with   = i < args.endIndex ? args[i] : nil  // Match sender, chat name, or participants
  case "--sender": i += 1; sender = i < args.endIndex ? args[i] : nil  // Match just the sender
  case "--chat":   i += 1; chat   = i < args.endIndex ? args[i] : nil  // Match just the chat name
  case "--raw":   useRawLike = true                                    // Use LIKE instead of REGEXP
  default: contentPattern = args[i]                                    // The search pattern
  }
  i += 1
}

if contentPattern.isEmpty {
  fputs("Usage: imsg-grep [--flag value] pattern\n", stderr)
  exit(1)
}

class RegexCache {
  static var patterns: [String: NSRegularExpression] = [:]

  static func get(_ pattern: String) -> NSRegularExpression? {
    if let existing = patterns[pattern] {
      return existing
    }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    patterns[pattern] = regex
    return regex
  }
}
// MARK: - SQLite Function Setup
let searchPattern = useRawLike ?
  "%\(contentPattern.lowercased())%" :
  contentPattern
let NSUnarchiver: AnyClass = NSClassFromString("NSUnarchiver")!
let sel              = NSSelectorFromString("unarchiveObjectWithData:")
let imp              = NSUnarchiver.method(for: sel)
let unarchive        = unsafeBitCast(imp, to: (@convention(c) (AnyClass, Selector, NSData) -> NSAttributedString?).self)
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Track query parameters
struct QueryParams {
  var params: [String] = []
  mutating func add(_ value: String) {
    params.append(value)
  }
}

// Setup regexp and attributed text decoding functions
func setupSQLiteFunctions(db: OpaquePointer) {

  // Regular expression matching
  sqlite3_create_function(
    db,
    "REGEXP",
    2,
    SQLITE_UTF8 | SQLITE_DETERMINISTIC,
    nil,
    { context, argc, argv in
      guard let pattern = sqlite3_value_text(argv?[0]),
            let text = sqlite3_value_text(argv?[1]) else {
        sqlite3_result_int(context, 0)
        return
      }
      let patternStr = String(cString: pattern)
      guard let regex = RegexCache.get(patternStr) else {
        sqlite3_result_int(context, 0)
        return
      }
      let nsString = String(cString: text)
      let range    = NSRange(nsString.startIndex..<nsString.endIndex, in: nsString)
      let matches  = regex.firstMatch(in: nsString, range: range) != nil
      sqlite3_result_int(context, matches ? 1 : 0)
    },
    nil,
    nil
  )

  // Attributed text decoder with proper string handling
  sqlite3_create_function(
    db,
    "DECODE_ATTRIBUTED",
    1,
    SQLITE_UTF8 | SQLITE_DETERMINISTIC,
    nil,
    { context, argc, argv in
      guard let data = sqlite3_value_blob(argv?[0]) else {
        sqlite3_result_null(context)
        return
      }
      let length = Int(sqlite3_value_bytes(argv?[0]))
      let bytes = Data(bytes: data, count: length) as NSData
      if let str = unarchive(NSUnarchiver, sel, bytes)?.string {
        str.withCString {
          sqlite3_result_text(context, $0, -1, SQLITE_TRANSIENT)
        }
      } else {
        sqlite3_result_null(context)
      }
    },
    nil,
    nil
  )
}

// MARK: - Query Building
func buildQuery() -> (String, [String]) {
  var conditions = [String]()
  var params = QueryParams()

  // Base query using CTE for efficient text decoding
  var baseQuery = """
    WITH decoded AS (
    SELECT *,
      DECODE_ATTRIBUTED(attributedBody) as decoded_text,
      CASE
      WHEN \(useRawLike ? "LOWER(text) LIKE ?" : "text REGEXP ?") THEN 'text'
      ELSE 'attr'
      END as matched_in
    FROM message
    WHERE (associated_message_type IS NULL
      OR associated_message_type < 2000)
        -- ^^^  Exclude metadata/action messages:
        -- associated_message_type: reaction
        -- 2000: love
        -- 2001: like
        -- 2002: dislike
        -- 2003: laugh
        -- 2004: emphasize
        -- 2005: question
        -- 3000+, 4000 exist too
        -- Main content matching conditions
      AND (\(useRawLike ? "LOWER(text) LIKE ?" : "text REGEXP ?")
      OR (attributedBody IS NOT NULL
        AND length(attributedBody) > 0
        AND \(useRawLike ? "LOWER(DECODE_ATTRIBUTED(attributedBody)) LIKE ?" : "DECODE_ATTRIBUTED(attributedBody) REGEXP ?")))
    )
    SELECT
      decoded.ROWID                                                                as id,
      datetime((decoded.date / 1000000000) + 978307200, 'unixepoch', 'localtime') as date,
      COALESCE(handle.id, '')                                                     as sender,
      COALESCE(handle.service, '')                                                as service,
      chat.style                                                                  as chat_style,
      chat.display_name                                                           as chat_name,
      GROUP_CONCAT(DISTINCT other_handles.id)                                     as participants,
      decoded.text,
      decoded.decoded_text,
      decoded.matched_in,
      decoded.cache_has_attachments,
      decoded.is_from_me
    FROM decoded
      LEFT JOIN handle               ON decoded.handle_id          = handle.ROWID
      LEFT JOIN chat_message_join    ON decoded.ROWID              = chat_message_join.message_id
      LEFT JOIN chat                 ON chat_message_join.chat_id  = chat.ROWID
      LEFT JOIN chat_handle_join     ON chat.ROWID                 = chat_handle_join.chat_id
      LEFT JOIN handle other_handles ON chat_handle_join.handle_id = other_handles.ROWID
    """

  // Add pattern parameters for both text and attributed content
  params.add(searchPattern)
  params.add(searchPattern)
  params.add(searchPattern)

  // Additional search conditions
  // Filter messages after the given ISO date (e.g. 2023-01-01)
  if let since = since {
    conditions.append("datetime(decoded.date / 1000000000 + 978307200, 'unixepoch') >= datetime(?)")
    params.add(since)
  }

  // Match messages in chats where name matches or any participant matches pattern
  if let to = to {
    conditions.append("""
      (chat.display_name REGEXP ? OR
       EXISTS (
         SELECT 1 FROM chat_handle_join chj
         JOIN handle h ON chj.handle_id = h.ROWID
         WHERE chj.chat_id = chat.ROWID AND h.id REGEXP ?
       ))
      """)
    params.add(to)
    params.add(to)
  }

  // Match messages where sender handle matches pattern exactly
  if let sender = sender {
    conditions.append("handle.id REGEXP ?")
    params.add(sender)
  }

  // Match messages in chats where name matches pattern exactly
  if let chat = chat {
    conditions.append("chat.display_name REGEXP ?")
    params.add(chat)
  }
  // Match messages where either sender or chat name matches pattern
  if let from = from {
    conditions.append("(sender REGEXP ? OR chat.display_name REGEXP ?)")
    params.add(from)
    params.add(from)
  }

  // Match messages where sender, chat name, or any participant matches pattern
  if let with = with {
    conditions.append("""
      (handle.id REGEXP ? OR
       chat.display_name REGEXP ? OR
       EXISTS (
         SELECT 1 FROM chat_handle_join chj
         JOIN handle h ON chj.handle_id = h.ROWID
         WHERE chj.chat_id = chat.ROWID AND h.id REGEXP ?
       ))
      """)
    params.add(with)
    params.add(with)
    params.add(with)
  }

  if !conditions.isEmpty {
    baseQuery += "\nWHERE " + conditions.joined(separator: " AND ")
  }

  baseQuery += """

    GROUP BY decoded.ROWID
    ORDER BY decoded.date DESC
    """

  return (baseQuery, params.params)
}

// MARK: - Message Processing
func getColumnIndex(_ statement: OpaquePointer!, _ name: String) -> Int32 {
  (0..<sqlite3_column_count(statement))
    .first { i in sqlite3_column_name(statement, i).map { String(cString: $0) } == name }
    .map { Int32($0) } ?? {
      fputs("Error: column '\(name)' not found\n", stderr)
      exit(1)
    }()
}

struct MessageJSON: Codable {
  let id: Int64
  let date: String
  let sender: String
  let chat: String?
  let recipients: [String]
  let message: String
  let has_attachments: Bool
}

// Original text output format - now unused but preserved for reference
func processMessage(statement: OpaquePointer, index: Int) -> String {

  let msgId          = sqlite3_column_int64(statement, getColumnIndex(statement, "id"))
  let date           = sqlite3_column_text(statement, getColumnIndex(statement, "date"     )).map { String(cString: $0) } ?? ""
  let isFromMe       = sqlite3_column_int(statement, getColumnIndex(statement, "is_from_me")) == 1
  let sender         = isFromMe ? "ME" : (sqlite3_column_text(statement, getColumnIndex(statement, "sender")).map { String(cString: $0) } ?? "")
  let chatStyle      = sqlite3_column_int( statement, getColumnIndex(statement, "chat_style"  ))
  let chatName       = sqlite3_column_text(statement, getColumnIndex(statement, "chat_name"   )).map { String(cString: $0) }
  let participants   = sqlite3_column_text(statement, getColumnIndex(statement, "participants")).map { String(cString: $0) }
  let text           = sqlite3_column_text(statement, getColumnIndex(statement, "text"        )).map { String(cString: $0) }
  let decodedText    = sqlite3_column_text(statement, getColumnIndex(statement, "decoded_text")).map { String(cString: $0) }
  let hasAttachments = sqlite3_column_int (statement, getColumnIndex(statement, "cache_has_attachments")) == 1
  // let service     = sqlite3_column_text(statement, getColumnIndex(statement, "service"     )).map { String(cString: $0) } ?? ""
  // let matchedIn   = sqlite3_column_text(statement, getColumnIndex(statement, "matched_in"  )).map { String(cString: $0) }

  //let messageText: String
  //let textAlert: String
  //if let t = text, let dt = decodedText {
  //  if t == dt {
  //    messageText = t
  //    textAlert = ""
  //  } else {
  //    messageText = "TEXT: \(t)\nATTR: \(dt)"
  //    textAlert = "[!] Different text versions"
  //  }
  //} else {
  //  messageText = text ?? decodedText ?? ""
  //  textAlert = ""
  //}

  let message = MessageJSON(
    id: msgId,
    date: date,
    sender: sender,
    chat: chatStyle == 43 ? chatName : nil,
    recipients: participants?.split(separator: ",").map { String($0) } ?? [],
    message: text ?? decodedText ?? "",
    has_attachments: hasAttachments
  )

  messages.append(message)
  return "" // We'll encode everything at the end

  /*
   -- From: handle.id
   -- Examples: "john@example.com", "+1234567890", "someone@icloud.com"
   SELECT COALESCE(handle.id, '') as sender

   -- Service: handle.service
   -- Examples: "iMessage", "SMS", "icloud.com"
   SELECT COALESCE(handle.service, '') as service

   -- Chat Type: chat.style
   -- 43 = Group chat
   -- 45 = Individual chat
   SELECT chat.style as chat_style

   -- Chat Name: chat.display_name
   -- Examples: "Family Group", "Work Team", "John and Bob"
   -- NULL for individual chats unless manually named
   SELECT chat.display_name as chat_name

   -- Participants: GROUP_CONCAT of handle.id for chat members
   -- Examples: "bob@icloud.com,alice@example.com,+1234567890"
   -- Comma-separated list of all participants except yourself
   SELECT GROUP_CONCAT(DISTINCT other_handles.id) as participants

   -- Message: combination of message.text and decoded_text
   -- text: message.text
   -- Example: "Hey, what's up?"
   -- decoded_text: DECODE_ATTRIBUTED(message.attributedBody)
   -- Example: "Meeting at 2pm 📅" (with emoji/formatting)

   -- Matched In: our CASE statement result
   -- Values: "text" or "attr"
   -- Shows whether match was found in plain text or attributed text
   CASE WHEN ... THEN 'text' ELSE 'attr' END as matched_in

   -- Attachments: message.cache_has_attachments
   -- Values: 0 or 1
   -- Indicates if message includes photos, files, etc.
   SELECT decoded.cache_has_attachments

   */

  //return """
  //  [\(index)] \(date) \(textAlert)
  //  From:     \(sender)
  //  Service:    \(service)
  //  Chat Type:  \(chatType)
  //  Chat Name:  \(chatName ?? "none")
  //  Participants: \(participants ?? "none")
  //  Message:    \(messageText)
  //  Matched In:   \(matchedIn ?? "unknown")
  //  Attachments:  \(hasAttachments)
  //  ----------------
  //  """
}

var messages: [MessageJSON] = []
// MARK: - Main Run
let homePath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
var db: OpaquePointer?

guard sqlite3_open(homePath, &db) == SQLITE_OK,
    let db = db else {
  fputs("Cannot open database\n", stderr)
  exit(1)
}
defer { sqlite3_close(db) }

setupSQLiteFunctions(db: db)

let (query, params) = buildQuery()
// fputs("\nQuery:\n\(query)\n", stderr)
// fputs("\nParameters: \(params)\n", stderr)

var statement: OpaquePointer?
guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
  fputs("Cannot prepare statement: \(String(cString: sqlite3_errmsg(db)))\n", stderr)
  exit(1)
}
defer { sqlite3_finalize(statement) }

for (index, param) in params.enumerated() {
  let idx = Int32(index + 1)
  // fputs("Binding param[\(idx)]: \(param)\n", stderr)
  param.withCString { cstr in
    let result = sqlite3_bind_text(statement, idx, cstr, -1, SQLITE_TRANSIENT)
    if result != SQLITE_OK {
      fputs("Failed to bind parameter \(idx): \(String(cString: sqlite3_errmsg(db)))\n", stderr)
    }
  }
}

let start = getTime()

var matchCount = 0
while sqlite3_step(statement) == SQLITE_ROW {
  matchCount += 1
  print(processMessage(statement: statement!, index: matchCount))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted]
print(String(data: try! encoder.encode(messages), encoding: .utf8)!)
fputs("Found \(matchCount) matches in \(String(format: "%.3f", getTime() - start))s\n", stderr)
