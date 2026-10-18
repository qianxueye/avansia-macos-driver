#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
static int inject_wait_eintr;
static pid_t fixture_waitpid(pid_t pid, int *status, int options);
#define waitpid fixture_waitpid
#define main ippeveprinter_program_main
#include "../build/ipp/cups-2.4.14/tools/ippeveprinter.c"
#undef main
#undef waitpid
#include <assert.h>

static pid_t fixture_waitpid(pid_t pid, int *status, int options)
{
  if (inject_wait_eintr && options == WNOHANG)
  {
    inject_wait_eintr = 0;
    errno = EINTR;
    return (-1);
  }
  return (waitpid(pid, status, options));
}

static void *status_writer(void *context)
{
  ippeve_printer_t *printer = context;
  int i;
  for (i = 0; i < 20000; i ++)
  {
    status_apply(printer, "ready", i % 101, (i + 1) % 101);
    usleep(50);
  }
  return (NULL);
}

static ipp_t *snapshot(ippeve_printer_t *printer)
{
  static const char * const requested[] = {
    "marker-levels", "printer-supply", "printer-supply-description",
    "avansia-connection-state", "printer-state", "printer-state-message", "printer-state-reasons"
  };
  ippeve_client_t client = {0};
  client.printer = printer;
  client.request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
  client.response = ippNew();
  strlcpy(client.hostname, "synthetic-fixture", sizeof(client.hostname));
  client.operation_id = IPP_OP_GET_PRINTER_ATTRIBUTES;
  ippAddStrings(client.request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes",
                sizeof(requested) / sizeof(requested[0]), NULL, requested);
  ipp_get_printer_attributes(&client);
  ippDelete(client.request);
  return (client.response);
}

static void expect_levels(ippeve_printer_t *printer, int ribbon, int film)
{
  ipp_t *response = snapshot(printer);
  ipp_attribute_t *attr = ippFindAttribute(response, "marker-levels", IPP_TAG_INTEGER);
  ipp_attribute_t *supply = ippFindAttribute(response, "printer-supply", IPP_TAG_STRING);
  char expected[32];
  int length;
  const char *value;
  assert(attr && ippGetCount(attr) == 2);
  assert(ippGetInteger(attr, 0) == ribbon && ippGetInteger(attr, 1) == film);
  assert(supply && ippGetCount(supply) == 2);
  value = ippGetOctetString(supply, 0, &length);
  snprintf(expected, sizeof(expected), "level=%d;", ribbon);
  assert(value && memmem(value, (size_t)length, expected, strlen(expected)));
  value = ippGetOctetString(supply, 1, &length);
  snprintf(expected, sizeof(expected), "level=%d;", film);
  assert(value && memmem(value, (size_t)length, expected, strlen(expected)));
  ippDelete(response);
}

static void finish_probe(ippeve_printer_t *printer, ippeve_status_t *probe, double now)
{
  int attempts;
  for (attempts = 0; probe->pid && attempts < 5000; attempts ++)
  {
    status_tick(printer, probe, now);
    usleep(1000);
  }
  assert(probe->pid == 0 && probe->fd == -1);
}

static int helper(void)
{
  const char *mode = getenv("IPP_STATUS_FIXTURE");
  if (!mode) return (2);
  if (!strcmp(mode, "hang")) { sleep(60); return (0); }
  if (!strcmp(mode, "descendant"))
  {
    pid_t child = fork();
    FILE *file;
    if (child < 0) return (2);
    if (!child) { sleep(60); _exit(0); }
    file = fopen(getenv("IPP_STATUS_PID_FILE"), "w");
    if (!file) return (2);
    fprintf(file, "%d\n", child);
    fclose(file);
    sleep(60);
    return (0);
  }
  if (!strcmp(mode, "overflow"))
  {
    char bytes[512];
    memset(bytes, 'x', sizeof(bytes));
    fwrite(bytes, 1, sizeof(bytes), stdout);
    return (0);
  }
  if (!strcmp(mode, "nul"))
  {
    static const char bytes[] = "AVANSIA_STATUS_V1 ready 90 80\0hidden";
    fwrite(bytes, 1, sizeof(bytes) - 1, stdout);
    return (0);
  }
  if (!strcmp(mode, "nonzero"))
  {
    puts("AVANSIA_STATUS_V1 ready 90 80");
    return (1);
  }
  puts(mode);
  return (0);
}

int main(int argc, char **argv)
{
  ippeve_printer_t printer = {0};
  ippeve_job_t job = {0};
  ippeve_status_t probe = { .fd = -1 };
  ipp_t *response;
  ipp_attribute_t *attr;
  char executable[PATH_MAX], connection[16];
  int ribbon, film, status;
  pid_t child;
  double begin;
  static const char * const invalid[] = {
    "", "AVANSIA_STATUS_V2 ready 1 2", "AVANSIA_STATUS_V1 offline 1 2",
    "AVANSIA_STATUS_V1 ready -2 0", "AVANSIA_STATUS_V1 ready 101 0",
    "AVANSIA_STATUS_V1 ready 1.5 2", "AVANSIA_STATUS_V1 ready 0 0 trailing",
    "AVANSIA_STATUS_V1 ready 0", "AVANSIA_STATUS_V1 ready 99999999 0"
  };
  size_t i;
  if (argc == 2 && !strcmp(argv[1], "ipp-status")) return (helper());
  if (argc == 2 && getenv("IPP_JOB_FIXTURE"))
  {
    const char *media = getenv("IPP_MEDIA_DEFAULT"), *quality = getenv("IPP_PRINT_QUALITY_DEFAULT");
    if (!(media && quality && !strcmp(media, "iso_id-1_53.98x85.6mm") && !strcmp(quality, "high")))
    {
      fprintf(stderr, "ERROR: Synthetic defaults mismatch: media=%s quality=%s\n", media ? media : "missing", quality ? quality : "missing");
      return (1);
    }
    return (0);
  }
  assert(realpath(argv[0], executable));
  StatusCommand = executable;
  printer.attrs = ippNew();
  printer.state = IPP_PSTATE_IDLE;
  printer.start_time = printer.config_time = printer.state_time = time(NULL);
  _cupsRWInit(&printer.rwlock);

  for (i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i ++)
    assert(!status_parse(invalid[i], connection, &ribbon, &film));
  assert(status_parse("AVANSIA_STATUS_V1 unknown -1 0\n", connection, &ribbon, &film));
  assert(ribbon == -1 && film == 0);
  status_apply(&printer, "unknown", -1, 0);
  expect_levels(&printer, -1, 0);

  setenv("IPP_STATUS_FIXTURE", "AVANSIA_STATUS_V1 ready 90 80", 1);
  status_tick(&printer, &probe, 1000.0);
  assert(probe.pid && probe.next_poll == 1015.0 && probe.deadline == 1020.0);
  finish_probe(&printer, &probe, 1000.1);
  expect_levels(&printer, 90, 80);
  setenv("IPP_STATUS_FIXTURE", "AVANSIA_STATUS_V1 ready 0 -1", 1);
  status_tick(&printer, &probe, 1014.9);
  assert(probe.pid == 0);
  expect_levels(&printer, 90, 80);
  status_tick(&printer, &probe, 1015.0);
  finish_probe(&printer, &probe, 1015.1);
  expect_levels(&printer, 0, -1);

  for (i = 0; i < 4; i ++)
  {
    static const char * const modes[] = { "bad output", "overflow", "nul", "nonzero" };
    setenv("IPP_STATUS_FIXTURE", modes[i], 1);
    status_tick(&printer, &probe, 1100.0 + 20.0 * i);
    finish_probe(&printer, &probe, 1100.1 + 20.0 * i);
    expect_levels(&printer, -1, -1);
    assert(!strcmp(printer.connection, "unknown"));
  }

  setenv("IPP_STATUS_FIXTURE", "hang", 1);
  status_tick(&printer, &probe, 1300.0);
  child = probe.pid;
  assert(child > 0);
  inject_wait_eintr = 1;
  status_tick(&printer, &probe, 1310.0);
  assert(probe.pid == child && !probe.failed);
  status_tick(&printer, &probe, 1315.0);
  assert(probe.pid == child);
  begin = status_now();
  status_tick(&printer, &probe, 1320.0);
  assert(status_now() - begin < 0.2 && probe.failed == 2);
  finish_probe(&printer, &probe, 1320.1);
  assert(waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD);
  expect_levels(&printer, -1, -1);

  printer.state_reasons = IPPEVE_PREASON_COVER_OPEN;
  status_apply(&printer, "busy", 25, 50);
  response = snapshot(&printer);
  assert(ippGetInteger(ippFindAttribute(response, "printer-state", IPP_TAG_ENUM), 0) == IPP_PSTATE_PROCESSING);
  assert(strstr(ippGetString(ippFindAttribute(response, "printer-state-message", IPP_TAG_TEXT), 0, NULL), "deferred"));
  assert(printer.state == IPP_PSTATE_IDLE && printer.state_reasons == IPPEVE_PREASON_COVER_OPEN);
  ippDelete(response);

  job.printer = &printer;
  job.id = 17;
  job.state = IPP_JSTATE_PROCESSING;
  printer.active_job = &job;
  printer.state = IPP_PSTATE_PROCESSING;
  status_apply(&printer, "disconnected", -1, -1);
  response = snapshot(&printer);
  assert(ippGetInteger(ippFindAttribute(response, "printer-state", IPP_TAG_ENUM), 0) == IPP_PSTATE_PROCESSING);
  assert(job.state == IPP_JSTATE_PROCESSING && printer.active_job == &job && job.completed == 0);
  ippDelete(response);

  printer.state = IPP_PSTATE_STOPPED;
  printer.state_reasons |= IPPEVE_PREASON_OTHER;
  job.state = IPP_JSTATE_STOPPED;
  job.message = "Retained physical completion uncertainty.";
  status_apply(&printer, "ready", 100, 100);
  response = snapshot(&printer);
  assert(ippGetInteger(ippFindAttribute(response, "printer-state", IPP_TAG_ENUM), 0) == IPP_PSTATE_STOPPED);
  assert(!strcmp(ippGetString(ippFindAttribute(response, "printer-state-message", IPP_TAG_TEXT), 0, NULL), job.message));
  attr = ippFindAttribute(response, "printer-state-reasons", IPP_TAG_KEYWORD);
  assert(ippContainsString(attr, "other-error") && ippContainsString(attr, "cover-open-error"));
  assert(job.state == IPP_JSTATE_STOPPED && printer.active_job == &job && !job.completed);
  ippDelete(response);

  printer.active_job = NULL;
  printer.state = IPP_PSTATE_IDLE;
  status_apply(&printer, "disconnected", -1, -1);
  response = snapshot(&printer);
  assert(ippGetInteger(ippFindAttribute(response, "printer-state", IPP_TAG_ENUM), 0) == IPP_PSTATE_STOPPED);
  ippDelete(response);
  status_apply(&printer, "unknown", -1, -1);
  response = snapshot(&printer);
  assert(ippGetInteger(ippFindAttribute(response, "printer-state", IPP_TAG_ENUM), 0) == IPP_PSTATE_IDLE);
  assert(strstr(ippGetString(ippFindAttribute(response, "printer-state-message", IPP_TAG_TEXT), 0, NULL), "unavailable"));
  ippDelete(response);
  {
    char directory[] = "/private/tmp/avansia-ipp-stress.XXXXXX", filename[PATH_MAX], pidfile[PATH_MAX];
    _cups_thread_t writer;
    int i, descendant, attempts;
    FILE *file;
    assert(mkdtemp(directory));
    printer.directory = directory;
    printer.command = executable;
    printer.device_uri = "file:///dev/null";
    printer.state_reasons = IPPEVE_PREASON_NONE;
    ippAddString(printer.attrs, IPP_TAG_PRINTER, IPP_TAG_KEYWORD, "media-default", NULL, "iso_id-1_53.98x85.6mm");
    ippAddInteger(printer.attrs, IPP_TAG_PRINTER, IPP_TAG_ENUM, "print-quality-default", 5);
    snprintf(filename, sizeof(filename), "%s/input.pdf", directory);
    setenv("IPP_JOB_FIXTURE", "1", 1);
    writer = _cupsThreadCreate(status_writer, &printer);
    assert(writer);
    for (i = 1; i <= 25; i ++)
    {
      ippeve_job_t stress_job = {0};
      stress_job.printer = &printer;
      stress_job.attrs = ippNew();
      stress_job.id = i;
      stress_job.fd = -1;
      stress_job.filename = filename;
      stress_job.format = "application/pdf";
      stress_job.state = IPP_JSTATE_PENDING;
      ippAddInteger(stress_job.attrs, IPP_TAG_JOB, IPP_TAG_INTEGER, "job-id", i);
      ippAddString(stress_job.attrs, IPP_TAG_JOB, IPP_TAG_NAME, "job-name", NULL, "Synthetic environment test");
      _cupsRWLockWrite(&printer.rwlock);
      printer.active_job = &stress_job;
      printer.next_job_id = i + 1;
      _cupsRWUnlock(&printer.rwlock);
      process_job(&stress_job);
      assert(stress_job.state == IPP_JSTATE_COMPLETED && printer.active_job == NULL);
      ippDelete(stress_job.attrs);
      free(stress_job.message);
    }
    _cupsThreadWait(writer);
    unsetenv("IPP_JOB_FIXTURE");
    snprintf(pidfile, sizeof(pidfile), "%s/descendant.pid", directory);
    setenv("IPP_STATUS_PID_FILE", pidfile, 1);
    setenv("IPP_STATUS_FIXTURE", "descendant", 1);
    status_tick(&printer, &probe, 1500.0);
    child = probe.pid;
    descendant = 0;
    for (attempts = 0; attempts < 5000; attempts ++)
    {
      file = fopen(pidfile, "r");
      if (file)
      {
        if (fscanf(file, "%d", &descendant) != 1) descendant = 0;
        fclose(file);
      }
      if (descendant > 0) break;
      usleep(1000);
    }
    assert(descendant > 0);
    assert(getpgid(descendant) == child);
    status_stop(&probe);
    assert(!probe.pid && probe.fd == -1);
    assert(waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD);
    for (attempts = 0; !kill(descendant, 0) && attempts < 5000; attempts ++) usleep(1000);
    assert(kill(descendant, 0) == -1 && errno == ESRCH);
    unlink(pidfile);
    rmdir(directory);
    puts("PASS: 25 default-environment jobs overlapped 20000 status updates; EINTR preserved; shutdown killed/reaped helper group and descendant.");
  }
  ippDelete(printer.attrs);
  puts("PASS: live levels, unknown versus zero, strict parser, bounded child/output, cadence/no overlap, virtual states and retained jobs.");
  return (0);
}
