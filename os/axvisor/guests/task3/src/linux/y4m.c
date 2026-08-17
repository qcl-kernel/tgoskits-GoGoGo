#include "y4m.h"

#include <stdlib.h>
#include <string.h>

enum { Y4M_LINE_CAPACITY = 256 };

static int parse_unsigned(const char *text, uint32_t *value)
{
    char *end;
    unsigned long parsed;

    if (text == NULL || *text == '\0') {
        return 0;
    }
    parsed = strtoul(text, &end, 10);
    if (*end != '\0' || parsed > UINT32_MAX) {
        return 0;
    }
    *value = (uint32_t)parsed;
    return 1;
}

static int parse_ratio(const char *text, uint32_t *numerator,
                       uint32_t *denominator)
{
    char copy[32];
    char *separator;

    if (strlen(text) >= sizeof(copy)) {
        return 0;
    }
    strcpy(copy, text);
    separator = strchr(copy, ':');
    if (separator == NULL) {
        return 0;
    }
    *separator = '\0';
    return parse_unsigned(copy, numerator) &&
           parse_unsigned(separator + 1, denominator) && *denominator != 0;
}

static y4m_result_t parse_header(y4m_reader_t *reader, char *line)
{
    char *token;
    int have_width = 0;
    int have_height = 0;
    int have_fps = 0;
    int have_chroma = 0;
    int supported_chroma = 0;

    token = strtok(line, " ");
    if (token == NULL || strcmp(token, "YUV4MPEG2") != 0) {
        return Y4M_MALFORMED_HEADER;
    }
    while ((token = strtok(NULL, " ")) != NULL) {
        switch (token[0]) {
        case 'W':
            have_width = parse_unsigned(token + 1, &reader->width);
            break;
        case 'H':
            have_height = parse_unsigned(token + 1, &reader->height);
            break;
        case 'F':
            have_fps = parse_ratio(token + 1, &reader->fps_numerator,
                                   &reader->fps_denominator);
            break;
        case 'C':
            have_chroma = 1;
            supported_chroma = strcmp(token + 1, "mono") == 0;
            break;
        default:
            break;
        }
    }
    if (!have_width || !have_height || !have_fps || !have_chroma) {
        return Y4M_MALFORMED_HEADER;
    }
    if (!supported_chroma || reader->width != TASK3_Y4M_WIDTH ||
        reader->height != TASK3_Y4M_HEIGHT || reader->fps_numerator != 10 ||
        reader->fps_denominator != 1) {
        return Y4M_UNSUPPORTED_FORMAT;
    }
    return Y4M_OK;
}

y4m_result_t y4m_reader_open(y4m_reader_t *reader, const char *path)
{
    char line[Y4M_LINE_CAPACITY];
    size_t length;
    y4m_result_t result;

    if (reader == NULL || path == NULL) {
        return Y4M_INVALID_ARGUMENT;
    }
    memset(reader, 0, sizeof(*reader));
    reader->stream = fopen(path, "rb");
    if (reader->stream == NULL) {
        return Y4M_IO_ERROR;
    }
    if (fgets(line, sizeof(line), reader->stream) == NULL) {
        result = ferror(reader->stream) ? Y4M_IO_ERROR : Y4M_MALFORMED_HEADER;
        y4m_reader_close(reader);
        return result;
    }
    length = strlen(line);
    if (length == 0 || line[length - 1] != '\n') {
        y4m_reader_close(reader);
        return Y4M_MALFORMED_HEADER;
    }
    line[length - 1] = '\0';
    result = parse_header(reader, line);
    if (result != Y4M_OK) {
        y4m_reader_close(reader);
    }
    return result;
}

y4m_result_t y4m_reader_next(y4m_reader_t *reader, uint8_t *pixels,
                             size_t capacity, uint32_t *frame_id)
{
    char marker[Y4M_LINE_CAPACITY];
    size_t length;
    size_t received;

    if (reader == NULL || reader->stream == NULL || pixels == NULL ||
        frame_id == NULL) {
        return Y4M_INVALID_ARGUMENT;
    }
    if (capacity < TASK3_Y4M_FRAME_BYTES) {
        return Y4M_BUFFER_TOO_SMALL;
    }
    if (fgets(marker, sizeof(marker), reader->stream) == NULL) {
        return ferror(reader->stream) ? Y4M_IO_ERROR : Y4M_EOF;
    }
    length = strlen(marker);
    if (length == 0 || marker[length - 1] != '\n' ||
        strncmp(marker, "FRAME", 5) != 0 ||
        (marker[5] != '\n' && marker[5] != ' ')) {
        return Y4M_MALFORMED_FRAME;
    }
    received = fread(pixels, 1, TASK3_Y4M_FRAME_BYTES, reader->stream);
    if (received != TASK3_Y4M_FRAME_BYTES) {
        return ferror(reader->stream) ? Y4M_IO_ERROR : Y4M_TRUNCATED_FRAME;
    }
    *frame_id = reader->next_frame_id++;
    return Y4M_OK;
}

void y4m_reader_close(y4m_reader_t *reader)
{
    if (reader != NULL && reader->stream != NULL) {
        fclose(reader->stream);
        reader->stream = NULL;
    }
}
