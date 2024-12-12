#!/usr/bin/env ruby
require 'sqlite3'
require 'ffi'
require 'benchmark'
require_relative 'lib/keyed_archive'
require_relative 'lib/attr_str'

CONTACTS_DB = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
MESSAGES_DB = Dir[File.expand_path("~/Library/Messages/chat.db")][0]

db = SQLite3::Database.new(":memory:")
db.execute("ATTACH DATABASE '#{CONTACTS_DB}' AS contacts_db; PRAGMA contacts_db.readonly = ON")
db.execute("ATTACH DATABASE '#{MESSAGES_DB}' AS messages_db; PRAGMA messages_db.readonly = ON")

REGEX_CACHE = Hash.new { |h,k| h[k] = Regexp.new(k, Regexp::IGNORECASE) }
db.create_function("regexp", 2)               { |f, rx, text| f.result = REGEX_CACHE[rx].match?(text) ? 1 : 0 }
db.create_function("plusdigits", 1)           { |f, text| f.result = text.delete("^0-9+") }
db.create_function("unarchive_attributed", 1) { |f, text| f.result = NSAttributedString.unarchive text }
# db.create_function("describe_attributed", 1)  { |f, text| f.result = NSAttributedString.describe text }

time = Benchmark.measure do
db.execute <<-SQL
  CREATE TABLE contacts AS
  WITH emails AS (
    SELECT ZOWNER, json_group_array(ZADDRESS) as emails
    FROM contacts_db.ZABCDEMAILADDRESS
    GROUP BY ZOWNER
  ),
  phones AS (
    SELECT
      ZOWNER,
      json_group_array(ZFULLNUMBER) as numbers_fmt,
      json_group_array(plusdigits(ZFULLNUMBER)) as numbers
    FROM contacts_db.ZABCDPHONENUMBER
    GROUP BY ZOWNER
  )
  SELECT
    r.Z_PK as id,
    r.ZFIRSTNAME || ' ' || r.ZLASTNAME as name,
    COALESCE(e.emails, '[]')           as emails,
    COALESCE(p.numbers, '[]')          as numbers,
    COALESCE(p.numbers_fmt, '[]')      as numbers_fmt,
    json_object(
      'name',         r.ZFIRSTNAME || ' ' || r.ZLASTNAME,
      'emails',       json(COALESCE(e.emails, '[]')),
      'numbers',      json(COALESCE(p.numbers, '[]')),
      'numbers_fmt',  json(COALESCE(p.numbers_fmt, '[]'))
    ) as contact
  FROM contacts_db.ZABCDRECORD r
  LEFT JOIN emails e ON e.ZOWNER = r.Z_PK
  LEFT JOIN phones p ON p.ZOWNER = r.Z_PK
  WHERE r.ZFIRSTNAME IS NOT NULL
SQL
end
puts "\nContacts table creation took: #{time.real.round(3)}s"

time = Benchmark.measure do
db.execute <<-SQL
  CREATE TABLE contacts_by_handle AS
  WITH base AS (            -- First pass: try to match handles to contacts
    SELECT
      h.id      as handle,  -- Raw handle from messages
      c.contact as details  -- Full contact JSON if found
    FROM messages_db.handle h
    LEFT JOIN contacts c ON (
      EXISTS (SELECT 1 FROM json_each(c.numbers) WHERE h.id LIKE plusdigits(value)) OR
      EXISTS (SELECT 1 FROM json_each(c.emails) WHERE h.id = value)
    )
  )
  SELECT
    handle,                                     -- Original handle string
    CASE WHEN details IS NULL                   -- No contact found
    THEN json_object('handle', handle)          -- Just return {handle: id}
    ELSE json_set(details, '$.handle', handle)  -- Add handle to full contact
    END as contact
  FROM base
SQL
end
puts "Contacts by handle table creation took: #{time.real.round(3)}s"


time = Benchmark.measure do
db.execute <<-SQL
CREATE TABLE messages AS
WITH chat_participants AS (
  SELECT
    chat_id,
    json_group_array(
      (SELECT json(contact) FROM contacts_by_handle WHERE handle = h.id)
    ) as participants
  FROM messages_db.chat_handle_join chj
  JOIN messages_db.handle h ON chj.handle_id = h.ROWID
  GROUP BY chat_id
)
SELECT
  m.ROWID                                                   as id,
  datetime((m.date / 1000000000) + 978307200, 'unixepoch', 'utc') as utc_date,
  datetime((m.date / 1000000000) + 978307200, 'unixepoch', 'localtime') as local_date,
  (SELECT contact FROM contacts_by_handle WHERE handle = h.id) as sender,
  c.style                                                   as chat_style,
  c.display_name                                            as chat_name,
  p.participants                                            as participants,
  m.text                                                    as text,
  unarchive_attributed(m.attributedBody)                     as body,
  m.cache_has_attachments                                   as has_attachments,
  m.is_from_me,
  m.associated_message_type,
  m.attributedBody
FROM messages_db.message m
LEFT JOIN messages_db.handle h             ON m.handle_id = h.ROWID
LEFT JOIN messages_db.chat_message_join cm ON m.ROWID     = cm.message_id
LEFT JOIN messages_db.chat c               ON cm.chat_id  = c.ROWID
LEFT JOIN chat_participants p              ON c.ROWID     = p.chat_id
WHERE (associated_message_type IS NULL OR associated_message_type < 2000) -- Exclude metadata/reaction messages
  AND utc_date > datetime('now', '-7 days')
SQL
end
puts "Messages table creation took: #{time.real.round(3)}s"

def print_query(db, sql)
  puts "\n#{'=' * 80}"
  cols = []

  db.execute2(sql) do |row|
    if cols.empty?
      cols = row
      next
    end

    row.each_with_index do |val, i|
      val = val.nil? ? "NULL" : val.to_s
      if val.include?("\n")
        puts "\n#{cols[i]}:"
        puts val.gsub(/^/, "  ")
      else
        puts "#{cols[i].ljust(15)}: #{val}"
      end
    end
    puts "-" * 80
  end
end

time = Benchmark.measure do
  print_query(db, <<~SQL)
    SELECT
      utc_date,
      json_extract(sender, '$.name') as sender_name,
      -- chat_name,
      -- coalesce(text, body) as text,
      text,
      body,
      -- json_pretty(participants) as participants
      '' as ''
    FROM messages
    -- A (associated_message_type IS NULL OR associated_message_type < 2000) -- Exclude metadata/reaction messages
    -- AND (text IS  NULL AND attributedBody IS  NULL)
      -- AND has_attachments = 0
      -- AND (body IS NOT NULL AND body REGEXP 'https?://(www.)?youtu')
      -- AND (body IS NOT NULL AND body REGEXP 'https?://')
    ORDER BY utc_date DESC
    LIMIT 20
  SQL
end

puts "\nQuery took: #{time.real.round(3)}s"


# db.execute("CREATE INDEX idx_contacts_numbers          ON contacts(numbers)")
# db.execute("CREATE INDEX idx_contacts_emails           ON contacts(emails)")
# db.execute("CREATE INDEX idx_contacts_by_handle_handle ON contacts_by_handle(handle)")
# db.execute("CREATE INDEX idx_messages_utc_date         ON messages(utc_date DESC)")
# db.execute("CREATE INDEX idx_messages_chat             ON messages(chat_name)")
