#!/usr/bin/env ruby
require 'fileutils'
require 'sqlite3'
require 'json'
require 'ffi'
require 'benchmark'
require_relative 'keyed_archive'
require_relative 'attr_str'
require 'parallel'
require 'etc'

CONTACTS_DB = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
MESSAGES_DB = Dir[File.expand_path("~/Library/Messages/chat.db")][0]
CACHE_DB    = File.expand_path("~/.cache/imsg-grep/chat.db")
FileUtils.mkdir_p File.dirname(CACHE_DB)
FileUtils.touch(CACHE_DB)

[CONTACTS_DB, MESSAGES_DB, CACHE_DB].each do |db|
  raise "Database not found: #{db}" unless File.exist?(db)
  raise "Database not readable: #{db}" unless File.readable?(db)
end

$db = SQLite3::Database.new(CACHE_DB, { encoding: "utf-8" })
$db.execute("ATTACH DATABASE '#{CONTACTS_DB}' AS contacts_db; PRAGMA contacts_db.readonly = ON")
$db.execute("ATTACH DATABASE '#{MESSAGES_DB}' AS messages_db; PRAGMA messages_db.readonly = ON")

REGEX_CACHE = Hash.new { |h,k| h[k] = Regexp.new(k, Regexp::IGNORECASE) }
$db.create_function("regexp", 2)               { |f, rx, text| f.result = REGEX_CACHE[rx].match?(text) ? 1 : 0 }
$db.create_function("plusdigits", 1)           { |f, text| f.result = text.delete("^0-9+") }
$db.create_function("unarchive_keyed", 1)      { |f, text| f.result = NSKeyedArchive.unarchive(text).to_json }
$db.create_function("unarchive_attributed", 1) { |f, text| f.result = NSAttributedString.unarchive text }

# all contacts, like:
# id      | 42
# name    | "John Smith"
# emails  | ["john@gmail.com", "john@work.com"]
# numbers | ["+14155551212", "+14155551213"]
$db.execute "DROP TABLE IF EXISTS contacts;"
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
    p.numbers as numbers
  FROM contacts_db.ZABCDRECORD r
  LEFT JOIN emails e ON e.ZOWNER = r.Z_PK
  LEFT JOIN phones p ON p.ZOWNER = r.Z_PK;
SQL

# maps message handles to contact IDs:
# handle_id | "+14155551212"
# contact_id| 42
$db.execute "DROP TABLE IF EXISTS handle_contacts;"
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
    h.handle as handle_id,
    c.id as contact_id
  FROM all_handles h
  JOIN contacts c ON (
    EXISTS (SELECT 1 FROM json_each(c.numbers) WHERE h.handle = value) OR
    EXISTS (SELECT 1 FROM json_each(c.emails) WHERE h.handle = value)
  );
SQL
$db.execute "CREATE INDEX idx_handle_contacts ON handle_contacts(handle_id)"

# maps handles to full contact info as json
# handle   | "+14155551212"
# contact  | { "name":    "John Smith",
#          |   "emails":  ["john@gmail.com", "john@work.com"],
#          |   "numbers": ["+14155551212", "+14155551213"] }
$db.execute <<~SQL
  CREATE TEMP VIEW contact_details AS
  SELECT
    h.handle_id as handle,
    json_object(
      'name',    c.name,
      'emails',  json(COALESCE(c.emails, '[]')),
      'numbers', json(COALESCE(c.numbers, '[]'))
    ) as contact
  FROM handle_contacts h
  JOIN contacts c ON c.id = h.contact_id;
SQL

# searchable contact info with all their handles. match on searchable, use handles to query msgs
# contact_id | 42
# handles    | ["+14155551212", "+14155551213"]
# searchable | ["John Smith", "john@gmail.com", "john@work.com", "+14155551212", "+14155551213"]
# details    | { "name": "John Smith", "emails": ["john@gmail.com", "john@work.com"], "numbers": ["+14155551212", "+14155551213"] }
$db.execute <<~SQL
  CREATE TEMP VIEW contact_lookup AS
  SELECT
    c.id as contact_id,
    json_group_array(h.handle_id) as handles,
    (SELECT json_group_array(value) FROM (
      SELECT c.name as value                UNION ALL
      SELECT value FROM json_each(c.emails) UNION ALL
      SELECT value FROM json_each(c.numbers)
    )) as searchable,
    (SELECT contact FROM contact_details WHERE handle = h.handle_id) as details
  FROM contacts c
  JOIN handle_contacts h ON h.contact_id = c.id
  GROUP BY c.id;
SQL

###

MESSAGES_EXCLUSION = <<~SQL
  (
    (associated_message_type IS NULL OR associated_message_type < 2000)  -- # Exclude metadata/reaction messages
    AND (balloon_bundle_id != 'com.apple.DigitalTouchBalloonProvider')   -- # Digital touch lol; another check: substr(hex(payload_data), 1, 8) = '08081100'
  )
SQL

MESSAGES_DECODED_QUERY = <<~SQL
  WITH chat_participants AS (
    SELECT
      chat_id,
      json_group_array(h.id) as participant_handles
    FROM messages_db.chat_handle_join chj
    JOIN messages_db.handle h ON chj.handle_id = h.ROWID
    GROUP BY chat_id
  )
  SELECT
    m.ROWID as id,
    m.guid,
    IIF(m.is_from_me, m.destination_caller_id, h.id) as sender_handle,
    IIF(m.destination_caller_id IS NOT NULL, json_insert(p.participant_handles, '$[#]', m.destination_caller_id), p.participant_handles) as participant_handles,
    (SELECT json_group_array(json(cl.details))
     FROM contact_lookup cl, json_each(p.participant_handles) ph
     WHERE json_extract(cl.handles, '$') LIKE '%' || ph.value || '%') as participant_details,
    (SELECT cd.contact
     FROM contact_details cd
     WHERE cd.handle = IIF(m.is_from_me, m.destination_caller_id, h.id)) as sender_details,
    IIF(m.attributedBody IS NOT NULL, unarchive_attributed(m.attributedBody), NULL) as text_decoded,
    -- IIF(m.payload_data IS NOT NULL, unarchive_keyed(payload_data), NULL) as payload,
    NULL as payload
  FROM messages_db.message m
  LEFT JOIN messages_db.handle h             ON m.handle_id = h.ROWID
  LEFT JOIN messages_db.chat_message_join cm ON m.ROWID     = cm.message_id
  LEFT JOIN messages_db.chat c               ON cm.chat_id  = c.ROWID
  LEFT JOIN chat_participants p              ON c.ROWID     = p.chat_id
  WHERE #{MESSAGES_EXCLUSION}
SQL

time = Benchmark.measure do
  $db.execute "CREATE TABLE IF NOT EXISTS messages_decoded AS #{MESSAGES_DECODED_QUERY}"
  $db.execute "INSERT INTO messages_decoded #{MESSAGES_DECODED_QUERY} AND m.ROWID > (SELECT COALESCE(MAX(id), 0) FROM messages_decoded)"
end
puts "Messages decoded table update took: #{time.real.round(3)}s"


payload_rows = $db.execute(<<~SQL)
  SELECT md.id, m.payload_data
  FROM messages_decoded md
  JOIN messages_db.message m ON md.id = m.ROWID
  WHERE m.payload_data IS NOT NULL AND md.payload IS NULL
SQL


SQLite3::ForkSafety.suppress_warnings!

# Split rows for concurrent processing
payload_results = nil
payload_time = Benchmark.measure do
  # payload_results = payload_rows.map do |row|
  payload_results = Parallel.map(payload_rows, in_processes: Etc.nprocessors - 1) do |id, data|
    [id, NSKeyedArchive.json(data)]
  end
end

# Bulk update decoded results in batches
db_time = Benchmark.measure do
  $db.transaction do
    payload_results.each_slice(500) do |batch|
      ids    = batch.map { |id, _| id }
      cases  = batch.map { |id, _| "WHEN #{id} THEN ?" }.join(" ")
      params = batch.map { |_, payload| payload }

      $db.execute(<<~SQL, params)
        UPDATE messages_decoded
        SET    payload = CASE id #{cases} END
        WHERE  id IN (#{ids.join(",")})
      SQL
    end
  end
end

puts "Payload processing took: #{payload_time.real.round(3)}s (#{payload_rows.size} items)"
puts "Database update took: #{db_time.real.round(3)}s (#{payload_results.size} records)"


MESSAGES_QUERY = <<~SQL
  SELECT
    m.ROWID as id,
    d.guid,
    d.sender_handle,
    datetime((m.date / 1000000000) + 978307200, 'unixepoch') as utc_time,
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
