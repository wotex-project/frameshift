#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/personality.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Disposable booted-manager fixture; never part of the installed product. */
static void refuse(const char *check) {
  fprintf(stderr, "systemd-canary: %s refused (%d)\n", check, errno);
  exit(1);
}
static void require(int condition, const char *check) {
  if (!condition) refuse(check);
}
static void file_denied(const char *path, int flags, int expected, const char *check) {
  errno = 0;
  int fd = open(path, flags | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd >= 0) { close(fd); refuse(check); }
  require(errno == expected, check);
}
static void mounted_read_only(const char *path, const char *check) {
  struct statvfs filesystem;
  require(statvfs(path, &filesystem) == 0 && (filesystem.f_flag & ST_RDONLY) != 0, check);
  errno = 0;
  int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd >= 0) { close(fd); refuse(check); }
  /* Permission checks on pseudo-files can precede a read-only mount refusal. */
  require(errno == EROFS || errno == EACCES, check);
}
static void managed_write(const char *path) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  require(fd >= 0, "managed-write");
  require(write(fd, "owned\n", 6) == 6, "managed-write");
  require(close(fd) == 0 && unlink(path) == 0, "managed-cleanup");
}
static void policy(void) {
  require(getuid() != 0 && getuid() == geteuid(), "nonroot");
  require(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1, "no-new-privileges");
  struct rlimit limit;
  require(getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur == 4096 && limit.rlim_max == 4096, "file-limit");
  managed_write("/var/lib/frameshift/.systemd-canary-state");
  managed_write("/run/frameshift/.systemd-canary-runtime");
  file_denied("/usr/lib/frameshift-systemd-qualification/write", O_WRONLY | O_CREAT, EROFS, "system-read-only");
  file_denied("/home/frameshift-systemd-qualification/read", O_RDONLY, EACCES, "home-denial");
  file_denied("/tmp/frameshift-systemd-qualification", O_RDONLY, ENOENT, "private-tmp");
  file_denied("/dev/frameshift-systemd-qualification", O_RDONLY, ENOENT, "private-devices");
  mounted_read_only("/proc/sys/kernel/hostname", "kernel-read-only");
  mounted_read_only("/sys/fs/cgroup/cgroup.procs", "cgroup-read-only");
  int fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
  require(fd >= 0 && close(fd) == 0, "private-null-device");
  require(setuid(0) == -1 && errno == EPERM, "privilege-denial");
  struct sched_param realtime = { .sched_priority = 1 };
  require(sched_setscheduler(0, SCHED_FIFO, &realtime) == -1 && errno == EPERM, "realtime-denial");
  require(personality(READ_IMPLIES_EXEC) == -1 && errno == EPERM, "personality-denial");
  errno = 0;
  fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC, 0);
  require(fd == -1 && errno == EAFNOSUPPORT, "address-family-denial");
  puts("systemd-canary: kernel-policy passed");
}
static void tasks(void) {
  pid_t children[600];
  size_t count = 0;
  int failure = 0;
  while (count < sizeof children / sizeof children[0]) {
    pid_t child = fork();
    if (child < 0) { failure = errno; break; }
    if (child == 0) { for (;;) pause(); }
    children[count++] = child;
  }
  for (size_t i = 0; i < count; i++) require(kill(children[i], SIGKILL) == 0, "task-cleanup");
  for (size_t i = 0; i < count; i++) require(waitpid(children[i], NULL, 0) == children[i], "task-reap");
  require(count == 511 && failure == EAGAIN, "task-ceiling");
  puts("systemd-canary: 512-task ceiling passed");
}
static void oom(void) {
  pid_t child = fork();
  require(child >= 0, "oom-fork");
  if (child == 0) {
    int fd = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
    require(fd >= 0 && write(fd, "1000", 4) == 4 && close(fd) == 0, "oom-selection");
    void *blocks[128];
    for (size_t i = 0; i < 128; i++) {
      volatile unsigned char *block = malloc(16 * 1024 * 1024);
      require(block != NULL, "oom-allocation");
      blocks[i] = (void *)block;
      for (size_t offset = 0; offset < 16 * 1024 * 1024; offset += 4096) block[offset] = 1;
    }
    for (size_t i = 0; i < 128; i++) free(blocks[i]);
    refuse("memory-ceiling");
  }
  int status = 0;
  require(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL, "oom-child-killed");
  puts("systemd-canary: OOM child killed");
  fflush(stdout);
  /* Keep the cgroup present so its independent memory.events can be inspected. */
  sleep(30);
}
static void linger(void) {
  pid_t child = fork();
  require(child >= 0, "linger-fork");
  if (child == 0) {
    require(signal(SIGTERM, SIG_IGN) != SIG_ERR, "linger-signal");
    int fd = open("/run/frameshift/.systemd-canary-child", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd >= 0, "linger-custody");
    char value[32]; int length = snprintf(value, sizeof value, "%ld\n", (long)getpid());
    require(length > 0 && length < (int)sizeof value && write(fd, value, (size_t)length) == length && close(fd) == 0, "linger-ready");
    for (;;) pause();
  }
  for (;;) pause();
}
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  if (strcmp(argv[1], "policy") == 0) policy();
  else if (strcmp(argv[1], "tasks") == 0) tasks();
  else if (strcmp(argv[1], "oom") == 0) oom();
  else if (strcmp(argv[1], "linger") == 0) linger();
  else return 64;
  return 0;
}
