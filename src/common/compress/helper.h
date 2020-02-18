/***********************************************************************************************************************************
Compression Helper
***********************************************************************************************************************************/
#ifndef COMMON_COMPRESS_HELPER_H
#define COMMON_COMPRESS_HELPER_H

#include <stdbool.h>

#include <common/type/string.h>
#include <common/io/filter/group.h>

/***********************************************************************************************************************************
Available compression types
***********************************************************************************************************************************/
typedef enum
{
    compressTypeNone,
    compressTypeGzip,
    compressTypeLz4,
} CompressType;

/***********************************************************************************************************************************
Functions
***********************************************************************************************************************************/
// Get enum from a compression type string
CompressType compressTypeEnum(const String *type);

// Add compression filter to a filter group.  If compression type is none then no filter will be added.
bool compressFilterAdd(IoFilterGroup *filterGroup, CompressType type, int level);

// Get extension for the current compression type
const char *compressExtZ(CompressType type);

// Add extension for current compression type to the file
void compressExtCat(String *file, CompressType type);

#endif