#import <Foundation/Foundation.h>

/*
Decodes NSAttributedString binary data.

Library usage:
  clang -shared -framework Foundation -o decode_attr.dylib decode_attr.m

Test binary usage:
  clang -DMAIN_EXECUTABLE -framework Foundation -o decode_attr decode_attr.m
  cat attributed.data | ./decode_attr
*/

static NSAttributedString* decode_data(const void* data, size_t len) {
  NSData *nsdata = [NSData dataWithBytes:data length:len];

  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [NSUnarchiver unarchiveObjectWithData:nsdata];
  #pragma clang diagnostic pop
}

static char* string_to_cstr(NSString* str) {
  if (!str) return NULL;
  const char *utf8 = [str UTF8String];
  return utf8 ? strdup(utf8) : NULL;
}

char* decode_attributed_string(const void* data, size_t len) {
  NSAttributedString *str = decode_data(data, len);
  return string_to_cstr([str string]);
}

char* describe_attributed_string(const void* data, size_t len) {
  NSAttributedString *str = decode_data(data, len);
  return string_to_cstr([str description]);
}


#ifdef MAIN_EXECUTABLE
int main(void) {
  NSFileHandle *stdin = [NSFileHandle fileHandleWithStandardInput];
  NSData *input = [stdin readDataToEndOfFile];

  char *decoded = decode_attributed_string([input bytes], [input length]);
  char *desc    = describe_attributed_string([input bytes], [input length]);

  printf("Decoded: %s\n", decoded ?: "null");
  printf("Description: %s\n", desc ?: "null");

  free(decoded);
  free(desc);
  return 0;
}
#endif
