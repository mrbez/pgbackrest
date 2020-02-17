/***********************************************************************************************************************************
LZ4 Decompress

Decompress IO from the lz4 format.
***********************************************************************************************************************************/
#ifdef HAVE_LIBLZ4

#ifndef COMMON_COMPRESS_LZ4_DECOMPRESS_H
#define COMMON_COMPRESS_LZ4_DECOMPRESS_H

/***********************************************************************************************************************************
Object type
***********************************************************************************************************************************/
typedef struct Lz4Decompress Lz4Decompress;

#include "common/io/filter/filter.h"

/***********************************************************************************************************************************
Constructor
***********************************************************************************************************************************/
IoFilter *lz4DecompressNew(void);

#endif

#endif // HAVE_LIBLZ4