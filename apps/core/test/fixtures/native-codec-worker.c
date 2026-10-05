#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void wait_ten_seconds(void) {
  struct timespec remaining = {10, 0};
  while (nanosleep(&remaining, &remaining) != 0) {}
}

int main(int argc, char **argv) {
  struct stat error_output, null_device;
  if (environ[0] != NULL || fstat(2, &error_output) != 0 ||
      stat("/dev/null", &null_device) != 0 ||
      error_output.st_rdev != null_device.st_rdev ||
      !S_ISCHR(error_output.st_mode)) return 80;

  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
#ifdef BAD_REVISION
    puts("unqualified-revision");
#else
    puts("frameshift-codec/1 png/0.18.1 moxcms/0.9.1 exif/0.6.1 scalar-sdr/1");
#endif
    return 0;
  }
  if (argc != 1) return 81;

  unsigned char prefix[4];
  if (fread(prefix, 1, 4, stdin) != 4) return 82;
  uint32_t length = ((uint32_t)prefix[0] << 24) |
                    ((uint32_t)prefix[1] << 16) |
                    ((uint32_t)prefix[2] << 8) | prefix[3];
  int operation = getchar();
  if (length == 0 || operation == EOF) return 83;
  if (operation == 'B') wait_ten_seconds();
  for (uint32_t i = 1; i < length; i++) if (getchar() == EOF) return 84;
  if (getchar() != EOF) return 85;
  if (operation == 'S') wait_ten_seconds();

  unsigned char header[64] = {'F', 'S', 'N', '1', 0, 1, 0, 1};
  header[11] = 1;
  header[15] = 1;
  header[16] = 1;
  header[17] = 1;
  header[31] = 4;
  unsigned char rgba[4] = {12, 34, 56, 255};
  if (operation == 'F' || operation == 'G') {
    memset(header + 7, 0, 57);
    header[6] = 2;
  }
  if (operation == 'A') rgba[3] = 0;
  if (operation == 'M') header[11] = 0;
  for (size_t i = 0; i < sizeof(header); i++) {
    if (write(1, header + i, 1) != 1) return 86;
  }
  if (operation != 'F' && operation != 'G') {
    if (write(1, rgba, sizeof(rgba)) != sizeof(rgba)) return 87;
  }
  if (operation == 'T' || operation == 'G') {
    if (write(1, "extra", 5) != 5) return 88;
  }
  if (operation == 'Q') {
    close(1);
    wait_ten_seconds();
  }
  return operation == 'E' ? 7 : 0;
}
