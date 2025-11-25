#!/usr/bin/env ruby
# Extract NSString value from unkeyed-archived (typedstream) NSAttributedString

class AttributedStringExtractor
  def self.extract(data) = (new(data).extract if data)

  TAG_INTEGER_2 = -127  # Indicates 2-byte integer follows
  TAG_INTEGER_4 = -126  # Indicates 4-byte integer follows

  def initialize(data)
    return if data.nil?
    # Find NSString position first and fail fast if not found
    @nsstring_pos = data.index("NSString") or raise "NSString not found in data"
    @data = data.b
    @pos = 0

    # Read and validate header
    version = read.ord
    sig_length = read.ord
    raise "Only version 4 supported, got #{version}" unless version == 4
    raise "Invalid signature length #{sig_length}" unless sig_length == 11

    signature = read(sig_length)
    case signature
    when "streamtyped" then @int16_format, @int32_format = "v", "V"
    when "typedstream" then @int16_format, @int32_format = "n", "N"
    else raise "Invalid signature: #{signature.inspect}"
    end
  end

  def extract
    return if @data.nil?

    # Jump to after NSString and look for '+' string marker
    marker_pos = @data.index(?+, @nsstring_pos + 8)
    return unless marker_pos

    @pos = marker_pos + 1  # Skip '+' marker

    length_byte = read.ord                                             # Read string length
    length_byte = length_byte > 127 ? length_byte - 256 : length_byte  # Convert to signed byte for tag comparison

    length = case length_byte
    when TAG_INTEGER_2 then read(2).unpack1(@int16_format) # 2-byte length
    when TAG_INTEGER_4 then read(4).unpack1(@int32_format) # 4-byte length
    else length_byte                                       # Single byte length
    end

    return unless length && length > 0

    read(length).force_encoding("UTF-8") # Extract and return string
  end

  private

  def read(n = 1)
    bytes = @data[@pos, n]
    @pos += n
    bytes
  end
end

puts AttributedStringExtractor.extract(STDIN.read) if __FILE__ == $0 && STDIN.stat.size > 0
