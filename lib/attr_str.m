#import <Foundation/Foundation.h>

/*
Decodes NSAttributedString binary data.

Library usage:
  clang -shared -framework Foundation -o attr_str.dylib attr_str.m

Test binary usage:
  clang -DMAIN_EXECUTABLE -framework Foundation -o attr_str attr_str.m
  cat attributed.data | ./attr_str
*/

static NSAttributedString* unarchive(const void* data, size_t len) {
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

char* attributed_string_unarchive(const void* data, size_t len) {
  NSAttributedString *str = unarchive(data, len);
  return string_to_cstr([str string]);
}

char* attributed_string_describe(const void* data, size_t len) {
  NSAttributedString *str = unarchive(data, len);
  return string_to_cstr([str description]);
}


#ifdef MAIN_EXECUTABLE
int main(void) {
  NSFileHandle *stdin = [NSFileHandle fileHandleWithStandardInput];
  NSData *input = [stdin readDataToEndOfFile];

  char *attr_str = attributed_string_unarchive([input bytes], [input length]);
  char *desc     = attributed_string_describe([input bytes], [input length]);

  printf("Decoded: %s\n", attr_str ?: "null");
  printf("Description: %s\n", desc ?: "null");

  free(attr_str);
  free(desc);
  return 0;
}
#endif
