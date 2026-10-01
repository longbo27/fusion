#ifndef FS_TIFF_BRIDGE_H
#define FS_TIFF_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct FSTiff FSTiff;
typedef struct {
 uint32_t raw_width, raw_height, width, height, rows_per_strip, tile_width, tile_height;
 uint16_t bits, channels, orientation, compression, resolution_unit;
 uint64_t segments;
 double dpi_x, dpi_y;
 int tiled, big;
} FSTiffInfo;
typedef struct { uint64_t decoded_bytes, encoded_bytes, segments, planned_bytes; int direct_rows; } FSDecodePlan;
FSTiff *fs_tiff_open(const char *path, uint64_t internal_limit, char *error, size_t error_size);
void fs_tiff_close(FSTiff *file);
const char *fs_tiff_error(FSTiff *file);
int fs_tiff_info(FSTiff *file, FSTiffInfo *info);
const void *fs_tiff_icc(FSTiff *file, uint32_t *length);
const char *fs_tiff_text(FSTiff *file, uint32_t tag);
int fs_tiff_plan(FSTiff *file, uint32_t x, uint32_t y, uint32_t w, uint32_t h, FSDecodePlan *plan);
int fs_tiff_read(FSTiff *file, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint16_t *rgba, uint64_t memory_budget);
int fs_write_tiff_from_raw(const char *raw, const char *temporary, uint32_t width, uint32_t height,
 uint16_t compression, uint32_t tile_edge, uint32_t rows_per_strip, int force_big,
 const void *icc, uint32_t icc_length, double dpi_x, double dpi_y, uint16_t res_unit,
 const char *artist, const char *copyright, const char *description,
 uint64_t memory_budget, char *error, size_t error_size);
int fs_validate_tiff_against_raw(const char *raw, const char *tiff, uint32_t width, uint32_t height,
 const void *icc, uint32_t icc_length, uint64_t memory_budget, char *error, size_t error_size);
#endif
