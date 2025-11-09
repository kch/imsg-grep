#!/usr/bin/env ruby
# Core iMessage database processing - builds cached views with decoded messages, contacts, and attachments

require 'fileutils'
require 'sqlite3'
require 'parallel'
require 'etc'
require_relative 'keyed_archive'
require_relative 'attr_str'

module Timer
  def self.start
    @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @last_lap = @t0
    @total_time = 0.0
    @laps = []
  end

  def self.lap(msg)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lap_time = (now - @last_lap) * 1000
    @total_time += lap_time
    line = "%5.0fms / %5.0fms: #{msg}" % [lap_time, @total_time]
    puts line
    @laps << { msg: msg, time: lap_time, line: line, line_num: @laps.size }
    @last_lap = now
  end

  def self.finish
    max_lap_time = @laps.map { |lap| lap[:time] }.max
    longest_line = @laps.map { |lap| lap[:line].length }.max
    start_col = longest_line + 3
    @laps.reverse.each do |lap|
      pct = (lap[:time] / @total_time * 100).round(1)
      bar_length = (lap[:time] / max_lap_time * 20).round
      bar = "█" * bar_length + "░" * (20 - bar_length)
      padding = " " * [0, start_col - lap[:line].length].max
      print "\e[#{@laps.size - lap[:line_num]}A\r#{lap[:line]}#{padding}#{bar} #{pct}%\e[#{@laps.size - lap[:line_num]}B\r"
    end
    puts
  end
end

PARALLEL = true

CONTACTS_DB = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
MESSAGES_DB = Dir[File.expand_path("~/Library/Messages/chat.db")][0]
CACHE_DB    = File.expand_path("~/.cache/imsg-grep/chat.db")
FileUtils.mkdir_p File.dirname(CACHE_DB)
FileUtils.touch(CACHE_DB)

Timer.start

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
$db.create_function("unarchive_keyed", 1)      { |f, data| f.result = NSKeyedArchive.unarchive(data).to_json }
$db.create_function("unarchive_attributed", 1) { |f, data| f.result = AttributedStringExtractor.extract(data) }

Timer.lap "setup"

# table: contacts
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
Timer.lap "contacts table creation"

# table: handle_contacts
# maps message handles to contact IDs:
# handle_id  | "+14155551212"
# contact_id | 42
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
Timer.lap "handle contacts table creation"

# temp view: contact_details
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
Timer.lap "contact details table creation"


###
### messages cache ahaed
###

MESSAGES_EXCLUSION = <<~SQL
  (
    (associated_message_type IS NULL OR associated_message_type < 2000)                              -- # Exclude metadata/reaction messages
    AND (balloon_bundle_id IS NULL OR balloon_bundle_id != 'com.apple.DigitalTouchBalloonProvider')  -- # Digital touch lol; another check: substr(hex(payload_data), 1, 8) = '08081100'
  )
SQL

if PARALLEL
  # Check if messages_decoded table exists and build exclusion
  table_exists = !$db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='messages_decoded'").empty?
  exclusion_rules = "#{MESSAGES_EXCLUSION}#{table_exists ? " AND NOT EXISTS (SELECT 1 FROM messages_decoded md WHERE md.id = m.ROWID)" : ""}"

  # Get rows that need parallel processing
  payload_rows = $db.execute(<<~SQL)
    SELECT m.ROWID as id, m.payload_data
    FROM messages_db.message m
    WHERE m.payload_data IS NOT NULL AND #{exclusion_rules}
  SQL
  Timer.lap "payload query"

  text_rows = $db.execute(<<~SQL)
    SELECT m.ROWID as id, m.attributedBody
    FROM messages_db.message m
    WHERE m.attributedBody IS NOT NULL AND #{exclusion_rules}
  SQL
  Timer.lap "text query"

  SQLite3::ForkSafety.suppress_warnings!

  # Process payload rows in parallel
  payload_results = Parallel.map(payload_rows, in_processes: Etc.nprocessors - 1) do |id, data|
    [id, NSKeyedArchive.json(data)]
  end
  Timer.lap "payload processing (parallel) (#{payload_rows.size} items)"

  # Process text rows in parallel
  text_results = Parallel.map(text_rows, in_threads: Etc.nprocessors - 1) do |id, data|
    [id, AttributedStringExtractor.extract(data)]
  end
  Timer.lap "text processing (parallel) (#{text_rows.size} items)"

  # Create temp tables with results
  $db.execute "DROP TABLE IF EXISTS temp_payloads"
  $db.execute "CREATE TEMP TABLE temp_payloads (id INTEGER PRIMARY KEY, payload TEXT)"

  $db.execute "DROP TABLE IF EXISTS temp_texts"
  $db.execute "CREATE TEMP TABLE temp_texts (id INTEGER PRIMARY KEY, text_decoded TEXT)"

  $db.transaction do
    payload_results.each_slice(500) do |batch|
      placeholders = (["(?,?)"] * batch.size).join(",")
      params = batch.flatten
      $db.execute("INSERT INTO temp_payloads (id, payload) VALUES #{placeholders}", params)
    end

    text_results.each_slice(500) do |batch|
      placeholders = (["(?,?)"] * batch.size).join(",")
      params = batch.flatten
      $db.execute("INSERT INTO temp_texts (id, text_decoded) VALUES #{placeholders}", params)
    end
  end
  Timer.lap "temp tables creation"
end

MESSAGES_DECODED_QUERY = <<~SQL
  WITH chat_participants AS (
    SELECT
      chat_id,
      json_group_array(h.id) as participant_handles
    FROM messages_db.chat_handle_join chj
    JOIN messages_db.handle h ON chj.handle_id = h.ROWID
    GROUP BY chat_id
  ),
  message_participants AS (
    SELECT
      m.ROWID as message_id,
      IIF(m.destination_caller_id IS NOT NULL, json_insert(p.participant_handles, '$[#]', m.destination_caller_id), p.participant_handles) as participant_handles,
      IIF(m.is_from_me, m.destination_caller_id, h.id) as sender_handle
    FROM messages_db.message m
    LEFT JOIN messages_db.handle h ON m.handle_id = h.ROWID
    LEFT JOIN messages_db.chat_message_join cm ON m.ROWID = cm.message_id
    LEFT JOIN messages_db.chat c ON cm.chat_id = c.ROWID
    LEFT JOIN chat_participants p ON c.ROWID = p.chat_id
    WHERE #{MESSAGES_EXCLUSION}
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
    #{if PARALLEL
        "tt.text_decoded,
         tp.payload"
      else
        "IIF(m.attributedBody IS NOT NULL, unarchive_attributed(m.attributedBody), NULL) as text_decoded,
         IIF(m.payload_data IS NOT NULL, unarchive_keyed(payload_data), NULL) as payload"
      end}
  FROM messages_db.message m
  LEFT JOIN message_participants mp ON m.ROWID = mp.message_id
  #{if PARALLEL
      "LEFT JOIN temp_texts tt ON m.ROWID = tt.id
       LEFT JOIN temp_payloads tp ON m.ROWID = tp.id"
    end}
  WHERE #{MESSAGES_EXCLUSION}
SQL


$db.execute "CREATE TABLE IF NOT EXISTS messages_decoded AS #{MESSAGES_DECODED_QUERY}"
$db.execute "CREATE INDEX IF NOT EXISTS idx_messages_decoded_id ON messages_decoded(id)"
$db.execute "INSERT INTO messages_decoded #{MESSAGES_DECODED_QUERY} AND m.ROWID > (SELECT COALESCE(MAX(id), 0) FROM messages_decoded)"
Timer.lap "messages decoded table update"


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
Timer.lap "messages view creation"
Timer.finish
