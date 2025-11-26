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
    groups.map!{ [*it] } # normalize if passed strings instead of lists
    for group in groups
      right = labels & (groups - [group]).flatten(1)
      left  = labels & group
      bad   = right | left
      raise OptionError, "Cannot use together: #{bad.map{self[it]._name}.join(', ')}" if right.any? && left.any?
    end
  end
end


class Strop::Opt
  def _name = Strop.prefix name # shorthand for prefix
end
