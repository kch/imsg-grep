# frozen_string_literal: true

class Strop::Result

  # Ensures that the specified option is used alone, without any other options.
  # Raises an OptionError if the label is present alongside other options.
  # Example: result.standalone(:help)  # Ensures --help cannot be used with other options
  # raises OptionError if the label is present alongside other options
  def standalone(label)
    labels = opts.map(&:label)
    return unless labels.include?(label) && (labels - [label]).any?
    raise OptionError, "Cannot use #{self[label]._name} with other options"
  end

  # Ensures that options from different groups are not used together.
  # Each group represents a set of related options, the groups are mutually exclusive.
  # Examples:
  #   result.exclusive(:verbose, :quiet)                             # --verbose and --quiet can't be used together
  #   result.exclusive([:json, :pretty], :binary, [:xml, :doctype])  # options from each group don't mix with from others
  # raises OptionError if options from different groups are used together
  def exclusive(*groups)
    labels = opts.map(&:label)
    conflicts = groups.map{ [*it] & labels }.reject(&:empty?)
    return unless conflicts.size > 1
    raise OptionError, "Cannot use together: #{conflicts.flatten.map{self[it]._name}.join(', ')}"
  end

  # Compacts duplicate single-occurrence options by keeping only the last occurrence.
  # Issues a warning when duplicates are found and removed.
  # Example:
  #   $ cmd -a1 -b2 -a3 -b4 -x
  #   > result.compact_singles!(:a, :b)
  #   # result keeps only -a3 -b4 -x
  def compact_singles!(*labels)
    labels.flatten.filter_map{ (os = opts[[it]]).size > 1 and [it, os] }.each do |label, opts|
      names = opts.map(&:_name).uniq.join(", ")
      warn! "multiple #{names} options specified. Last takes precedence."
      replace self - opts[...-1]
    end
  end
end


class Strop::Opt
  def _name = Strop.prefix name # shorthand for prefix
end
