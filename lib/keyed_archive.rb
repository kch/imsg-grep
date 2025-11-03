#!/usr/bin/env ruby

require "json"
require "base64"
require_relative "bplist"

class NSKeyedArchive

  class BinaryString < String
    def initialize(s) = super(s).force_encoding("BINARY")
    def to_json(...) = Base64.strict_encode64(self).to_json(...)
  end


  attr_reader :data, :objects

  def self.unarchive(...) = new(...).unarchive

  def initialize(data)
    raise "no bplist" unless data.start_with?("bplist")
    @data = BPList.parse data
  end

  def unarchive
    top  = @data["$top"] or raise "no top"
    root = top["root"] or raise "no root"
    objs = @data["$objects"] or raise "no objects"
    decode_objects dereference_uids(root, objs)
  end

  private

  def dereference_uids(obj, objects, visited = Set.new, depth = 0)
    # Prevent infinite recursion
    raise "Maximum recursion depth exceeded" if depth > 1000
    case obj
    when Hash
      if obj.size == 1 && obj.has_key?("CF$UID")
        # This is a UID reference, expand it
        uid = obj["CF$UID"]
        return obj if visited.include?(uid) # Prevent infinite recursion
        return obj if uid >= objects.length || uid < 0

        visited.add(uid)
        result = dereference_uids(objects[uid], objects, visited, depth + 1)
        visited.delete(uid)
        return result
      else
        # Regular hash, expand all values
        result = {}
        obj.each { |k, v| result[k] = dereference_uids(v, objects, visited, depth + 1) }
        return result
      end
    when Array
      obj.map { |item| dereference_uids(item, objects, visited, depth + 1) }
    else
      obj
    end
  end

  def decode_objects(obj)
    case obj
    when Hash
      case obj.dig("$class", "$classname")
      in "NSArray" if obj.key? "NS.objects"
        obj["NS.objects"].map { |item| decode_objects(item) }

      in "NSDictionary" if obj.key?("NS.keys") && obj.key?("NS.objects")
        obj["NS.keys"].zip(obj["NS.objects"].map{ decode_objects it }).to_h

      in "NSURL" if obj["NS.base"] == "$null" && obj["NS.relative"]
        obj["NS.relative"]
      else
        obj.transform_values { decode_objects it }
      end

    when Array  then obj.map { |item| decode_objects(item) }
    when "$null" then nil  # Transform $null strings to actual null

    when String # Transform binary data to Base64 ; detect if string is binary (ASCII-8BIT) or invalid UTF-8
      case
      when obj.encoding == Encoding::BINARY then BinaryString.new(obj)
      when obj.force_encoding('UTF-8').valid_encoding? then obj
      else BinaryString.new(obj)
      end

    else obj
    end
  end

end


if __FILE__ == $0
  input = $stdin.read
  out = NSKeyedArchive.unarchive(input)
  puts JSON.pretty_generate(out)
end
