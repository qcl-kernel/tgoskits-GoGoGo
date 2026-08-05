#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct schedstat_reader {
	int fd;
	int stat_fd;
	int wchan_fd;
	long tid;
	uint64_t previous_exec_ns;
	uint64_t previous_run_delay_ns;
	int has_previous;
};

static void die(const char *message)
{
	perror(message);
	exit(EXIT_FAILURE);
}

static uint64_t timespec_to_ns(const struct timespec *value)
{
	return (uint64_t)value->tv_sec * 1000000000ULL + (uint64_t)value->tv_nsec;
}

static uint64_t monotonic_raw_ns(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC_RAW, &now) != 0) {
		die("clock_gettime(CLOCK_MONOTONIC_RAW)");
	}
	return timespec_to_ns(&now);
}

static unsigned long parse_unsigned(const char *text, const char *name)
{
	char *end = NULL;
	unsigned long value;

	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0') {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		exit(EXIT_FAILURE);
	}
	return value;
}

static void timestamp_stream(const char *raw_path, const char *timestamp_path)
{
	FILE *raw = fopen(raw_path, "w");
	FILE *timestamped = fopen(timestamp_path, "w");
	char *line = NULL;
	size_t capacity = 0;
	ssize_t length;
	uint64_t line_number = 0;

	if (raw == NULL || timestamped == NULL) {
		die("open timestamp-stream output");
	}
	if (fprintf(timestamped, "host_monotonic_raw_ns\tline_no\tconsole\n") < 0) {
		die("write timestamp-stream header");
	}
	while ((length = getline(&line, &capacity, stdin)) >= 0) {
		const uint64_t timestamp_ns = monotonic_raw_ns();
		ssize_t text_length = length;

		line_number++;
		if (fwrite(line, 1, (size_t)length, raw) != (size_t)length) {
			die("write raw console");
		}
		while (text_length > 0 &&
		       (line[text_length - 1] == '\n' || line[text_length - 1] == '\r')) {
			text_length--;
		}
		if (fprintf(timestamped, "%" PRIu64 "\t%" PRIu64 "\t", timestamp_ns,
			    line_number) < 0) {
			die("write timestamp prefix");
		}
		for (ssize_t index = 0; index < text_length; index++) {
			const char character = line[index];

			if (fputc(character == '\t' ? ' ' : character, timestamped) == EOF) {
				die("write timestamped console");
			}
		}
		if (fputc('\n', timestamped) == EOF || fflush(raw) != 0 ||
		    fflush(timestamped) != 0) {
			die("flush timestamp-stream output");
		}
	}
	if (ferror(stdin)) {
		die("read console stream");
	}
	free(line);
	if (fclose(raw) != 0 || fclose(timestamped) != 0) {
		die("close timestamp-stream output");
	}
}

static void read_schedstat(struct schedstat_reader *reader, uint64_t *exec_ns,
			   uint64_t *run_delay_ns, uint64_t *timeslices)
{
	char buffer[256];
	ssize_t length;

	if (lseek(reader->fd, 0, SEEK_SET) < 0) {
		die("rewind schedstat");
	}
	length = read(reader->fd, buffer, sizeof(buffer) - 1);
	if (length <= 0) {
		die("read schedstat");
	}
	buffer[length] = '\0';
	if (sscanf(buffer, "%" SCNu64 " %" SCNu64 " %" SCNu64, exec_ns,
		   run_delay_ns, timeslices) != 3) {
		fprintf(stderr, "invalid schedstat for tid %ld: %s\n", reader->tid, buffer);
		exit(EXIT_FAILURE);
	}
}

static ssize_t read_proc_file(int fd, char *buffer, size_t capacity, const char *name)
{
	ssize_t length;

	if (lseek(fd, 0, SEEK_SET) < 0) {
		die(name);
	}
	length = read(fd, buffer, capacity - 1);
	if (length <= 0) {
		die(name);
	}
	buffer[length] = '\0';
	return length;
}

static void read_task_context(struct schedstat_reader *reader, char *state,
			      long *processor, char *wchan, size_t wchan_capacity)
{
	char stat_buffer[2048];
	char *rest;
	char *save = NULL;
	char *token;
	int field = 3;
	ssize_t wchan_length;

	read_proc_file(reader->stat_fd, stat_buffer, sizeof(stat_buffer), "read task stat");
	rest = strrchr(stat_buffer, ')');
	if (rest == NULL || rest[1] != ' ') {
		fprintf(stderr, "invalid task stat for TID %ld\n", reader->tid);
		exit(EXIT_FAILURE);
	}
	rest += 2;
	*state = '?';
	*processor = -1;
	for (token = strtok_r(rest, " ", &save); token != NULL;
	     token = strtok_r(NULL, " ", &save), field++) {
		if (field == 3) {
			*state = token[0];
		} else if (field == 39) {
			char *end = NULL;

			errno = 0;
			*processor = strtol(token, &end, 10);
			if (errno != 0 || end == token || (*end != '\0' && *end != '\n')) {
				fprintf(stderr, "invalid processor field for TID %ld\n", reader->tid);
				exit(EXIT_FAILURE);
			}
			break;
		}
	}
	if (*state == '?' || *processor < 0) {
		fprintf(stderr, "incomplete task stat for TID %ld\n", reader->tid);
		exit(EXIT_FAILURE);
	}
	wchan_length = read_proc_file(reader->wchan_fd, wchan, wchan_capacity,
				      "read task wchan");
	while (wchan_length > 0 &&
	       (wchan[wchan_length - 1] == '\n' || wchan[wchan_length - 1] == '\r')) {
		wchan[--wchan_length] = '\0';
	}
	if (wchan_length == 0) {
		snprintf(wchan, wchan_capacity, "?");
	}
	for (ssize_t index = 0; index < wchan_length; index++) {
		if (wchan[index] == '\t' || wchan[index] == ' ') {
			wchan[index] = '_';
		}
	}
}

static void add_ns(struct timespec *value, uint64_t nanoseconds)
{
	value->tv_sec += (time_t)(nanoseconds / 1000000000ULL);
	value->tv_nsec += (long)(nanoseconds % 1000000000ULL);
	if (value->tv_nsec >= 1000000000L) {
		value->tv_sec++;
		value->tv_nsec -= 1000000000L;
	}
}

static void check_clock_nanosleep_result(int result)
{
	if (result == 0 || result == EINTR) {
		return;
	}
	fprintf(stderr, "clock_nanosleep(CLOCK_MONOTONIC): %s (error %d)\n",
		strerror(result), result);
	exit(EXIT_FAILURE);
}

static void sample_schedstat(const char *output_path, unsigned long duration_ms,
			     unsigned long interval_us, int tid_count, char **tid_text)
{
	const char *proc_root = getenv("AXVISOR_PROC_ROOT");
	struct schedstat_reader *readers;
	struct timespec deadline;
	struct timespec end;
	FILE *output;

	if (duration_ms == 0 || interval_us == 0 || tid_count == 0) {
		fprintf(stderr, "duration, interval, and TID list must be non-zero\n");
		exit(EXIT_FAILURE);
	}
	if (proc_root == NULL || *proc_root == '\0') {
		proc_root = "/proc";
	}
	readers = calloc((size_t)tid_count, sizeof(*readers));
	if (readers == NULL) {
		die("allocate schedstat readers");
	}
	for (int index = 0; index < tid_count; index++) {
		char path[PATH_MAX];
		const unsigned long tid = parse_unsigned(tid_text[index], "TID");

		if (tid == 0 || tid > LONG_MAX) {
			fprintf(stderr, "TID out of range: %s\n", tid_text[index]);
			exit(EXIT_FAILURE);
		}
		readers[index].tid = (long)tid;
		if (snprintf(path, sizeof(path), "%s/%lu/schedstat", proc_root, tid) >=
		    (int)sizeof(path)) {
			fprintf(stderr, "schedstat path is too long for TID %lu\n", tid);
			exit(EXIT_FAILURE);
		}
		readers[index].fd = open(path, O_RDONLY | O_CLOEXEC);
		if (readers[index].fd < 0) {
			die("open schedstat");
		}
		if (snprintf(path, sizeof(path), "%s/%lu/stat", proc_root, tid) >=
		    (int)sizeof(path)) {
			fprintf(stderr, "stat path is too long for TID %lu\n", tid);
			exit(EXIT_FAILURE);
		}
		readers[index].stat_fd = open(path, O_RDONLY | O_CLOEXEC);
		if (readers[index].stat_fd < 0) {
			die("open task stat");
		}
		if (snprintf(path, sizeof(path), "%s/%lu/wchan", proc_root, tid) >=
		    (int)sizeof(path)) {
			fprintf(stderr, "wchan path is too long for TID %lu\n", tid);
			exit(EXIT_FAILURE);
		}
		readers[index].wchan_fd = open(path, O_RDONLY | O_CLOEXEC);
		if (readers[index].wchan_fd < 0) {
			die("open task wchan");
		}
	}
	output = fopen(output_path, "w");
	if (output == NULL) {
		die("open schedstat output");
	}
	if (fprintf(output,
		    "host_monotonic_raw_ns\ttid\tstate\tprocessor\twchan\texec_ns\t"
		    "run_delay_ns\ttimeslices\tdelta_exec_ns\tdelta_run_delay_ns\n") < 0) {
		die("write schedstat header");
	}
	if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0) {
		die("clock_gettime(CLOCK_MONOTONIC)");
	}
	end = deadline;
	add_ns(&end, (uint64_t)duration_ms * 1000000ULL);
	for (;;) {
		struct timespec now;
		const uint64_t timestamp_ns = monotonic_raw_ns();

		for (int index = 0; index < tid_count; index++) {
			struct schedstat_reader *reader = &readers[index];
			uint64_t exec_ns;
			uint64_t run_delay_ns;
			uint64_t timeslices;
			uint64_t delta_exec_ns = 0;
			uint64_t delta_run_delay_ns = 0;
			char state;
			long processor;
			char wchan[256];

			read_schedstat(reader, &exec_ns, &run_delay_ns, &timeslices);
			read_task_context(reader, &state, &processor, wchan, sizeof(wchan));
			if (reader->has_previous) {
				if (exec_ns < reader->previous_exec_ns ||
				    run_delay_ns < reader->previous_run_delay_ns) {
					fprintf(stderr, "schedstat counter moved backwards for TID %ld\n",
						reader->tid);
					exit(EXIT_FAILURE);
				}
				delta_exec_ns = exec_ns - reader->previous_exec_ns;
				delta_run_delay_ns = run_delay_ns - reader->previous_run_delay_ns;
			}
			if (fprintf(output,
				    "%" PRIu64 "\t%ld\t%c\t%ld\t%s\t%" PRIu64 "\t%" PRIu64
				    "\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64 "\n",
				    timestamp_ns, reader->tid, state, processor, wchan,
				    exec_ns, run_delay_ns, timeslices,
				    delta_exec_ns, delta_run_delay_ns) < 0) {
				die("write schedstat sample");
			}
			reader->previous_exec_ns = exec_ns;
			reader->previous_run_delay_ns = run_delay_ns;
			reader->has_previous = 1;
		}
		if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
			die("clock_gettime(CLOCK_MONOTONIC)");
		}
		if (now.tv_sec > end.tv_sec ||
		    (now.tv_sec == end.tv_sec && now.tv_nsec >= end.tv_nsec)) {
			break;
		}
		add_ns(&deadline, (uint64_t)interval_us * 1000ULL);
		int sleep_result;

		do {
			sleep_result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME,
						       &deadline, NULL);
		} while (sleep_result == EINTR);
		check_clock_nanosleep_result(sleep_result);
	}
	if (fclose(output) != 0) {
		die("close schedstat output");
	}
	for (int index = 0; index < tid_count; index++) {
		if (close(readers[index].fd) != 0 || close(readers[index].stat_fd) != 0 ||
		    close(readers[index].wchan_fd) != 0) {
			die("close proc task data");
		}
	}
	free(readers);
}

int main(int argc, char **argv)
{
#ifdef AXVISOR_SCHED_PROBE_TEST
	if (argc == 3 && strcmp(argv[1], "test-clock-nanosleep-result") == 0) {
		const unsigned long result = parse_unsigned(argv[2], "clock-nanosleep-result");

		if (result > INT_MAX) {
			fprintf(stderr, "clock-nanosleep-result out of range: %s\n", argv[2]);
			return EXIT_FAILURE;
		}
		check_clock_nanosleep_result((int)result);
		return EXIT_SUCCESS;
	}
#endif
	if (argc == 4 && strcmp(argv[1], "timestamp-stream") == 0) {
		timestamp_stream(argv[2], argv[3]);
		return EXIT_SUCCESS;
	}
	if (argc >= 6 && strcmp(argv[1], "schedstat") == 0) {
		const unsigned long duration_ms = parse_unsigned(argv[3], "duration-ms");
		const unsigned long interval_us = parse_unsigned(argv[4], "interval-us");

		sample_schedstat(argv[2], duration_ms, interval_us, argc - 5, &argv[5]);
		return EXIT_SUCCESS;
	}
	fprintf(stderr,
		"usage: %s timestamp-stream <raw-console> <timestamped-console>\n"
		"       %s schedstat <output.tsv> <duration-ms> <interval-us> <tid>...\n",
		argv[0], argv[0]);
	return EXIT_FAILURE;
}
