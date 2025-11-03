#!/usr/bin/env ruby
# Ruby FFI wrapper for the attr_str.dylib library to decode NSAttributedString binary data

require "ffi"

module NSAttributedString
  extend FFI::Library
  ffi_lib "#{__dir__}/attr_str.dylib"

  attach_function :attributed_string_unarchive, [:pointer, :size_t], :pointer
  attach_function :attributed_string_describe,  [:pointer, :size_t], :pointer
  attach_function :free, [:pointer], :void

  def self.unarchive(bin) = handle_result(bin) { |ptr, len| attributed_string_unarchive(ptr, len) }
  def self.describe(bin)  = handle_result(bin) { |ptr, len| attributed_string_describe(ptr, len) }

  private
  def self.handle_result(bin)
    return nil if bin.nil?

    ptr = FFI::MemoryPointer.new :char, bin.bytesize
    ptr.put_bytes 0, bin

    result = yield ptr, bin.bytesize
    return nil if result.null?

    str = result.read_string
    free result
    str
  end
end

if __FILE__ == $0
  bin = STDIN.read
  puts "Decoded: #{NSAttributedString.unarchive(bin) || 'null'}"
  puts "Description: #{NSAttributedString.describe(bin) || 'null'}"
end
