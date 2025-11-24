#!/usr/bin/env ruby

require 'fileutils'
require 'sqlite3'
require_relative '../../lib/attr_str'
require_relative '../../lib/keyed_archive'
require_relative '../../lib/print_query'

def print_table(...) = Print.table(...)

addy_db = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
db = SQLite3::Database.new File.expand_path "~/Library/Messages/chat.db"
db.execute "PRAGMA query_only = ON"
db.execute "ATTACH DATABASE '#{addy_db}' AS _addy"
def db.ƒ(f, &) = define_function_with_flags(f.to_s, SQLite3::Constants::TextRep::UTF8 | SQLite3::Constants::TextRep::DETERMINISTIC, &)
db.ƒ(:normalize_phone)  { |text| text =~ /[^\p{Punct}\p{Space}\d+]/ ? text : text.delete("^0-9+") } # remove punctuation from normal phones but keep weird phones intact
db.ƒ(:unarchive_keyed)  { |data| NSKeyedArchive.unarchive(data).to_json if data }
db.ƒ(:unarchive_string) { |data| AttributedStringExtractor.extract(data) if data }



# Q: chat members, from messages handles; who sends?
# A: multiple handles per person depending on which sent msg with
print_table db.execute2 <<~SQL, 142, 1 # by chat ids
  SELECT DISTINCT c.ROWID as chat_id, h.ROWID as handle_id, h.id AS handle, m.destination_caller_id
  FROM chat c
  JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
  JOIN message m ON cmj.message_id = m.ROWID
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  WHERE c.ROWID IN (?, ?)
  SQL


# Q: messages from me, wihout a chat; who is recipient?
# A it's handle.id; but only SMS/RCS. unimportant
print_table db.execute2 <<~SQL
  SELECT m.ROWID, h.id AS handle, m.destination_caller_id, m.is_from_me as 'me?', m.service,
    coalesce(m.text, unarchive_string(m.attributedBody)) as text_decoded
  FROM message m
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
  -- WHERE cmj.chat_id IS NULL
  WHERE is_from_me = 1 AND cmj.chat_id IS NULL
  ORDER BY m.date DESC
  LIMIT 100
  SQL


exit


# no messages from me without a handle.id
# except for one RCS message which is ads so i don't care
# this confirms can rely on handle.id as the recipient of the message
print_table db.execute2 <<~SQL
  SELECT m.ROWID, h.id AS handle, m.is_from_me, c.chat_identifier,
    coalesce(m.text, unarchive_string(m.attributedBody)) as text_decoded
  FROM message m
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
  LEFT JOIN chat c ON cmj.chat_id = c.ROWID
  WHERE is_from_me = 0 and h.id is null
    AND NOT m.service = 'RCS'
  ORDER BY m.date DESC
  LIMIT 100
  SQL


exit

# chat members from chat handles
# only one handle per person
print_table db.execute2 <<~SQL,1 #6
  SELECT DISTINCT h.ROWID, h.id AS handle, m.destination_caller_id
  FROM chat c
  LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
  LEFT JOIN handle h ON chj.handle_id = h.ROWID
  LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
  LEFT JOIN message m ON cmj.message_id = m.ROWID
  WHERE c.ROWID = ?
    LIMIT 1001
  SQL

# chat members, from messages handles
# multiple handles per person depending on which sent msg with
print_table db.execute2 <<~SQL,1 #6
  SELECT DISTINCT h.ROWID, h.id AS handle, m.destination_caller_id
  FROM chat c
  JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
  JOIN message m ON cmj.message_id = m.ROWID
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  WHERE c.ROWID = ?
  SQL


### Reviewed:

# Q: messages with handle_id = 0, must be from me?
# A: yes except for one RCS, which meh
print_table db.execute2 <<~SQL
  SELECT m.ROWID, m.handle_id, h.id AS handle,                   -- message info + handle
  m.destination_caller_id, m.is_from_me as 'me?',
  m.service,
    coalesce(m.text, unarchive_string(m.attributedBody)) as text_decoded
  FROM message m
  LEFT JOIN handle h ON m.handle_id = h.ROWID                    -- join handles (will be null for handle_id=0)
  WHERE m.handle_id = 0                                          -- only messages with no handle
  -- and m.is_from_me = 0
  SQL

# Q: from me, no dest id?
# A: none
print_table db.execute2 <<~SQL
  SELECT m.ROWID, m.handle_id, h.id AS handle,
    m.destination_caller_id, m.is_from_me as 'me?',
    m.service,
    coalesce(m.text, unarchive_string(m.attributedBody)) as text_decoded
  FROM message m
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  WHERE m.is_from_me = 1
  and (m.destination_caller_id is null or m.destination_caller_id = '')
  SQL

# Q: Can I find links without parsing the payload
# A: yes
print_table db.execute2 <<~SQL
  SELECT COUNT(*)
  FROM message
  WHERE
  1=1
  AND instr(payload_data, 'richLinkMetadata') > 0
  AND instr(payload_data, 'youtube') > 0
  SQL

# Q: Can I find speed up finding links by first filtering rows out without parsing payload?
# A: yes
print_table db.execute2 <<~SQL
  SELECT COUNT(*)
  FROM message
  WHERE
  1=1
  AND instr(payload_data, 'richLinkMetadata') > 0
  AND instr(payload_data, 'youtube') > 0
  AND unarchive_keyed(payload_data) LIKE '%richLinkMetadata%'
  SQL

# handles; just looking. basically all message recipients / chat participants
print_table db.execute2 "SELECT DISTINCT handle.id FROM handle"

# self ids; per icloud destination it seems
print_table db.execute2 "SELECT DISTINCT destination_caller_id FROM message"

# Q: group chat members; only from chat tables; what do we see?
# A: only one handle per person, even if msgs from multiple handles from same contact
print_table db.execute2 <<~SQL
  SELECT c.ROWID, c.display_name,
    json_group_array(h.id) AS handles
  FROM chat c
  JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
  JOIN handle h ON chj.handle_id = h.ROWID
  GROUP BY c.ROWID, c.display_name
  HAVING COUNT(h.id) > 1
  SQL

# messages to real group chat (>1 members)
# Q: who is recipient when I'm sender?
# A: no recipient, gotta look at chat table.
print_table db.execute2 <<~SQL
  SELECT m.ROWID, h.id AS handle, m.destination_caller_id, m.is_from_me as 'me?',
    -- m.service, c.chat_identifier,
    c.ROWID as chat_id,
    c.display_name,
    coalesce(m.text, unarchive_string(m.attributedBody)) as text_decoded
  FROM message m
  LEFT JOIN handle h ON m.handle_id = h.ROWID
  LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
  LEFT JOIN chat c ON cmj.chat_id = c.ROWID
  WHERE 1 = 1
    AND is_from_me = 0
    and c.ROWID != 1 -- skip that one group chat with loads of msgs
    AND c.ROWID IN ( -- only group chats
      SELECT chat_id
      FROM chat_handle_join
      GROUP BY chat_id
      HAVING COUNT(handle_id) > 1
    )
  ORDER BY m.date DESC
  LIMIT 100
  SQL


## CONTACTS

# full set of useful fields in contacts, but idk. for example, maybe only use org if no other name info. maiden name prob useless
print_table db.execute2 <<~SQL
  SELECT
  ZFIRSTNAME    as first_name,
  ZMAIDENNAME   as maiden_name,
  ZMIDDLENAME   as middle_name,
  ZLASTNAME     as last_name,
  ZNICKNAME     as nick_name,
  ZORGANIZATION as organization
  FROM _addy.ZABCDRECORD r
  SQL

# contact handles, find all handles for contacts that have at least one handle in db
# this is more complex than what we went with which is just handles from chata.db
print_table db.execute2 <<~SQL
  WITH handles AS (
    SELECT
      ZOWNER as id,
      ZADDRESS as handle
    FROM _addy.ZABCDEMAILADDRESS
    UNION ALL
    SELECT
      ZOWNER as id,
      normalize_phone(ZFULLNUMBER) as handle
    FROM _addy.ZABCDPHONENUMBER
  ),
  contact_ids AS (
    -- contacts that have at least one handle in chat.db
    SELECT DISTINCT h.id
    FROM handles h
    JOIN handle ON handle.id = h.handle
  )
  SELECT
    r.Z_PK   as id,
    h.handle as handle,  -- all handles, not just matched ones
    (r.ZCONTAINERWHERECONTACTISME IS NOT NULL) as is_me
  FROM _addy.ZABCDRECORD r
  JOIN contact_ids c ON c.id = r.Z_PK  -- only matched contacts
  LEFT JOIN handles h ON h.id = r.Z_PK -- but all their handles
  SQL


__END__
    -- AND (associated_message_type IS NULL OR associated_message_type < 2000)                              -- # Exclude metadata/reaction messages
    -- AND (balloon_bundle_id IS NULL OR balloon_bundle_id != 'com.apple.DigitalTouchBalloonProvider')  -- # Digital touch lol; another check: substr(hex(payload_data), 1, 8) = '08081100'
