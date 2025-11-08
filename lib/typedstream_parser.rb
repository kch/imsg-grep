#!/usr/bin/env ruby

class TypedStreamParser
  SIGNATURE_LITTLE_ENDIAN = "streamtyped".b  # Little-endian signature bytes
  SIGNATURE_BIG_ENDIAN    = "typedstream".b  # Big-endian signature bytes
  SIGNATURE_LENGTH        = SIGNATURE_LITTLE_ENDIAN.length  # Both signatures same length

  STREAMER_VERSION_CURRENT = 4  # Only supported version

  TAG_INTEGER_2      = -127  # Indicates 2-byte integer follows
  TAG_INTEGER_4      = -126  # Indicates 4-byte integer follows
  TAG_FLOATING_POINT = -125  # Indicates float/double follows
  TAG_NEW            = -124  # Indicates new literal object/string
  TAG_NIL            = -123  # Indicates nil value
  TAG_END_OF_OBJECT  = -122  # Indicates end of object

  FIRST_TAG = -128  # First reserved tag value
  LAST_TAG  = -111  # Last reserved tag value
  FIRST_REFERENCE_NUMBER = LAST_TAG + 1  # First valid reference number

  def initialize(data)
    @data = data.b  # Ensure binary string encoding
    @pos = 0        # Current read position
    read_header
  end

  def read_header
    # Read streamer version and signature length
    @streamer_version = @data[@pos].ord  # First byte is streamer version
    @pos += 1

    signature_length = @data[@pos].ord  # Second byte is signature length
    @pos += 1

    raise "Only streamer version 4 supported, got #{@streamer_version}" unless @streamer_version == STREAMER_VERSION_CURRENT
    raise "Signature must be exactly #{SIGNATURE_LENGTH} bytes, got #{signature_length}" unless signature_length == SIGNATURE_LENGTH

    # Read and validate signature
    signature = @data[@pos, signature_length]  # Extract signature bytes
    @pos += signature_length

    @byte_order = case signature  # Determine endianness from signature
      when SIGNATURE_LITTLE_ENDIAN then :little
      when SIGNATURE_BIG_ENDIAN    then :big
      else raise "Invalid signature: #{signature.inspect}"
      end

    # Precompute unpack formats for performance
    @int32_format  = @byte_order == :little ? "V" : "N"    # 32-bit unsigned
    @sint16_format = @byte_order == :little ? "s<" : "s>"  # 16-bit signed
    @uint16_format = @byte_order == :little ? "S<" : "S>"  # 16-bit unsigned

    # Read and skip system version
    @system_version = read_int32  # System version (not used but required)
  end

  def read_byte
    return nil if @pos >= @data.length     # Check bounds
    byte = @data[@pos]                     # Get byte at current position
    @pos += 1                              # Advance position
    byte = byte.ord                        # Convert to integer
    byte > 127 ? byte - 256 : byte         # Convert to signed byte (-128..127)
  end

  def read_int32
    return nil if @pos + 4 > @data.length  # Check bounds for 4 bytes
    bytes = @data[@pos, 4]                 # Extract 4 bytes
    @pos += 4                              # Advance position
    bytes.unpack1(@int32_format)           # Unpack using precomputed format
  end

  def read_integer(head = nil, signed: true)
    head ||= read_byte  # Use provided head or read new byte
    return unless head

    case head
    when TAG_INTEGER_2                       # 2-byte integer
      return nil if @pos + 2 > @data.length
      bytes = @data[@pos, 2]
      @pos += 2
      bytes.unpack1(signed ? @sint16_format : @uint16_format)
    when TAG_INTEGER_4 then read_int32       # 4-byte integer
    else head                                # Single-byte integer (literal value)
    end
  end

  def read_string(head = nil)
    head ||= read_byte                          # Use provided head or read new byte
    return nil if head.nil? || head == TAG_NIL  # Handle nil string

    length = read_integer(head, signed: false)  # Read string length
    return nil if length.nil? || @pos + length > @data.length  # Check bounds

    str = @data[@pos, length]  # Extract string bytes
    @pos += length             # Advance position
    str
  end

  def extract_nsstring
    # Simple approach: find "NSString" then find the next string data
    nsstring_pos = @data.index("NSString", @pos) or return # Search from current position

    # Look for the string marker (0x2b = '+') after NSString
    @pos = nsstring_pos + 8  # Skip "NSString" (8 bytes)

    while ((head = read_byte) && head != 0x2b) do end  # Skip bytes until '+' marker found
    return unless head == 0x2b                         # Ensure we found the marker
    return read_string&.force_encoding("UTF-8")        # Read the actual string data, convert to UTF-8
  end
end


puts TypedStreamParser.new(STDIN.read).extract_nsstring  if __FILE__ == $0 && STDIN.stat.size > 0  # Read from stdin if available
