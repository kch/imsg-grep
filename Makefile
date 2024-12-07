SWIFT    = swiftc
FLAGS    = -v
TARGETS  = contact-lookup imsg-grep

all: $(TARGETS)

contact-lookup: contact-lookup.swift
	$(SWIFT) $(FLAGS) $< -o $@

imsg-grep: imsg-grep.swift
	$(SWIFT) $(FLAGS) $< -o $@

clean:
	rm -f $(TARGETS)

.PHONY: all clean
