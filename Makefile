CC      = clang
CFLAGS  = -framework Foundation

lib: lib/decode_attr.dylib

bin: lib/decode_attr

lib/decode_attr.dylib: lib/decode_attr.m
	$(CC) -shared $(CFLAGS) -o $@ $<

lib/decode_attr: lib/decode_attr.m
	$(CC) -DMAIN_EXECUTABLE $(CFLAGS) -o $@ $<

clean:
	rm -f lib/decode_attr.dylib lib/decode_attr
