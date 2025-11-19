#!/usr/bin/env ruby
# Core iMessage database processing - builds cached views with decoded messages, contacts, and attachments

require 'fileutils'
require 'sqlite3'
require_relative 'keyed_archive'
require_relative 'attr_str'
require_relative 'timer'

CONTACTS_DB = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
MESSAGES_DB = File.expand_path("~/Library/Messages/chat.db")
CACHE_DB    = File.expand_path("~/.cache/imsg-grep/chat.db")
FileUtils.mkdir_p File.dirname(CACHE_DB)
FileUtils.touch(CACHE_DB)

Timer.start

[CONTACTS_DB, MESSAGES_DB, CACHE_DB].each do |db|
  raise "Database not found: #{db}" unless File.exist?(db)
  raise "Database not readable: #{db}" unless File.readable?(db)
end

$db = SQLite3::Database.new(CACHE_DB)
$db.execute("ATTACH DATABASE '#{CONTACTS_DB}' AS contacts_db")
$db.execute("ATTACH DATABASE '#{MESSAGES_DB}' AS messages_db")

REGEX_CACHE = Hash.new { |h,k| h[k] = Regexp.new(k, Regexp::IGNORECASE) }
$db.create_function("regexp", 2)               { |f, rx, text| f.result = REGEX_CACHE[rx].match?(text) ? 1 : 0 }
$db.create_function("plusdigits", 1)           { |f, text| f.result = text.delete("^0-9+") }
$db.create_function("unarchive_keyed", 1)      { |f, data| f.result = NSKeyedArchive.unarchive(data).to_json }
$db.create_function("unarchive_attributed", 1) { |f, data| f.result = AttributedStringExtractor.extract(data) }


### Sync state stuff

$db.execute "CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value)"
sync_state = $db.execute("SELECT key, value FROM sync_state").to_h
new_state  = $db.prepare(<<~SQL).execute.next_hash
  SELECT
    (SELECT MAX(ZTIMESTAMP) FROM contacts_db.ATRANSACTION) as contacts_timestamp,
    (SELECT seq FROM messages_db.sqlite_sequence WHERE name = 'message') as messages_sequence
SQL

synced_contacts, synced_messages = [sync_state, new_state].map{ it.values_at "contacts_timestamp", "messages_sequence" }.transpose.map{_1==_2}


### Messages to ignore completely

MESSAGES_EXCLUSION = <<~SQL
  ( (associated_message_type IS NULL OR associated_message_type < 2000)                              -- # Exclude metadata/reaction messages
    AND (balloon_bundle_id IS NULL OR balloon_bundle_id != 'com.apple.DigitalTouchBalloonProvider')  -- # Digital touch lol; another check: substr(hex(payload_data), 1, 8) = '08081100'
  )
SQL

# Check if messages_decoded table exists and build exclusion
exclusion_rules = "#{MESSAGES_EXCLUSION}"
last_row = sync_state["messages_sequence"]                   # a roundabout way to get this value but since we already have it…
exclusion_rules << " AND m.ROWID > #{last_row}" if last_row  # exclude messages previously imported


Timer.lap "setup"


### Begin fancy db stuff

if !synced_contacts && !synced_messages
  # table: contacts
  # all contacts, like:
  # id      | 42
  # name    | "John Smith"
  # emails  | ["john@gmail.com", "john@work.com"]
  # numbers | ["+14155551212", "+14155551213"]
  $db.execute "DROP TABLE IF EXISTS contacts"
  $db.execute <<-SQL
    CREATE TABLE contacts AS
    WITH emails AS (
      SELECT ZOWNER, json_group_array(ZADDRESS) as emails
      FROM contacts_db.ZABCDEMAILADDRESS GROUP BY ZOWNER
    ),
    phones AS (
      SELECT ZOWNER, json_group_array(plusdigits(ZFULLNUMBER)) as numbers
      FROM contacts_db.ZABCDPHONENUMBER GROUP BY ZOWNER
    )
    SELECT
      r.Z_PK as id,
      r.ZFIRSTNAME || ' ' || r.ZLASTNAME as name,
      e.emails as emails,
      p.numbers as numbers,
      IIF(r.ZCONTAINERWHERECONTACTISME IS NOT NULL, 1, 0) as is_me
    FROM contacts_db.ZABCDRECORD r
    LEFT JOIN emails e ON e.ZOWNER = r.Z_PK
    LEFT JOIN phones p ON p.ZOWNER = r.Z_PK;
  SQL
  Timer.lap "contacts table created"

  # table: handle_contacts
  # maps message handles to contact IDs:
  # handle     | "+14155551212"
  # contact_id | 42
  $db.execute "DROP TABLE IF EXISTS handle_contacts"
  $db.execute <<-SQL
    CREATE TABLE handle_contacts AS
    WITH all_handles AS (
      SELECT DISTINCT id as handle FROM messages_db.handle
      UNION
      SELECT DISTINCT destination_caller_id as handle
      FROM messages_db.message
      WHERE destination_caller_id IS NOT NULL
    )
    SELECT
      h.handle as handle,
      c.id as contact_id
    FROM all_handles h
    JOIN contacts c ON (
      EXISTS (SELECT 1 FROM json_each(c.numbers) WHERE h.handle = value) OR
      EXISTS (SELECT 1 FROM json_each(c.emails) WHERE h.handle = value)
    );
  SQL
  $db.execute "CREATE UNIQUE INDEX idx_handle_contacts_unique ON handle_contacts(handle, contact_id)"
  Timer.lap "handle_contacts table created, indexed"

  # Add missing handles for "me" contact (past phone numbers, etc)
  $db.execute <<-SQL
    INSERT OR IGNORE INTO handle_contacts (handle, contact_id)
    SELECT DISTINCT
      destination_caller_id as handle,
      (SELECT id FROM contacts WHERE is_me = 1 LIMIT 1) as contact_id
    FROM messages_db.message
    WHERE is_from_me = 1
      AND destination_caller_id IS NOT NULL
      AND destination_caller_id NOT IN (SELECT handle FROM handle_contacts);
  SQL
  Timer.lap "handle_contacts table updated from messages"

  # view: contact_details
  # maps handles to full contact info as json
  # handle   | "+14155551212"
  # contact  | { "name":    "John Smith",
  #          |   "emails":  ["john@gmail.com", "john@work.com"],
  #          |   "numbers": ["+14155551212", "+14155551213"] }
  $db.execute <<~SQL
    CREATE VIEW contact_details AS
    SELECT
      h.handle as handle,
      json_object(
        'name',    c.name,
        'emails',  json(COALESCE(c.emails, '[]')),
        'numbers', json(COALESCE(c.numbers, '[]'))
      ) as contact
    FROM handle_contacts h
    JOIN contacts c ON c.id = h.contact_id;
  SQL
  Timer.lap "contact_details view created"
end # if !synced_contacts && !synced_messages


### messages cache ahaed
if !synced_messages

  MESSAGES_DECODED_QUERY = <<~SQL
    WITH chat_participants AS (
      SELECT
        chat_id,
        jsonb_group_array(h.id) as participant_handles
      FROM messages_db.chat_handle_join chj
      JOIN messages_db.handle h ON chj.handle_id = h.ROWID
      GROUP BY chat_id
    ),
    message_participants AS (
      SELECT
        m.ROWID as message_id,
        (SELECT json_group_array(value) FROM (
          SELECT DISTINCT value FROM (
            SELECT value FROM json_each(p.participant_handles)
            UNION ALL
            -- guess we still need to decide on if include this or not, prob not
            -- SELECT m.destination_caller_id WHERE m.destination_caller_id IS NOT NULL
            -- UNION ALL
            SELECT h.id WHERE h.id IS NOT NULL
          )
        )) as participant_handles,
        IIF(m.is_from_me, m.destination_caller_id, h.id) as sender_handle
      FROM messages_db.message m
      LEFT JOIN messages_db.handle h ON m.handle_id = h.ROWID
      LEFT JOIN messages_db.chat_message_join cm ON m.ROWID = cm.message_id
      LEFT JOIN messages_db.chat c ON cm.chat_id = c.ROWID
      LEFT JOIN chat_participants p ON c.ROWID = p.chat_id
      WHERE #{exclusion_rules}
    )
    SELECT
      m.ROWID as id,
      m.guid,
      mp.sender_handle,
      mp.participant_handles,
      (SELECT json_group_array(json(cd.contact))
        FROM contact_details cd, json_each(mp.participant_handles) ph
        WHERE cd.handle = ph.value) as participant_details,
      (SELECT cd.contact
        FROM contact_details cd
        WHERE cd.handle = mp.sender_handle) as sender_details,
      IIF(m.attributedBody IS NOT NULL, unarchive_attributed(m.attributedBody), NULL) as text_decoded,
      IIF(m.payload_data IS NOT NULL, unarchive_keyed(payload_data), NULL) as payload
    FROM messages_db.message m
    LEFT JOIN message_participants mp ON m.ROWID = mp.message_id
    WHERE #{exclusion_rules}
  SQL


  $db.execute "CREATE TABLE IF NOT EXISTS messages_decoded AS #{MESSAGES_DECODED_QUERY}"
  $db.execute "CREATE INDEX IF NOT EXISTS idx_messages_decoded_id ON messages_decoded(id)"
  $db.execute "INSERT INTO messages_decoded #{MESSAGES_DECODED_QUERY} AND m.ROWID > (SELECT COALESCE(MAX(id), 0) FROM messages_decoded)"
  Timer.lap "messages_decoded table updated"
end # if !synced_messages


APPLE_EPOCH = 978307200
MESSAGES_QUERY = <<~SQL
  SELECT
    m.ROWID as id,
    d.guid,
    d.sender_handle,
    datetime((m.date / 1000000000) + #{APPLE_EPOCH}, 'unixepoch') as utc_time,
    c.style as chat_style,
    c.display_name as chat_name,
    d.participant_handles,
    d.participant_details,
    d.sender_details,
    d.text_decoded,
    COALESCE(m.text, d.text_decoded, '') as computed_text,
    d.payload,
    m.cache_has_attachments as has_attachments,
    m.is_from_me
  FROM messages_db.message m
  LEFT JOIN messages_db.chat_message_join cm ON m.ROWID     = cm.message_id
  LEFT JOIN messages_db.chat c               ON cm.chat_id  = c.ROWID
  LEFT JOIN messages_decoded d               ON m.ROWID     = d.id
  WHERE #{MESSAGES_EXCLUSION}
SQL

$db.execute "CREATE TEMP VIEW messages AS #{MESSAGES_QUERY}"
Timer.lap "messages view created"


# Update cache with fresh values
$db.execute "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('contacts_timestamp', ?), ('messages_sequence', ?)", new_state.values_at("contacts_timestamp", "messages_sequence")

Timer.finish


__END__

$ sqlite3 ~/Library/Messages/chat.db .schema  | grep "CREATE TABLE"

-- Loading resources from /Users/kch/.sqliterc
CREATE TABLE _SqliteDatabaseProperties (key TEXT, value TEXT, UNIQUE(key));
CREATE TABLE deleted_messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, guid TEXT NOT NULL);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE chat_handle_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE, handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE, UNIQUE(chat_id, handle_id));
CREATE TABLE sync_deleted_messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, guid TEXT NOT NULL, recordID TEXT );
CREATE TABLE message_processing_task (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, guid TEXT NOT NULL, task_flags INTEGER NOT NULL );
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL, country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT, person_centric_id TEXT, UNIQUE (id, service) );
CREATE TABLE sync_deleted_chats (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, guid TEXT NOT NULL, recordID TEXT,timestamp INTEGER);
CREATE TABLE message_attachment_join (message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, attachment_id INTEGER REFERENCES attachment (ROWID) ON DELETE CASCADE, UNIQUE(message_id, attachment_id));
CREATE TABLE sync_deleted_attachments (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, guid TEXT NOT NULL, recordID TEXT );
CREATE TABLE kvtable (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, key TEXT UNIQUE NOT NULL, value BLOB NOT NULL);
CREATE TABLE chat_message_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE, message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, message_date INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id));
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT, replace INTEGER DEFAULT 0, service_center TEXT, handle_id INTEGER DEFAULT 0, subject TEXT, country TEXT, attributedBody BLOB, version INTEGER DEFAULT 0, type INTEGER DEFAULT 0, service TEXT, account TEXT, account_guid TEXT, error INTEGER DEFAULT 0, date INTEGER, date_read INTEGER, date_delivered INTEGER, is_delivered INTEGER DEFAULT 0, is_finished INTEGER DEFAULT 0, is_emote INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, is_empty INTEGER DEFAULT 0, is_delayed INTEGER DEFAULT 0, is_auto_reply INTEGER DEFAULT 0, is_prepared INTEGER DEFAULT 0, is_read INTEGER DEFAULT 0, is_system_message INTEGER DEFAULT 0, is_sent INTEGER DEFAULT 0, has_dd_results INTEGER DEFAULT 0, is_service_message INTEGER DEFAULT 0, is_forward INTEGER DEFAULT 0, was_downgraded INTEGER DEFAULT 0, is_archive INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0, cache_roomnames TEXT, was_data_detected INTEGER DEFAULT 0, was_deduplicated INTEGER DEFAULT 0, is_audio_message INTEGER DEFAULT 0, is_played INTEGER DEFAULT 0, date_played INTEGER, item_type INTEGER DEFAULT 0, other_handle INTEGER DEFAULT 0, group_title TEXT, group_action_type INTEGER DEFAULT 0, share_status INTEGER DEFAULT 0, share_direction INTEGER DEFAULT 0, is_expirable INTEGER DEFAULT 0, expire_state INTEGER DEFAULT 0, message_action_type INTEGER DEFAULT 0, message_source INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, payload_data BLOB, expressive_send_style_id TEXT, associated_message_range_location INTEGER DEFAULT 0, associated_message_range_length INTEGER DEFAULT 0, time_expressive_send_played INTEGER, message_summary_info BLOB, ck_sync_state INTEGER DEFAULT 0, ck_record_id TEXT, ck_record_change_tag TEXT, destination_caller_id TEXT, is_corrupt INTEGER DEFAULT 0, reply_to_guid TEXT, sort_id INTEGER, is_spam INTEGER DEFAULT 0, has_unseen_mention INTEGER DEFAULT 0, thread_originator_guid TEXT, thread_originator_part TEXT, syndication_ranges TEXT, synced_syndication_ranges TEXT, was_delivered_quietly INTEGER DEFAULT 0, did_notify_recipient INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0, was_detonated INTEGER DEFAULT 0, part_count INTEGER, is_stewie INTEGER DEFAULT 0, is_sos INTEGER DEFAULT 0, is_critical INTEGER DEFAULT 0, bia_reference_id TEXT DEFAULT NULL, is_kt_verified INTEGER DEFAULT 0, fallback_hash TEXT DEFAULT NULL, associated_message_emoji TEXT DEFAULT NULL, is_pending_satellite_send INTEGER DEFAULT 0, needs_relay INTEGER DEFAULT 0, schedule_type INTEGER DEFAULT 0, schedule_state INTEGER DEFAULT 0, sent_or_received_off_grid INTEGER DEFAULT 0, date_recovered INTEGER DEFAULT 0);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER, state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT, service_name TEXT, room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0, last_addressed_handle TEXT, display_name TEXT, group_id TEXT, is_filtered INTEGER DEFAULT 0, successful_query INTEGER, engram_id TEXT, server_change_token TEXT, ck_sync_state INTEGER DEFAULT 0, original_group_id TEXT, last_read_message_timestamp INTEGER DEFAULT 0, cloudkit_record_id TEXT, last_addressed_sim_id TEXT, is_blackholed INTEGER DEFAULT 0, syndication_date INTEGER DEFAULT 0, syndication_type INTEGER DEFAULT 0, is_recovered INTEGER DEFAULT 0, is_deleting_incoming_messages INTEGER DEFAULT 0);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, created_date INTEGER DEFAULT 0, start_date INTEGER DEFAULT 0, filename TEXT, uti TEXT, mime_type TEXT, transfer_state INTEGER DEFAULT 0, is_outgoing INTEGER DEFAULT 0, user_info BLOB, transfer_name TEXT, total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0, sticker_user_info BLOB, attribution_info BLOB, hide_attachment INTEGER DEFAULT 0, ck_sync_state INTEGER DEFAULT 0, ck_server_change_token_blob BLOB, ck_record_id TEXT, original_guid TEXT UNIQUE NOT NULL, is_commsafety_sensitive INTEGER DEFAULT 0, emoji_image_content_identifier TEXT DEFAULT NULL, emoji_image_short_description TEXT DEFAULT NULL, preview_generation_state INTEGER DEFAULT 0);
CREATE TABLE chat_recoverable_message_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE, message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, delete_date INTEGER, ck_sync_state INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id), CHECK (delete_date != 0));
CREATE TABLE unsynced_removed_recoverable_messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, chat_guid TEXT NOT NULL, message_guid TEXT NOT NULL, part_index INTEGER);
CREATE TABLE recoverable_message_part (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE, message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, part_index INTEGER, delete_date INTEGER, part_text BLOB NOT NULL, ck_sync_state INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id, part_index), CHECK (delete_date != 0));
CREATE TABLE scheduled_messages_pending_cloudkit_delete (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, guid TEXT NOT NULL, recordID TEXT );
CREATE TABLE sqlite_stat1(tbl,idx,stat);
