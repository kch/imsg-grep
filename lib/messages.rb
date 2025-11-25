#!/usr/bin/env ruby
# frozen_string_literal: true
# Core iMessage database processing - builds views with decoded messages, expanded contacts, a cache

require 'fileutils'
require 'sqlite3'
require_relative 'keyed_archive'
require_relative 'attr_str'
require_relative 'print_query'

################################################################################
### DB Setup ###################################################################
################################################################################

addy_db  = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
imsg_db  = File.expand_path("~/Library/Messages/chat.db")
CACHE_DB = File.expand_path("~/.cache/imsg-grep/cache.db")
FileUtils.mkdir_p File.dirname(CACHE_DB)
FileUtils.touch(CACHE_DB)

[addy_db, imsg_db, CACHE_DB].each do |db|
  raise "Database not found: #{db}" unless File.exist?(db)
  raise "Database not readable: #{db}" unless File.readable?(db)
end

$db = SQLite3::Database.new(":memory:")
$db.execute "ATTACH DATABASE '#{addy_db}' AS _addy"
$db.execute "ATTACH DATABASE '#{imsg_db}' AS _imsg"
$db.execute "ATTACH DATABASE '#{CACHE_DB}' AS _cache"

def reset_cache = FileUtils.rm_f(CACHE_DB)

def $db.select_hashes(sql) = prepare(sql).execute.enum_for(:each_hash).map{ it.transform_keys(&:to_sym) }
def $db.ƒ(f, &) = define_function_with_flags(f.to_s, SQLite3::Constants::TextRep::UTF8 | SQLite3::Constants::TextRep::DETERMINISTIC, &)
REGEX_CACHE = Hash.new { |h,src| h[src] = Regexp.new(src) }
$db.ƒ(:regexp)           { |rx, text| REGEX_CACHE[rx].match?(text) ? 1 : 0 }
$db.ƒ(:unarchive_keyed)  { |data| NSKeyedArchive.unarchive(data).to_json if data }
$db.ƒ(:unarchive_string) { |data| AttributedStringExtractor.extract(data) if data }


################################################################################
### Contacts setup #############################################################
################################################################################

# Contacts table with:
# - contact_id (in address book table)
# - handle_id (in chat.db)
# - handle (email or phone number)
# - is_me
# one row per handle. only handles that exist in chat.db
# can map a contact to handle once i match the contact
$db.ƒ(:normalize_phone) { |text| text =~ /[^\p{Punct}\p{Space}\d+]/ ? text : text.delete("^0-9+") } # remove punctuation from normal phones but keep weird phones intact
$db.execute <<~SQL
  CREATE TEMP TABLE contacts AS
  WITH handles AS (
    SELECT
      ZOWNER   as contact_id,
      ZADDRESS as handle
    FROM _addy.ZABCDEMAILADDRESS
    UNION ALL
    SELECT
      ZOWNER as contact_id,
      normalize_phone(ZFULLNUMBER) as handle
    FROM _addy.ZABCDPHONENUMBER
  )
  SELECT DISTINCT
    r.Z_PK   as contact_id,
    ch.ROWID as handle_id,
    h.handle as handle,
    (r.ZCONTAINERWHERECONTACTISME IS NOT NULL) as is_me
  FROM _addy.ZABCDRECORD r
  JOIN handles h ON h.contact_id = r.Z_PK
  JOIN _imsg.handle ch ON ch.id = h.handle -- only take handles that exist in _imsg
  SQL

# # older messages from me may have discontinued numbers not in address book
# # re-add those as handles for my contact
# # i'm not sure this is gonna be needed anymore, but leaving here for now
# # these don't get a handle_id (if i've messaged myself, they get from previous query)
# $db.execute "CREATE UNIQUE INDEX idx_contacts_unique ON contacts (handle, handle_id, contact_id, is_me)"
# $db.execute <<~SQL
#   INSERT OR IGNORE INTO contacts (contact_id, handle, is_me)
#   SELECT DISTINCT
#     (SELECT contact_id FROM contacts WHERE is_me = 1 LIMIT 1)
#                           as contact_id,
#     destination_caller_id as handle,
#     1                     as is_me
#   FROM _imsg.message
#   WHERE is_from_me = 1
#     AND destination_caller_id IS NOT NULL
#     AND destination_caller_id NOT IN (SELECT handle FROM contacts)
#     AND EXISTS (SELECT 1 FROM contacts WHERE is_me = 1);
#   SQL

$db.ƒ(:computed_name) do |first, maiden, middle, last, nick, org|
  names = [first, maiden, middle, last].compact.reject(&:empty?)
  names << "(#{nick})" if nick && !nick.empty?
  names.empty? ? org.to_s : names.join(" ")
end

$db.execute <<~SQL
  CREATE TEMP TABLE handle_groups AS
  WITH computed AS (
    SELECT
      c.handle_id,
      r.Z_PK as contact_id,
      (r.zcontainerwherecontactisme IS NOT NULL) as is_me,
      computed_name(r.zfirstname, r.zmaidenname, r.zmiddlename, r.zlastname, r.znickname, r.zorganization) as name
    FROM _addy.zabcdrecord r
    JOIN contacts c ON c.contact_id = r.Z_PK                  -- get all contact->handle mappings with computed names
  ),
  searchables AS (
    SELECT handle_id, c2.handle as term                       -- flatten: handle_id -> each handle string
    FROM contacts c2
    WHERE c2.handle_id IN (SELECT handle_id FROM computed)    -- only for handles that have contacts
    UNION ALL
    SELECT handle_id, name as term                            -- flatten: handle_id -> each computed name
    FROM computed
  )
  SELECT
    c.handle_id,
    json_group_array(c.contact_id) as contact_ids,            -- collect all contact_ids as JSON array
    MAX(c.is_me) as is_me,                                    -- true if any contact entry is me
    (SELECT json_group_array(DISTINCT term)                   -- collect all searchable terms per handle
     FROM searchables s
     WHERE s.handle_id = c.handle_id) as searchable,          -- result: ["handle1","handle2","Name"]
    MIN(c.name) as name                                       -- pick first computed name when duplicates
  FROM computed c
  GROUP BY c.handle_id                                        -- collapse duplicate contact entries per handle
  UNION
  -- add handles without any contact entry
  SELECT
    h.ROWID as handle_id,
    null,
    null,
    json_array(h.id) as searchable,                           -- only handle string searchable
    h.id as name                                              -- handle string as display name
  FROM _imsg.handle h
  WHERE h.ROWID NOT IN (SELECT handle_id FROM contacts)      -- exclude handles already processed above
  ORDER BY name
  SQL


################################################################################
### Caching ####################################################################
################################################################################

$db.execute_batch <<~SQL
  CREATE TABLE IF NOT EXISTS _cache.texts    ( guid TEXT PRIMARY KEY, value TEXT) STRICT;
  CREATE TABLE IF NOT EXISTS _cache.payloads ( guid TEXT PRIMARY KEY, value TEXT) STRICT;
  CREATE TABLE IF NOT EXISTS _cache.links    ( guid TEXT PRIMARY KEY, value TEXT) STRICT;
SQL

CACHE = { texts: {}, payload_data: {}, payloads: {}, links: {} }

def cache_text(guid, attr) = CACHE[:texts][guid] ||= AttributedStringExtractor.extract(attr)
def cache_payload(guid, data)
  CACHE[:payload_data][guid] = NSKeyedArchive.unarchive(data) unless CACHE[:payload_data].key? guid
  CACHE[:payloads][guid] ||= CACHE[:payload_data][guid]&.to_json
end

$db.ƒ(:cache_text)         { |guid, attr| cache_text(guid, attr) }
$db.ƒ(:cache_payload_json) { |guid, data| cache_payload(guid, data) }

end_mark = '\uFFFC\p{Space}'  # \uFFFC is the attributed string object marker
noallow = Regexp.escape('\|^"<>{}[]') + end_mark
RX_URL = %r(\bhttps?://[^#{noallow}]{4,}?(?=["':;,\.\)]{0,3}(?:[#{end_mark}]|$)))i
$db.ƒ(:cache_link_url) do |guid, data, text, attr|
  next CACHE[:links][guid] if CACHE[:links][guid]
  text = cache_text(guid, attr)
  cache_payload(guid, data) # force CACHE[:payload_data] to be set
  payload = CACHE[:payload_data][guid]

  CACHE[:links][guid] = \
    payload&.dig("richLinkMetadata", "URL") ||
    payload&.dig("richLinkMetadata", "originalURL") ||
    (text && text[RX_URL])
end

at_exit do
  # next # disable saving cache
  next if CACHE.values.all?(&:empty?)
  quote = ->v{ v == nil ? "NULL" : "'#{SQLite3::Database.quote v}'" }
  batch_size = 50_000
  $db.transaction do
    CACHE.except(:payload_data).each do |table, rows|
      rows.each_slice(batch_size) do |rows|
        values = rows.inject(String.new){|s, (guid, v)| s << "('#{guid}', #{quote[v]})," }.chop!
        $db.execute <<~SQL
          INSERT INTO _cache.#{table} (guid, value) VALUES #{values}
          ON CONFLICT(guid) DO UPDATE SET value = COALESCE(excluded.value, _cache.#{table}.value)
          SQL
      end
    end
  end
end

################################################################################
### Main message view ##########################################################
################################################################################

APPLE_EPOCH = 978307200
UNIX_TIME = "((m.date / 1000000000) + #{APPLE_EPOCH})"
$db.execute <<~SQL
  CREATE TEMP VIEW message_view AS
  WITH chat_members AS (
    SELECT
      c.ROWID as chat_id,
      (COUNT(DISTINCT hg.handle_id) > 1) as is_group_chat,
      json_group_array(DISTINCT hg.name) as member_names,
      json_group_array(DISTINCT term.value) as members_searchable
    FROM _imsg.chat c
    JOIN _imsg.chat_handle_join chj ON c.ROWID = chj.chat_id
    LEFT JOIN handle_groups hg ON chj.handle_id = hg.handle_id
    CROSS JOIN json_each(hg.searchable) as term  -- flatten each member's searchable array
    GROUP BY c.ROWID
  ),
  computed AS (
    SELECT
      m.ROWID,
      COALESCE(m.text, ct.value, IIF(ct.guid IS NULL AND m.attributedBody IS NOT NULL, cache_text(m.guid, m.attributedBody)))
        as text,
      COALESCE(cp.value, IIF(cp.guid IS NULL AND m.payload_data IS NOT NULL, cache_payload_json(m.guid, m.payload_data)))
        as payload_json,
      COALESCE(cl.value, IIF(cl.guid IS NULL AND (
          m.payload_data IS NOT NULL OR instr(m.text, 'http') OR instr(m.attributedBody, 'http')
        ), cache_link_url(m.guid, m.payload_data, m.text, m.attributedBody)))
        as link_url
    FROM message m
    LEFT JOIN _cache.texts    ct ON m.guid = ct.guid
    LEFT JOIN _cache.payloads cp ON m.guid = cp.guid
    LEFT JOIN _cache.links    cl ON m.guid = cl.guid
  )
  SELECT
    m.ROWID                                                             as message_id,
    m.guid,
    m.associated_message_type,
    m.service,
    m.cache_has_attachments                                             as has_attachments,
    mc.text,
    mc.payload_json,
    c.display_name                                                      as chat_name,
    #{UNIX_TIME}                                                        as unix_time,
    strftime('%Y-%m-%d', #{UNIX_TIME}, 'unixepoch')                     as utc_date,
    strftime('%Y-%m-%d', #{UNIX_TIME}, 'unixepoch', 'localtime')        as local_date,
    datetime(#{UNIX_TIME}, 'unixepoch')                                 as utc_time,
    datetime(#{UNIX_TIME}, 'unixepoch', 'localtime')                    as local_time,
    m.is_from_me                                                        as is_from_me,
    m.payload_data                                                      as payload_data,
    mc.link_url,
    cm.is_group_chat,
    CASE
    WHEN hg_recipient.name IS NOT NULL
    THEN json_array(hg_recipient.name)
    WHEN hg_sender.searchable IS NULL OR hg_sender.searchable != cm.members_searchable
    THEN cm.member_names
    ELSE NULL
    END                                                                 as recipient_names,
    CASE
    WHEN hg_recipient.searchable IS NOT NULL
    THEN hg_recipient.searchable
    WHEN hg_sender.searchable IS NULL OR hg_sender.searchable != cm.members_searchable
    THEN cm.members_searchable
    ELSE NULL
    END                                                                 as recipients_searchable,
    hg_sender.name                                                      as sender_name,
    hg_recipient.name                                                   as recipient_name,
    COALESCE(cm.member_names, json_array())                             as member_names,         -- all chat members
    hg_sender.searchable                                                as sender_searchable,    -- for optional filtering
    hg_recipient.searchable                                             as recipient_searchable, -- for optional filtering
    cm.members_searchable                                               as members_searchable    -- for optional filtering
  FROM _imsg.message m
  JOIN computed mc                      ON m.ROWID = mc.ROWID
  LEFT JOIN _imsg.chat_message_join cmj ON m.ROWID = cmj.message_id
  LEFT JOIN _imsg.chat c                ON cmj.chat_id = c.ROWID
  LEFT JOIN handle_groups hg_sender     ON m.handle_id = hg_sender.handle_id    AND m.is_from_me = 0
  LEFT JOIN handle_groups hg_recipient  ON m.handle_id = hg_recipient.handle_id AND m.is_from_me = 1
  LEFT JOIN chat_members cm             ON c.ROWID = cm.chat_id
  WHERE
  ((associated_message_type IS NULL OR associated_message_type < 1000)                               -- Exclude associated reaction messages 1000: stickers, 20xx: reactions; 30xx: remove reactions
    AND (balloon_bundle_id IS NULL OR balloon_bundle_id != 'com.apple.DigitalTouchBalloonProvider')  -- Exclude Digital touch lol
  )
  SQL
