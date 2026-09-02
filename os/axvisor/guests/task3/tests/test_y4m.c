#define _POSIX_C_SOURCE 200809L

#include "y4m.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, \
                    #condition);                                                \
            failures++;                                                         \
        }                                                                       \
    } while (0)

static char *write_fixture(const char *header, const char *marker,
                           size_t plane_bytes, int frames)
{
    char template[] = "/tmp/task3-y4m-XXXXXX";
    int descriptor = mkstemp(template);
    FILE *stream;
    size_t index;
    int frame;
    char *path;

    CHECK(descriptor >= 0);
    if (descriptor < 0) {
        return NULL;
    }
    stream = fdopen(descriptor, "wb");
    CHECK(stream != NULL);
    if (stream == NULL) {
        close(descriptor);
        unlink(template);
        return NULL;
    }
    fputs(header, stream);
    for (frame = 0; frame < frames; frame++) {
        fputs(marker, stream);
        for (index = 0; index < plane_bytes; index++) {
            fputc((frame + (int)index) & 0xff, stream);
        }
    }
    CHECK(fclose(stream) == 0);
    path = malloc(strlen(template) + 1);
    CHECK(path != NULL);
    if (path != NULL) {
        strcpy(path, template);
    }
    return path;
}

static void remove_fixture(char *path)
{
    if (path != NULL) {
        unlink(path);
        free(path);
    }
}

static void test_valid_frames_and_eof(void)
{
    char *path = write_fixture(
        "YUV4MPEG2 W32 H32 F10:1 Ip A1:1 Cmono\n", "FRAME\n", 1024, 2);
    y4m_reader_t reader;
    uint8_t pixels[1024];
    uint32_t frame_id = 99;

    CHECK(y4m_reader_open(&reader, path) == Y4M_OK);
    CHECK(reader.width == 32 && reader.height == 32);
    CHECK(reader.fps_numerator == 10 && reader.fps_denominator == 1);
    CHECK(y4m_reader_next(&reader, pixels, sizeof(pixels), &frame_id) == Y4M_OK);
    CHECK(frame_id == 0 && pixels[0] == 0 && pixels[1023] == 255);
    CHECK(y4m_reader_next(&reader, pixels, sizeof(pixels), &frame_id) == Y4M_OK);
    CHECK(frame_id == 1 && pixels[0] == 1);
    CHECK(y4m_reader_next(&reader, pixels, sizeof(pixels), &frame_id) == Y4M_EOF);
    y4m_reader_close(&reader);
    remove_fixture(path);
}

static void test_rejects_unsupported_headers(void)
{
    char *wrong_size = write_fixture(
        "YUV4MPEG2 W64 H32 F10:1 Ip A1:1 Cmono\n", "FRAME\n", 1024, 0);
    char *wrong_chroma = write_fixture(
        "YUV4MPEG2 W32 H32 F10:1 Ip A1:1 C420\n", "FRAME\n", 1024, 0);
    char *wrong_fps = write_fixture(
        "YUV4MPEG2 W32 H32 F30:1 Ip A1:1 Cmono\n", "FRAME\n", 1024, 0);
    y4m_reader_t reader;

    CHECK(y4m_reader_open(&reader, wrong_size) == Y4M_UNSUPPORTED_FORMAT);
    CHECK(y4m_reader_open(&reader, wrong_chroma) == Y4M_UNSUPPORTED_FORMAT);
    CHECK(y4m_reader_open(&reader, wrong_fps) == Y4M_UNSUPPORTED_FORMAT);
    remove_fixture(wrong_size);
    remove_fixture(wrong_chroma);
    remove_fixture(wrong_fps);
}

static void test_rejects_bad_marker_and_truncated_plane(void)
{
    char *bad_marker = write_fixture(
        "YUV4MPEG2 W32 H32 F10:1 Ip A1:1 Cmono\n", "BROKEN\n", 1024, 1);
    char *truncated = write_fixture(
        "YUV4MPEG2 W32 H32 F10:1 Ip A1:1 Cmono\n", "FRAME tag=value\n", 1000, 1);
    y4m_reader_t reader;
    uint8_t pixels[1024];
    uint32_t frame_id;

    CHECK(y4m_reader_open(&reader, bad_marker) == Y4M_OK);
    CHECK(y4m_reader_next(&reader, pixels, sizeof(pixels), &frame_id) ==
          Y4M_MALFORMED_FRAME);
    y4m_reader_close(&reader);
    CHECK(y4m_reader_open(&reader, truncated) == Y4M_OK);
    CHECK(y4m_reader_next(&reader, pixels, sizeof(pixels), &frame_id) ==
          Y4M_TRUNCATED_FRAME);
    y4m_reader_close(&reader);
    remove_fixture(bad_marker);
    remove_fixture(truncated);
}

static void test_rejects_small_output_buffer(void)
{
    char *path = write_fixture(
        "YUV4MPEG2 W32 H32 F10:1 Ip A1:1 Cmono\n", "FRAME\n", 1024, 1);
    y4m_reader_t reader;
    uint8_t pixels[1000];
    uint32_t frame_id;

    CHECK(y4m_reader_open(&reader, path) == Y4M_OK);
    CHECK(y4m_reader_next(&reader, pixels, sizeof(pixels), &frame_id) ==
          Y4M_BUFFER_TOO_SMALL);
    y4m_reader_close(&reader);
    remove_fixture(path);
}

int main(void)
{
    test_valid_frames_and_eof();
    test_rejects_unsupported_headers();
    test_rejects_bad_marker_and_truncated_plane();
    test_rejects_small_output_buffer();

    if (failures != 0) {
        fprintf(stderr, "test_y4m: %d failure(s)\n", failures);
        return 1;
    }
    puts("test_y4m: PASS");
    return 0;
}
