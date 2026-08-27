#include "cnn.h"

#include "model_weights.h"

#include <limits.h>
#include <stddef.h>

enum {
    CONV1_SIZE = TASK3_CONV1_OUTPUT_SIZE,
    CONV1_CHANNELS = TASK3_CONV1_CHANNELS,
    POOL_SIZE = TASK3_POOL_OUTPUT_SIZE,
    CONV2_SIZE = TASK3_CONV2_OUTPUT_SIZE,
    CONV2_CHANNELS = TASK3_CONV2_CHANNELS,
    SPATIAL_REGIONS = TASK3_SPATIAL_REGIONS,
    SPATIAL_FEATURES = TASK3_SPATIAL_FEATURES,
};

_Static_assert(CNN_INPUT_WIDTH == TASK3_INPUT_WIDTH, "model input width mismatch");
_Static_assert(CNN_INPUT_HEIGHT == TASK3_INPUT_HEIGHT, "model input height mismatch");
_Static_assert(CNN_OUTPUT_CLASSES == TASK3_OUTPUT_CLASSES, "model output mismatch");
_Static_assert(SPATIAL_FEATURES == SPATIAL_REGIONS * CONV2_CHANNELS,
               "model spatial feature mismatch");

static int add_product(int64_t *accumulator, int32_t left, int32_t right)
{
    int64_t product = (int64_t)left * right;

    if ((product > 0 && *accumulator > INT64_MAX - product) ||
        (product < 0 && *accumulator < INT64_MIN - product)) {
        return -1;
    }
    *accumulator += product;
    return 0;
}

static int requantize_relu(int64_t accumulator, int32_t multiplier, int shift,
                           int8_t *output)
{
    int64_t rounding;
    int64_t scaled;

    if (accumulator <= 0) {
        *output = 0;
        return 0;
    }
    if (multiplier <= 0 || shift <= 0 || shift >= 63) {
        return -1;
    }
    rounding = INT64_C(1) << (shift - 1);
    if (accumulator > (INT64_MAX - rounding) / multiplier) {
        return -1;
    }
    scaled = (accumulator * multiplier + rounding) >> shift;
    *output = scaled > 127 ? INT8_C(127) : (int8_t)scaled;
    return 0;
}

static int conv1(const uint8_t *pixels,
                 int8_t output[CONV1_SIZE][CONV1_SIZE][CONV1_CHANNELS])
{
    int row;
    int column;
    int channel;
    int kernel_row;
    int kernel_column;

    for (row = 0; row < CONV1_SIZE; row++) {
        for (column = 0; column < CONV1_SIZE; column++) {
            for (channel = 0; channel < CONV1_CHANNELS; channel++) {
                int64_t accumulator = TASK3_CONV1_BIAS[channel];
                for (kernel_row = 0; kernel_row < TASK3_KERNEL_SIZE; kernel_row++) {
                    for (kernel_column = 0; kernel_column < TASK3_KERNEL_SIZE;
                         kernel_column++) {
                        int input = 255 - pixels[(row + kernel_row) * CNN_INPUT_WIDTH +
                                                  column + kernel_column];
                        size_t weight_index =
                            ((size_t)channel * TASK3_KERNEL_SIZE + kernel_row) *
                                TASK3_KERNEL_SIZE +
                            kernel_column;
                        if (add_product(&accumulator, input,
                                        TASK3_CONV1_WEIGHTS[weight_index]) != 0) {
                            return -1;
                        }
                    }
                }
                if (requantize_relu(accumulator, TASK3_CONV1_MULTIPLIER,
                                    TASK3_CONV1_SHIFT,
                                    &output[row][column][channel]) != 0) {
                    return -1;
                }
            }
        }
    }
    return 0;
}

static void maxpool2(int8_t input[CONV1_SIZE][CONV1_SIZE][CONV1_CHANNELS],
                     int8_t output[POOL_SIZE][POOL_SIZE][CONV1_CHANNELS])
{
    int row;
    int column;
    int channel;
    int dy;
    int dx;

    for (row = 0; row < POOL_SIZE; row++) {
        for (column = 0; column < POOL_SIZE; column++) {
            for (channel = 0; channel < CONV1_CHANNELS; channel++) {
                int8_t maximum = 0;
                for (dy = 0; dy < 2; dy++) {
                    for (dx = 0; dx < 2; dx++) {
                        int8_t value = input[row * 2 + dy][column * 2 + dx][channel];
                        if (value > maximum) {
                            maximum = value;
                        }
                    }
                }
                output[row][column][channel] = maximum;
            }
        }
    }
}

static int conv2(int8_t input[POOL_SIZE][POOL_SIZE][CONV1_CHANNELS],
                 int8_t output[CONV2_SIZE][CONV2_SIZE][CONV2_CHANNELS])
{
    int row;
    int column;
    int output_channel;
    int input_channel;
    int kernel_row;
    int kernel_column;

    for (row = 0; row < CONV2_SIZE; row++) {
        for (column = 0; column < CONV2_SIZE; column++) {
            for (output_channel = 0; output_channel < CONV2_CHANNELS;
                 output_channel++) {
                int64_t accumulator = TASK3_CONV2_BIAS[output_channel];
                for (input_channel = 0; input_channel < CONV1_CHANNELS;
                     input_channel++) {
                    for (kernel_row = 0; kernel_row < TASK3_KERNEL_SIZE; kernel_row++) {
                        for (kernel_column = 0; kernel_column < TASK3_KERNEL_SIZE;
                             kernel_column++) {
                            size_t weight_index =
                                (((size_t)output_channel * CONV1_CHANNELS + input_channel) *
                                     TASK3_KERNEL_SIZE +
                                 kernel_row) *
                                    TASK3_KERNEL_SIZE +
                                kernel_column;
                            if (add_product(
                                    &accumulator,
                                    input[row + kernel_row][column + kernel_column]
                                         [input_channel],
                                    TASK3_CONV2_WEIGHTS[weight_index]) != 0) {
                                return -1;
                            }
                        }
                    }
                }
                if (requantize_relu(accumulator, TASK3_CONV2_MULTIPLIER,
                                    TASK3_CONV2_SHIFT,
                                    &output[row][column][output_channel]) != 0) {
                    return -1;
                }
            }
        }
    }
    return 0;
}

static void spatial_pool(
    int8_t input[CONV2_SIZE][CONV2_SIZE][CONV2_CHANNELS],
    int8_t features[SPATIAL_FEATURES])
{
    static const uint8_t starts[SPATIAL_REGIONS] = {0, 4, 9};
    static const uint8_t ends[SPATIAL_REGIONS] = {4, 9, 13};
    int region;
    int channel;
    int row;
    int column;

    for (region = 0; region < SPATIAL_REGIONS; region++) {
        int count = CONV2_SIZE * (ends[region] - starts[region]);
        for (channel = 0; channel < CONV2_CHANNELS; channel++) {
            int64_t total = 0;
            for (row = 0; row < CONV2_SIZE; row++) {
                for (column = starts[region]; column < ends[region]; column++) {
                    total += input[row][column][channel];
                }
            }
            features[region * CONV2_CHANNELS + channel] =
                (int8_t)((total + count / 2) / count);
        }
    }
}

int cnn_infer_32x32(const uint8_t pixels[CNN_INPUT_BYTES], cnn_result_t *result)
{
    int8_t conv1_output[CONV1_SIZE][CONV1_SIZE][CONV1_CHANNELS];
    int8_t pooled[POOL_SIZE][POOL_SIZE][CONV1_CHANNELS];
    int8_t conv2_output[CONV2_SIZE][CONV2_SIZE][CONV2_CHANNELS];
    int8_t features[SPATIAL_FEATURES];
    int output;
    int feature;
    int best = 0;
    int second = 1;
    int64_t margin;

    if (pixels == NULL || result == NULL) {
        return -1;
    }
    if (conv1(pixels, conv1_output) != 0) {
        return -1;
    }
    maxpool2(conv1_output, pooled);
    if (conv2(pooled, conv2_output) != 0) {
        return -1;
    }
    spatial_pool(conv2_output, features);

    for (output = 0; output < CNN_OUTPUT_CLASSES; output++) {
        int64_t accumulator = TASK3_DENSE_BIAS[output];
        for (feature = 0; feature < SPATIAL_FEATURES; feature++) {
            if (add_product(&accumulator, features[feature],
                            TASK3_DENSE_WEIGHTS[feature * CNN_OUTPUT_CLASSES + output]) !=
                0) {
                return -1;
            }
        }
        if (accumulator < INT32_MIN || accumulator > INT32_MAX) {
            return -1;
        }
        result->logits[output] = (int32_t)accumulator;
    }
    if (result->logits[second] > result->logits[best]) {
        best = 1;
        second = 0;
    }
    for (output = 2; output < CNN_OUTPUT_CLASSES; output++) {
        if (result->logits[output] > result->logits[best]) {
            second = best;
            best = output;
        } else if (result->logits[output] > result->logits[second]) {
            second = output;
        }
    }
    margin = (int64_t)result->logits[best] - result->logits[second];
    result->klass = (uint8_t)(best + 1);
    if (margin <= 0) {
        result->confidence_q15 = 0;
    } else {
        int64_t best_magnitude = result->logits[best] < 0
                                     ? -(int64_t)result->logits[best]
                                     : result->logits[best];
        int64_t second_magnitude = result->logits[second] < 0
                                       ? -(int64_t)result->logits[second]
                                       : result->logits[second];
        int64_t normalizer = best_magnitude + second_magnitude;
        int64_t confidence = normalizer == 0
                                 ? 0
                                 : (margin * 32767 + normalizer / 2) / normalizer;
        result->confidence_q15 =
            confidence > 32767 ? UINT16_C(32767) : (uint16_t)confidence;
    }
    return 0;
}
