#ifndef TASK3_CNN_H
#define TASK3_CNN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    CNN_INPUT_WIDTH = 32,
    CNN_INPUT_HEIGHT = 32,
    CNN_INPUT_BYTES = CNN_INPUT_WIDTH * CNN_INPUT_HEIGHT,
    CNN_OUTPUT_CLASSES = 3,
};

typedef struct {
    int32_t logits[CNN_OUTPUT_CLASSES];
    uint8_t klass;
    uint16_t confidence_q15;
} cnn_result_t;

int cnn_infer_32x32(const uint8_t pixels[CNN_INPUT_BYTES], cnn_result_t *result);

#ifdef __cplusplus
}
#endif

#endif
