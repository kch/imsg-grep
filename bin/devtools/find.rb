#!/usr/bin/env ruby
# Development tool to query messages with regexp patterns against computed_text. $ find sender text1 text2

require_relative "../../lib/messages"

# Create temp view for chat names keyed by chat_id
$db.execute <<~SQL
  CREATE TEMP VIEW chat_names AS
  WITH distinct_handles AS (
    SELECT DISTINCT cmj.chat_id, md.participant_handles
    FROM messages_db.chat_message_join cmj
    JOIN messages_decoded md ON cmj.message_id = md.id
    WHERE md.participant_handles IS NOT NULL
  ),
  chat_participants AS (
    SELECT DISTINCT dh.chat_id, value as handle
    FROM distinct_handles dh
    JOIN json_each(dh.participant_handles)
  )
  SELECT
    c.ROWID as chat_id,
    c.display_name,
    COALESCE(
      NULLIF(c.display_name, ''),
      (SELECT group_concat(name, ', ')
       FROM (
         SELECT DISTINCT COALESCE(ct.name, cp.handle) as name
         FROM chat_participants cp
         LEFT JOIN handle_contacts hc ON hc.handle = cp.handle
         LEFT JOIN contacts ct ON ct.id = hc.contact_id
         WHERE cp.chat_id = c.ROWID
       ))
    ) as name
  FROM messages_db.chat c
  where c.ROWID = 123
SQL

$db.results_as_hash = true

# Parameters
name_param = ARGV[0] || "andy"
text_patterns = ARGV.length > 1 ? ARGV[1..] : []
text_conditions = text_patterns.map { "    AND regexp(?, m.computed_text)" }.join("\n")
binds = [name_param, name_param] + text_patterns

results = $db.execute(<<~SQL, binds)
  SELECT
    m.id,
    m.utc_time,
    m.sender_handle,
    m.sender_details,
    m.participant_handles,
    m.participant_details,
    COALESCE(json_extract(m.sender_details, '$.name'), m.sender_handle) as sender_name,
    cn.name as chat_name,
    cn.display_name,
    m.computed_text
  FROM messages m
  LEFT JOIN messages_db.chat_message_join cmj ON m.id = cmj.message_id
  LEFT JOIN chat_names cn ON cmj.chat_id = cn.chat_id
  WHERE
  (regexp(?, m.sender_handle)
  OR EXISTS (
    SELECT 1 FROM json_tree(m.sender_details)
    WHERE type = 'text'
    AND regexp(?, value)
    -- AND lower(value) LIKE '%' || lower(?) || '%'
  ))
  -- AND utc_time >= datetime('now', '-4 month')
#{text_conditions}
    AND m.is_from_me = 0
  ORDER BY m.utc_time DESC
  LIMIT 50
SQL
# require "pry"; binding.pry

require 'time'
require 'rainbow'
def ¢(...) = Rainbow(...)

search_desc = text_patterns.empty? ? "'#{name_param}'" : "'#{name_param}' && #{text_patterns.join(' && ')}"
puts "Found #{results.size} messages matching: #{search_desc}"
results.each do |row|
  row.transform_keys(&:to_sym) => {id:, utc_time:, sender_name:, chat_name:, display_name:, computed_text:, sender_handle:}
  chat_prefix = (display_name && !display_name.empty?) ? "via" : "with"
  from_text = chat_name ? "#{sender_name} (#{chat_prefix} #{chat_name})" : "#{sender_name} [#{sender_handle}]"
  local_time = Time.parse(utc_time+"Z").getlocal
  puts ¢("ID: "  ).bright.magenta + ¢(id).bright.cyan + ¢(", Time: ").bright.magenta + ¢(local_time).bright.white + ¢(", From: ").bright.magenta + ¢(from_text).bright.blue
  puts ¢("Text: ").bright.yellow  + ¢(computed_text).gold
  puts ¢("---"   ).gray
end
