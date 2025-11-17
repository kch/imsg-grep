class Strop::Result
  def standalone(label)
    labels = opts.map(&:label)
    return unless labels.include?(label) && (labels - [label]).any?
    raise OptionError, "Cannot use #{self[label]._name} with other options"
  end

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
