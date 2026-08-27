#include "cnn.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint32_t read_le32(const uint8_t bytes[4])
{
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
           (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint16_t read_le16(const uint8_t bytes[2])
{
    return (uint16_t)bytes[0] | (uint16_t)bytes[1] << 8;
}

int main(int argc, char **argv)
{
    uint8_t header[8];
    uint8_t pixels[CNN_INPUT_BYTES];
    uint8_t encoded_logits[12];
    uint8_t expected_class;
    uint8_t encoded_confidence[2];
    cnn_result_t result;
    FILE *stream;
    uint32_t count;
    uint32_t index;
    int output;

    if (cnn_infer_32x32(NULL, &result) != -1 ||
        cnn_infer_32x32(pixels, NULL) != -1) {
        fprintf(stderr, "null argument was not rejected\n");
        return 1;
    }

    if (argc != 2) {
        fprintf(stderr, "usage: cnn_runner GOLDEN_VECTORS\n");
        return 2;
    }
    stream = fopen(argv[1], "rb");
    if (stream == NULL) {
        perror("fopen");
        return 2;
    }
    if (fread(header, 1, sizeof(header), stream) != sizeof(header) ||
        memcmp(header, "T3GV", 4) != 0) {
        fprintf(stderr, "invalid golden vector header\n");
        fclose(stream);
        return 2;
    }
    count = read_le32(header + 4);
    for (index = 0; index < count; index++) {
        if (fread(pixels, 1, sizeof(pixels), stream) != sizeof(pixels) ||
            fread(encoded_logits, 1, sizeof(encoded_logits), stream) !=
                sizeof(encoded_logits) ||
            fread(&expected_class, 1, 1, stream) != 1 ||
            fread(encoded_confidence, 1, sizeof(encoded_confidence), stream) !=
                sizeof(encoded_confidence)) {
            fprintf(stderr, "truncated golden vector %u\n", index);
            fclose(stream);
            return 2;
        }
        if (cnn_infer_32x32(pixels, &result) != 0) {
            fprintf(stderr, "inference failed for vector %u\n", index);
            fclose(stream);
            return 1;
        }
        for (output = 0; output < CNN_OUTPUT_CLASSES; output++) {
            int32_t expected = (int32_t)read_le32(encoded_logits + output * 4);
            if (result.logits[output] != expected) {
                fprintf(stderr,
                        "vector %u logit %d: got %d expected %d\n", index,
                        output, result.logits[output], expected);
                fclose(stream);
                return 1;
            }
        }
        if (result.klass != expected_class) {
            fprintf(stderr, "vector %u class: got %u expected %u\n", index,
                    result.klass, expected_class);
            fclose(stream);
            return 1;
        }
        if (result.confidence_q15 != read_le16(encoded_confidence)) {
            fprintf(stderr, "vector %u confidence: got %u expected %u\n", index,
                    result.confidence_q15, read_le16(encoded_confidence));
            fclose(stream);
            return 1;
        }
    }
    if (fgetc(stream) != EOF) {
        fprintf(stderr, "trailing golden vector data\n");
        fclose(stream);
        return 2;
    }
    fclose(stream);
    printf("cnn_runner: PASS (%u vectors)\n", count);
    return 0;
}
