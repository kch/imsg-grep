#!/usr/bin/env ruby
# Development tool to query messages with specified name and platform URLs

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
      (SELECT group_concat(COALESCE(ct.name, cp.handle), ', ')
       FROM chat_participants cp
       LEFT JOIN handle_contacts hc ON hc.handle = cp.handle
       LEFT JOIN contacts ct ON ct.id = hc.contact_id
       WHERE cp.chat_id = c.ROWID)
    ) as name
  FROM messages_db.chat c
SQL

# Query for messages with specified name in participant details and platform links in payload
$db.results_as_hash = true

# Parameters
name_param = ARGV[0] || "andy"
like_params = ARGV[1] ? ARGV[1..] : ["https://www.youtube.com", "https://soundcloud.com"]
results = $db.execute(<<~SQL, [name_param, name_param, like_params.to_json])
  SELECT
    m.id,
    m.utc_time,
    m.sender_handle,
    COALESCE(json_extract(m.sender_details, '$.name'), m.sender_handle) as sender_name,
    cn.name as chat_name,
    cn.display_name,
    m.participant_details,
    json_extract(m.payload, '$.richLinkMetadata.title') as title,
    json_extract(m.payload, '$.richLinkMetadata.summary') as summary,
    json_extract(m.payload, '$.richLinkMetadata.URL') as url
  FROM messages m
  LEFT JOIN messages_db.chat_message_join cmj ON m.id = cmj.message_id
  LEFT JOIN chat_names cn ON cmj.chat_id = cn.chat_id
  WHERE
    m.payload IS NOT NULL
    AND m.is_from_me = 0
    AND (
      -- Match sender only in JSON leaf string values, not keys
      EXISTS (SELECT 1 FROM json_tree(m.participant_details) WHERE type = 'text' AND regexp(?, value))
      -- Match sender in participant handles array (senders not in contacts need to be matched by handle only)
      OR EXISTS (SELECT 1 FROM json_each(m.participant_handles) WHERE regexp(?, value)))
    --  match urls
    AND EXISTS (SELECT 1 FROM json_each(?) WHERE json_extract(m.payload, '$.richLinkMetadata.URL') LIKE '%' || value || '%')
  ORDER BY m.utc_time DESC
  LIMIT 20
SQL


require 'time'
require 'rainbow'
def ¢(...) = Rainbow(...)

puts "Found #{results.size} messages with '#{name_param}' and #{like_params.join('/')} links:"
results.each do |row|
  row.transform_keys(&:to_sym) => {id:, utc_time:, sender_name:, chat_name:, display_name:, title:, summary:, url:}
  chat_prefix = (display_name && !display_name.empty?) ? "via" : "with"
  from_text = chat_name ? "#{sender_name} (#{chat_prefix} #{chat_name})" : sender_name
  local_time = Time.parse(utc_time+"Z").getlocal
  puts ¢("ID: "     ).bright.magenta + ¢(id).bright.cyan + ¢(", Time: ").bright.magenta + ¢(local_time).bright.white + ¢(", From: ").bright.magenta + ¢(from_text).bright.blue
  puts ¢("Title: "  ).bright.yellow  + ¢(title).gold
  puts ¢("Summary: ").bright.green   + ¢(summary).lime
  puts ¢("URL: "    ).bright.red     + ¢(url).aqua
  puts ¢("---"      ).gray
end
