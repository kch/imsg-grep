require 'set'

def parse_bplist(data)
  raise "Invalid header" unless data[0, 8] == "bplist00"

  # Parse trailer (last 32 bytes)
  trailer           = data[-32..]
  offset_int_size   = trailer[6].ord
  objref_size       = trailer[7].ord
  num_objects       = trailer[8, 8].unpack1("Q>")
  root_object_index = trailer[16, 8].unpack1("Q>")
  offset_table_pos  = trailer[24, 8].unpack1("Q>")

  raise "Invalid trailer" if offset_int_size < 1 || objref_size < 1
  raise "Invalid object count" if num_objects < 1 || root_object_index >= num_objects

  # Read offset table
  offsets = (0...num_objects).map do |i|
    pos = offset_table_pos + i * offset_int_size
    bytes = data[pos, offset_int_size].unpack("C*")
    bytes.reduce(0) { |a, b|
      raise "nil value in offset calculation" if a.nil? || b.nil?
      (a << 8) | b
    }
  end

  # Parse objects recursively
  objects = Array.new(num_objects)
  object_cache = {}

  parse_object = lambda do |index|
    raise "Invalid object ref: #{index}" if index >= num_objects
    return objects[index] if objects[index]

    # Check cache first
    offset = offsets[index]
    return object_cache[offset] if object_cache.has_key?(offset)

    # Set placeholder to detect circular refs
    objects[index] = :parsing

    pos    = offsets[index]
    raise "Position #{pos} beyond data size #{data.bytesize}" if pos >= data.bytesize
    marker = data[pos].ord
    high   = marker >> 4
    low    = marker & 0x0F

    # Get count/length (handles 0xF continuation)
    get_count = lambda do |pos|
      return [low, pos + 1] if low != 0x0F

      raise "Position #{pos + 1} beyond data size" if pos + 1 >= data.bytesize
      int_marker = data[pos + 1].ord
      int_high   = int_marker >> 4
      raise "Invalid count marker" unless int_high == 0x1

      byte_count = 1 << (int_marker & 0x0F)
      raise "Position #{pos + 2} + #{byte_count} beyond data size" if pos + 2 + byte_count > data.bytesize
      bytes = data[pos + 2, byte_count].unpack("C*")
      count = bytes.reduce(0) { |a, b|
        raise "nil value in get_count: a=#{a.inspect}, b=#{b.inspect}" if a.nil? || b.nil?
        (a << 8) | b
      }
      [count, pos + 2 + byte_count]
    end

    # Read multi-byte integer
    read_int = lambda do |pos, size|
      raise "Position #{pos} + #{size} beyond data size" if pos + size > data.bytesize
      bytes = data[pos, size].unpack("C*")
      bytes.reduce(0) { |a, b|
        raise "nil value in read_int: a=#{a.inspect}, b=#{b.inspect}" if a.nil? || b.nil?
        (a << 8) | b
      }
    end

    result = case high
    when 0x0  # Null, Bool, Fill
      case marker
      when 0x00 then nil
      when 0x08 then false
      when 0x09 then true
      else raise "Unknown null type: 0x#{marker.to_s(16)}"
      end

    when 0x1  # Integer
      byte_count = 1 << low
      raise "Invalid int size" if byte_count > 16
      raise "Position #{pos + 1} + #{byte_count} beyond data size" if pos + 1 + byte_count > data.bytesize

      if byte_count == 16
        # 128-bit integer - read as two 64-bit values (high, low)
        high_bytes = data[pos + 1, 8].unpack("C*")
        low_bytes = data[pos + 9, 8].unpack("C*")
        high = high_bytes.reduce(0) { |a, b| (a << 8) | b }
        low = low_bytes.reduce(0) { |a, b| (a << 8) | b }
        # Convert to signed if high MSB is set
        if high >= (1 << 63)
          high = high - (1 << 64)
        end
        # Ruby handles big integers automatically
        (high << 64) | low
      else
        value = read_int.call(pos + 1, byte_count)
        # Per Apple spec: only 8+ byte integers are signed, 1/2/4 byte are unsigned
        if byte_count >= 8 && value >= (1 << (byte_count * 8 - 1))
          value - (1 << (byte_count * 8))
        else
          value
        end
      end

    when 0x2  # Real
      byte_count = 1 << low
      raise "Position #{pos + 1} + #{byte_count} beyond data size" if pos + 1 + byte_count > data.bytesize
      case byte_count
      when 4 then data[pos + 1, 4].unpack1("g")
      when 8 then data[pos + 1, 8].unpack1("G")
      else raise "Invalid real size: #{byte_count}"
      end

    when 0x3  # Date
      raise "Invalid date marker" unless marker == 0x33
      raise "Position #{pos + 1} + 8 beyond data size" if pos + 1 + 8 > data.bytesize
      seconds = data[pos + 1, 8].unpack1("G")
      Time.at(978307200 + seconds)

    when 0x4  # Data
      count, start = get_count.call(pos)
      raise "Position #{start} + #{count} beyond data size" if start + count > data.bytesize
      data[start, count]

    when 0x5  # ASCII string
      count, start = get_count.call(pos)
      raise "Position #{start} + #{count} beyond data size" if start + count > data.bytesize
      ascii_data = data[start, count]
      # Validate ASCII - all bytes must be < 128
      if ascii_data.bytes.all? { |b| b < 128 }
        ascii_data.force_encoding("US-ASCII").encode("UTF-8")
      else
        # Invalid ASCII, keep as binary for later Base64 encoding
        ascii_data.force_encoding("ASCII-8BIT")
      end

    when 0x6  # UTF-16 string
      count, start = get_count.call(pos)
      raise "Position #{start} + #{count * 2} beyond data size" if start + count * 2 > data.bytesize
      utf16_data = data[start, count * 2]
      # Convert UTF-16BE to UTF-8
      begin
        utf16_data.force_encoding("UTF-16BE").encode("UTF-8")
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        # Invalid UTF-16, keep as binary for later Base64 encoding
        utf16_data.force_encoding("ASCII-8BIT")
      end

    when 0x8  # UID
      byte_count = low + 1
      raise "Position #{pos + 1} + #{byte_count} beyond data size" if pos + 1 + byte_count > data.bytesize
      {uid: read_int.call(pos + 1, byte_count)}

    when 0xA  # Array
      count, start = get_count.call(pos)
      raise "Position #{start} + #{count * objref_size} beyond data size" if start + count * objref_size > data.bytesize
      refs         = (0...count).map { |i| read_int.call(start + i * objref_size, objref_size) }
      refs.map { |ref| parse_object.call(ref) }

    when 0xC  # Set
      count, start = get_count.call(pos)
      raise "Position #{start} + #{count * objref_size} beyond data size" if start + count * objref_size > data.bytesize
      refs         = (0...count).map { |i| read_int.call(start + i * objref_size, objref_size) }
      Set.new(refs.map { |ref| parse_object.call(ref) })

    when 0xD  # Dict
      count, start = get_count.call(pos)
      raise "Position #{start} + #{count * objref_size * 2} beyond data size" if start + count * objref_size * 2 > data.bytesize
      key_refs     = (0...count).map { |i| read_int.call(start + i * objref_size, objref_size) }
      val_refs     = (0...count).map { |i| read_int.call(start + (count + i) * objref_size, objref_size) }
      key_refs.zip(val_refs).to_h { |k, v| [parse_object.call(k), parse_object.call(v)] }

    else
      raise "Unknown marker: 0x#{marker.to_s(16)}"
    end

    objects[index] = result
    # Cache the parsed object by its offset for reuse
    object_cache[offset] = result
  end

  parse_object.call(root_object_index)
end

def expand_uids(obj, objects, visited = Set.new, depth = 0)
  # Prevent infinite recursion
  raise "Maximum recursion depth exceeded" if depth > 1000
  case obj
  when Hash
    if obj.has_key?(:uid) && obj.keys == [:uid]
      # This is a UID reference, expand it
      uid = obj[:uid]
      return obj if visited.include?(uid) # Prevent infinite recursion
      return obj if uid >= objects.length || uid < 0

      visited.add(uid)
      result = expand_uids(objects[uid], objects, visited, depth + 1)
      visited.delete(uid)
      return result
    else
      # Regular hash, expand all values
      result = {}
      obj.each { |k, v| result[k] = expand_uids(v, objects, visited, depth + 1) }
      return result
    end
  when Array
    obj.map { |item| expand_uids(item, objects, visited, depth + 1) }
  else
    obj
  end
end

def transform_ns_objects(obj)
  case obj
  when Hash
    # Stage 3: Transform NSArray and $null values
    if obj["$class"] && obj["$class"]["$classname"]
      case obj["$class"]["$classname"]
      when "NSArray"
        # Use contents of NS.objects as the value
        return obj["NS.objects"] ? obj["NS.objects"].map { |item| transform_ns_objects(item) } : []
      when "NSDictionary"
        # Transform NS.keys and NS.objects into a hash (ordered pairs)
        if obj["NS.keys"] && obj["NS.objects"]
          result = {}
          keys = obj["NS.keys"]
          values = obj["NS.objects"]
          keys.each_with_index do |key, index|
            if index < values.length
              result[key] = transform_ns_objects(values[index])
            end
          end
          return result
        else
          # Fallback to regular hash transformation
          result = {}
          obj.each { |k, v| result[k] = transform_ns_objects(v) }
          return result
        end
      when "NSURL"
        # If NS.base is $null, use NS.relative value
        if obj["NS.base"] == "$null" && obj["NS.relative"]
          return obj["NS.relative"]
        else
          # Don't transform if NS.base is not $null
          result = {}
          obj.each { |k, v| result[k] = transform_ns_objects(v) }
          return result
        end
      end
    end

    # Regular hash, transform all values
    result = {}
    obj.each { |k, v| result[k] = transform_ns_objects(v) }
    return result
  when Array
    obj.map { |item| transform_ns_objects(item) }
  when "$null"
    # Transform $null strings to actual null
    nil
  when String
    # Transform binary data to Base64
    # detect if string is binary (ASCII-8BIT) or invalid UTF-8
    if obj.encoding == Encoding::ASCII_8BIT
      return Base64.strict_encode64(obj)
    end

    begin
      obj.force_encoding('UTF-8')
      if !obj.valid_encoding?
        obj.force_encoding('ASCII-8BIT')
        return Base64.strict_encode64(obj)
      end
    rescue
      obj.force_encoding('ASCII-8BIT')
      return Base64.strict_encode64(obj)
    end
    obj
  else
    obj
  end
end

def deep_sort_hash(obj)
  case obj
  when Hash
    result = {}
    obj.keys.sort_by(&:to_s).each do |key|
      result[key] = deep_sort_hash(obj[key])
    end
    result
  when Array
    obj.map { |item| deep_sort_hash(item) }
  else
    obj
  end
end

if __FILE__ == $0
  require 'sqlite3'
  require 'json'
  require 'yaml'
  require 'base64'

  # Connect to the database
  db = SQLite3::Database.new(File.expand_path("~/.cache/imsg-grep/chat.db"))

  # Get all rows with both payload_data and payload, including rowid
  rows = db.execute("SELECT rowid, payload_data, payload FROM messages_decoded WHERE payload_data IS NOT NULL ORDER BY utc_time DESC")

  puts "Comparing #{rows.length} records..."

  rows.each_with_index do |row, index|
    rowid, payload_data, payload_json = row

    # Parse bplist
    binary_data = payload_data.dup.force_encoding('BINARY')
    parsed_bplist = parse_bplist(binary_data)

    # Extract and transform root object
    root_object = parsed_bplist["$objects"][1]
    expanded_object = expand_uids(root_object, parsed_bplist["$objects"])
    transformed_object = transform_ns_objects(expanded_object)

    # # Parse payload JSON
    # payload_parsed = JSON.parse(payload_json) if payload_json

    # # Deep sort both for comparison (ignore key order)
    # sorted_transformed = deep_sort_hash(transformed_object)
    # sorted_payload = deep_sort_hash(payload_parsed)

    # if sorted_transformed == sorted_payload
    #   puts "Row #{index + 1}/#{rows.length} (id:#{rowid}): MATCH ✓"
    # else
    #   puts "Row #{index + 1}/#{rows.length} (id:#{rowid}): MISMATCH ✗"
    #   puts "\n=== TRANSFORMED BPLIST (STAGE 3) ==="
    #   puts transformed_object.to_yaml
    #   puts "\n=== PAYLOAD JSON ==="
    #   puts payload_parsed.to_yaml
    #   break
    # end
  end

  db.close
end

__END__

Binary plist format specification (based on Apple CFBinaryPList.c):

HEADER
	magic number ("bplist")
	file format version (currently "0?")

OBJECT TABLE
	variable-sized objects

	Object Formats (marker byte followed by additional info in some cases)
	null	0000 0000			// null object [v"1?"+ only]
	bool	0000 1000			// false
	bool	0000 1001			// true
	url	0000 1100	string		// URL with no base URL, recursive encoding of URL string [v"1?"+ only]
	url	0000 1101	base string	// URL with base URL, recursive encoding of base URL, then recursive encoding of URL string [v"1?"+ only]
	uuid	0000 1110			// 16-byte UUID [v"1?"+ only]
	fill	0000 1111			// fill byte
	int	0001 0nnn	...		// # of bytes is 2^nnn, big-endian bytes
	real	0010 0nnn	...		// # of bytes is 2^nnn, big-endian bytes
	date	0011 0011	...		// 8 byte float follows, big-endian bytes
	data	0100 nnnn	[int]	...	// nnnn is number of bytes unless 1111 then int count follows, followed by bytes
	string	0101 nnnn	[int]	...	// ASCII string, nnnn is # of chars, else 1111 then int count, then bytes
	string	0110 nnnn	[int]	...	// Unicode string, nnnn is # of chars, else 1111 then int count, then big-endian 2-byte uint16_t
	string	0111 nnnn	[int]	...	// UTF8 string, nnnn is # of chars, else 1111 then int count, then bytes [v"1?"+ only]
	uid	1000 nnnn	...		// nnnn+1 is # of bytes
		1001 xxxx			// unused
	array	1010 nnnn	[int]	objref*	// nnnn is count, unless '1111', then int count follows
	ordset	1011 nnnn	[int]	objref* // nnnn is count, unless '1111', then int count follows [v"1?"+ only]
	set	1100 nnnn	[int]	objref* // nnnn is count, unless '1111', then int count follows [v"1?"+ only]
	dict	1101 nnnn	[int]	keyref* objref*	// nnnn is count, unless '1111', then int count follows
		1110 xxxx			// unused
		1111 xxxx			// unused

OFFSET TABLE
	list of ints, byte size of which is given in trailer
	-- these are the byte offsets into the file
	-- number of these is in the trailer

TRAILER
	byte size of offset ints in offset table
	byte size of object refs in arrays and dicts
	number of offsets in offset table (also is number of objects)
	element # in offset table which is top level object
	offset table offset

**Integer Signedness (per Apple spec):**
- 1, 2, 4-byte integers: Always unsigned
- 8+ byte integers: Signed when MSB is set (two's complement)
- 16-byte integers: 128-bit signed (high 64-bit + low 64-bit)

**Encoding:**
- Big-endian byte order throughout
- Length in low nibble (0-14 direct, 0xF = follow-on integer)
- Object references are indices into offset table
- Strings: ASCII (0x5X), UTF-16BE (0x6X), UTF-8 (0x7X, v1+ only)
