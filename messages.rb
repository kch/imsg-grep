#!/usr/bin/env ruby
require 'fileutils'
require 'sqlite3'
require 'json'
require 'ffi'
require 'benchmark'
require_relative 'lib/keyed_archive'
require_relative 'lib/attr_str'

def print_query(db, sql)
  puts "\n#{'=' * 80}"
  cols = []

  db.execute2(sql) do |row|
    if cols.empty?
      cols = row
      next
    end
    width = cols.map(&:length).max

    row.each_with_index do |val, i|
      val = val.nil? ? "NULL" : val.to_s
      puts "#{cols[i].ljust(width, ' ')} : #{val.gsub("\n", "\n   " + ' ' * width)}"
    end
    puts "-" * 80
  end
end


CONTACTS_DB = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
MESSAGES_DB = Dir[File.expand_path("~/Library/Messages/chat.db")][0]
CACHE_DB    = File.expand_path("~/.cache/imsg-grep/chat.db")
FileUtils.mkdir_p File.dirname(CACHE_DB)

db = SQLite3::Database.new(CACHE_DB, { encoding: "utf-8" })
db.execute("ATTACH DATABASE '#{CONTACTS_DB}' AS contacts_db; PRAGMA contacts_db.readonly = ON")
db.execute("ATTACH DATABASE '#{MESSAGES_DB}' AS messages_db; PRAGMA messages_db.readonly = ON")

REGEX_CACHE = Hash.new { |h,k| h[k] = Regexp.new(k, Regexp::IGNORECASE) }
db.create_function("regexp", 2)               { |f, rx, text| f.result = REGEX_CACHE[rx].match?(text) ? 1 : 0 }
db.create_function("plusdigits", 1)           { |f, text| f.result = text.delete("^0-9+") }
db.create_function("unarchive_keyed", 1)      { |f, text| f.result = NSKeyedArchive.unarchive(text).to_json }
db.create_function("unarchive_attributed", 1) { |f, text| f.result = NSAttributedString.unarchive text }
# db.create_function("describe_attributed", 1)  { |f, text| f.result = NSAttributedString.describe text }

# all contacts, like:
# id      | 42
# name    | "John Smith"
# emails  | ["john@gmail.com", "john@work.com"]
# numbers | ["+14155551212", "+14155551213"]
db.execute "DROP TABLE IF EXISTS contacts;"
db.execute <<-SQL
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
db.execute "DROP TABLE IF EXISTS handle_contacts;"
db.execute <<-SQL
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
db.execute "CREATE INDEX idx_handle_contacts ON handle_contacts(handle_id)"

# maps handles to full contact info as json
# handle   | "+14155551212"
# contact  | { "name":    "John Smith",
#          |   "emails":  ["john@gmail.com", "john@work.com"],
#          |   "numbers": ["+14155551212", "+14155551213"] }
db.execute <<~SQL
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
db.execute <<~SQL
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

MESSAGES_QUERY = <<~SQL
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
    IIF(m.is_from_me, m.destination_caller_id, h.id) as sender_handle,
    datetime((m.date / 1000000000) + 978307200, 'unixepoch') as utc_time,
    c.style as chat_style,
    c.display_name as chat_name,
    CASE WHEN m.destination_caller_id IS NOT NULL
      THEN json_insert(p.participant_handles, '$[#]', m.destination_caller_id)
      ELSE p.participant_handles
    END as participant_handles,
    m.text                                 as text,
    unarchive_attributed(m.attributedBody) as body,
    m.cache_has_attachments                as has_attachments,
    m.is_from_me,
    m.associated_message_type,
    m.attributedBody
  FROM messages_db.message m
  LEFT JOIN messages_db.handle h             ON m.handle_id = h.ROWID
  LEFT JOIN messages_db.chat_message_join cm ON m.ROWID     = cm.message_id
  LEFT JOIN messages_db.chat c               ON cm.chat_id  = c.ROWID
  LEFT JOIN chat_participants p              ON c.ROWID     = p.chat_id
  WHERE (associated_message_type IS NULL OR associated_message_type < 2000) -- Exclude metadata/reaction messages
SQL

time = Benchmark.measure do
  db.execute "CREATE TABLE IF NOT EXISTS messages AS #{MESSAGES_QUERY}"
  db.execute "INSERT INTO messages #{MESSAGES_QUERY} AND m.ROWID > (SELECT MAX(id) FROM messages)"
end

puts "Messages table creation took: #{time.real.round(3)}s"


time = Benchmark.measure do
  print_query(db, <<~SQL)
    SELECT
      datetime(utc_time, 'localtime') as local_time,
      is_from_me,
      (SELECT COALESCE(json_extract(contact, '$.name'), sender_handle)
       FROM contact_details WHERE handle = sender_handle) as sender_name,
      chat_style,
      chat_name,
      coalesce(text, body) as computed_text,
      -- text,
      -- body,
      -- participants,
      -- json_pretty(participants) as participants,
      (
        SELECT json_group_array(
          COALESCE(
            (SELECT json_extract(contact, '$.name') FROM contact_details WHERE handle = value),
            value
          )
        )
        FROM json_each(participant_handles)
      ) as participant_names,
      '' as ''
    FROM messages
    WHERE 1=1

      AND (computed_text IS NOT NULL AND computed_text REGEXP 'https?://(www.)?youtu')
    -- AND (text IS  NULL AND attributedBody IS  NULL)
      -- AND has_attachments = 0
      -- AND (body IS NOT NULL AND body REGEXP 'https?://')
      -- AND sender_handle IN (SELECT value FROM contact_lookup, json_each(handles) WHERE searchable REGEXP 'reg|and')
      AND  EXISTS (
        SELECT 1 FROM json_each(participant_handles) p
        WHERE p.value IN (
          SELECT value FROM contact_lookup c, json_each(c.handles) WHERE c.searchable REGEXP 'reg|and'))
    ORDER BY utc_time DESC
    LIMIT 10
  SQL
end

puts "\nQuery took: #{time.real.round(3)}s"


# db.execute("CREATE INDEX idx_contacts_numbers          ON contacts(numbers)")
# db.execute("CREATE INDEX idx_contacts_emails           ON contacts(emails)")
# db.execute("CREATE INDEX idx_contacts_by_handle_handle ON contacts_by_handle(handle)")
# db.execute("CREATE INDEX idx_messages_utc_date         ON messages(utc_date DESC)")
# db.execute("CREATE INDEX idx_messages_chat             ON messages(chat_name)")
