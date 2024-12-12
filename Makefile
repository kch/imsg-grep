CC      = clang
CFLAGS  = -framework Foundation

lib: lib/attr_str.dylib

bin: lib/attr_str

lib/attr_str.dylib: lib/attr_str.m
	$(CC) -shared $(CFLAGS) -o $@ $<

lib/attr_str: lib/attr_str.m
	$(CC) -DMAIN_EXECUTABLE $(CFLAGS) -o $@ $<

clean:
	rm -f lib/attr_str.dylib lib/attr_str
