#define _XOPEN_SOURCE 700
#include "p5.h"
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t interrupted;
static void stopped(int signal) { interrupted = signal; }
static int live_terminal(int *slave) {
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  need(master >= 0, "Cannot open live log terminal");
  need(!grantpt(master) && !unlockpt(master), "Cannot initialize live log terminal");
  char *name = ptsname(master);
  need(name != NULL, "Cannot name live log terminal");
  *slave = open(name, O_RDWR | O_NOCTTY);
  need(*slave >= 0, "Cannot open live log terminal output");
  struct termios settings;
  need(!tcgetattr(*slave, &settings), "Cannot read live log terminal settings");
  settings.c_oflag &= ~OPOST; /* Preserve tool newlines in the saved log. */
  need(!tcsetattr(*slave, TCSANOW, &settings), "Cannot set live log terminal settings");
  need(fcntl(master, F_SETFL, O_NONBLOCK) >= 0,
       "Cannot make live log terminal nonblocking");
  return master;
}
static int relay_live(int master) {
  char buffer[4096];
  int received = 0;
  /* Bound each drain so a continuously noisy child cannot evade its deadline. */
  for (int batch = 0; batch < 16; batch++) {
    ssize_t n = read(master, buffer, sizeof(buffer));
    if (n < 0 && errno == EINTR) {
      batch--;
      continue;
    }
    if (n <= 0)
      break;
    received = 1;
    for (ssize_t offset = 0; offset < n;) {
      ssize_t written = write(STDERR_FILENO, buffer + offset, n - offset);
      if (written < 0 && errno == EINTR)
        continue;
      if (written <= 0) {
        if (!interrupted)
          interrupted = SIGTERM;
        return received;
      }
      offset += written;
    }
  }
  return received;
}
int process_main(int argc, char **argv) {
  if (!strcmp(argv[1], "lock-fd")) {
    need(argc == 3, "lock-fd DESCRIPTOR");
    char *end;
    long descriptor = strtol(argv[2], &end, 10);
    need(*argv[2] && !*end && descriptor >= 0 && descriptor < 1024,
         "Invalid lock descriptor");
    need(!flock(descriptor, LOCK_EX | LOCK_NB),
         "Another device operation holds the lock");
    return 1;
  }
  int live = !strcmp(argv[1], "run-live");
  if (!live && strcmp(argv[1], "run-timeout"))
    return 0;
  need(argc >= (live ? 5 : 4),
       live ? "run-live SECONDS LABEL EXECUTABLE [ARGS]"
            : "run-timeout SECONDS EXECUTABLE [ARGS]");
  int command = live ? 4 : 3;
  char *end;
  unsigned long seconds = strtoul(argv[2], &end, 10);
  need(*argv[2] && !*end && seconds > 0 && seconds <= 86400, "Invalid timeout");
  struct sigaction action = {0}, old_int, old_term, old_pipe;
  action.sa_handler = stopped;
  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, &old_int);
  sigaction(SIGTERM, &action, &old_term);
  if (live)
    sigaction(SIGPIPE, &action, &old_pipe);
  int master = -1, slave = -1;
  if (live)
    master = live_terminal(&slave);
  pid_t child = fork();
  need(child >= 0, "Cannot launch process");
  if (!child) {
    setpgid(0, 0);
    sigaction(SIGINT, &old_int, NULL);
    sigaction(SIGTERM, &old_term, NULL);
    if (live) {
      sigaction(SIGPIPE, &old_pipe, NULL);
      close(master);
      if (dup2(slave, STDOUT_FILENO) < 0 || dup2(slave, STDERR_FILENO) < 0)
        _exit(127);
      close(slave);
    }
    execvp(argv[command], argv + command);
    fprintf(stderr, "Cannot execute %s: %s\n", argv[command], strerror(errno));
    _exit(127);
  }
  if (live)
    close(slave);
  setpgid(child, child);
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  int status = 0, terminated = 0, timed_out = 0;
  time_t deadline = start.tv_sec + seconds;
  time_t last_output = start.tv_sec;
  while (1) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (live && relay_live(master))
      last_output = now.tv_sec;
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) {
      if (live)
        relay_live(master);
      break;
    }
    need(result >= 0 || errno == EINTR, "Cannot wait for process");
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (!terminated && (interrupted || now.tv_sec >= deadline)) {
      timed_out = !interrupted;
      kill(-child, interrupted ? interrupted : SIGTERM);
      deadline = now.tv_sec + 15;
      terminated = 1;
    } else if (terminated && now.tv_sec >= deadline)
      kill(-child, SIGKILL);
    if (live && !terminated && now.tv_sec - last_output >= 10) {
      fprintf(stderr, "[WAIT] %s: still running (%lds elapsed, limit %lus)\n",
              argv[3], (long)(now.tv_sec - start.tv_sec), seconds);
      last_output = now.tv_sec;
    }
    if (live) {
      struct pollfd output = {master, POLLIN, 0};
      poll(&output, 1, 100);
      if (output.revents & (POLLHUP | POLLERR)) {
        struct timespec pause = {0, 100000000};
        nanosleep(&pause, NULL);
      }
    } else {
      struct timespec pause = {0, 100000000};
      nanosleep(&pause, NULL);
    }
  }
  /* The direct child can exit on TERM while a descendant ignores it. Do not
   * return from a cancelled/timed-out operation with that descendant alive. */
  if (terminated || interrupted)
    kill(-child, SIGKILL);
  if (live)
    close(master);
  if (timed_out) {
    if (live)
      fprintf(stderr, "%s timed out after %lu seconds\n", argv[3], seconds);
    else
      fputs("Operation timed out\n", stderr);
    exit(124);
  }
  if (interrupted)
    exit(128 + interrupted);
  exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
}
