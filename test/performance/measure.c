#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t measured_child = 0;
static void stop_child(int signal_number) {
  if (measured_child > 0) kill(measured_child, signal_number);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--evict") == 0) {
    for (int i = 2; i < argc; i++) {
      int fd = open(argv[i], O_RDONLY);
      if (fd < 0) return 2;
      int error = posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
      close(fd);
      if (error) return 2;
    }
    return 0;
  }
  if (argc < 4) return 2;
  struct timespec start, end;
  clock_gettime(CLOCK_MONOTONIC, &start);
  pid_t child = fork();
  if (child < 0) return 2;
  if (child == 0) {
    execvp(argv[3], argv + 3);
    perror("execvp");
    _exit(127);
  }
  measured_child = child;
  struct sigaction stop = {0};
  stop.sa_handler = stop_child;
  sigemptyset(&stop.sa_mask);
  sigaction(SIGTERM, &stop, NULL);
  int status;
  struct rusage usage;
  while (wait4(child, &status, 0, &usage) < 0) {
    if (errno != EINTR) return 2;
  }
  clock_gettime(CLOCK_MONOTONIC, &end);
  double elapsed = end.tv_sec - start.tv_sec +
    (end.tv_nsec - start.tv_nsec) / 1000000000.0;
  double cpu = usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
    (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0;
  fprintf(stderr, "SZANIEC_PEAK %ld\nSZANIEC_PROCESS elapsed=%.9f cpu=%.9f\n",
    usage.ru_maxrss, elapsed, cpu);
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 2;
}
