#ifndef TASK3_Y4M_H
#define TASK3_Y4M_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    TASK3_Y4M_WIDTH = 32,
    TASK3_Y4M_HEIGHT = 32,
    TASK3_Y4M_FRAME_BYTES = TASK3_Y4M_WIDTH * TASK3_Y4M_HEIGHT,
};

typedef enum {
    Y4M_OK = 0,
    Y4M_EOF = 1,
    Y4M_INVALID_ARGUMENT = -1,
    Y4M_IO_ERROR = -2,
    Y4M_MALFORMED_HEADER = -3,
    Y4M_UNSUPPORTED_FORMAT = -4,
    Y4M_MALFORMED_FRAME = -5,
    Y4M_TRUNCATED_FRAME = -6,
    Y4M_BUFFER_TOO_SMALL = -7,
} y4m_result_t;

typedef struct {
    FILE *stream;
    uint32_t width;
    uint32_t height;
    uint32_t fps_numerator;
    uint32_t fps_denominator;
    uint32_t next_frame_id;
} y4m_reader_t;

y4m_result_t y4m_reader_open(y4m_reader_t *reader, const char *path);
y4m_result_t y4m_reader_next(y4m_reader_t *reader, uint8_t *pixels,
                             size_t capacity, uint32_t *frame_id);
void y4m_reader_close(y4m_reader_t *reader);

#ifdef __cplusplus
}
#endif

#endif
