/***********************************************************************************************************************************
Test Compression
***********************************************************************************************************************************/
#include "common/io/filter/group.h"
#include "common/io/bufferRead.h"
#include "common/io/bufferWrite.h"
#include "common/io/io.h"
#include "storage/posix/storage.h"

/***********************************************************************************************************************************
Compress data
***********************************************************************************************************************************/
static Buffer *
testCompress(IoFilter *compress, Buffer *decompressed, size_t inputSize, size_t outputSize)
{
    Buffer *compressed = bufNew(1024 * 1024);
    size_t inputTotal = 0;
    ioBufferSizeSet(outputSize);

    IoWrite *write = ioBufferWriteNew(compressed);
    ioFilterGroupAdd(ioWriteFilterGroup(write), compress);
    ioWriteOpen(write);

    // Compress input data
    while (inputTotal < bufSize(decompressed))
    {
        // Generate the input buffer based on input size.  This breaks the data up into chunks as it would be in a real scenario.
        Buffer *input = bufNewC(
            bufPtr(decompressed) + inputTotal,
            inputSize > bufSize(decompressed) - inputTotal ? bufSize(decompressed) - inputTotal : inputSize);

        ioWrite(write, input);

        inputTotal += bufUsed(input);
        bufFree(input);
    }

    ioWriteClose(write);
    memContextFree(((GzipCompress *)ioFilterDriver(compress))->memContext);

    return compressed;
}

/***********************************************************************************************************************************
Decompress data
***********************************************************************************************************************************/
static Buffer *
testDecompress(IoFilter *decompress, Buffer *compressed, size_t inputSize, size_t outputSize)
{
    Buffer *decompressed = bufNew(1024 * 1024);
    Buffer *output = bufNew(outputSize);
    ioBufferSizeSet(inputSize);

    IoRead *read = ioBufferReadNew(compressed);
    ioFilterGroupAdd(ioReadFilterGroup(read), decompress);
    ioReadOpen(read);

    while (!ioReadEof(read))
    {
        ioRead(read, output);
        bufCat(decompressed, output);
        bufUsedZero(output);
    }

    ioReadClose(read);
    bufFree(output);
    memContextFree(((GzipDecompress *)ioFilterDriver(decompress))->memContext);

    return decompressed;
}

/***********************************************************************************************************************************
Standard test suite to be applied to all compression types
***********************************************************************************************************************************/
static void
testSuite(CompressType type, const char *decompressCmd)
{
    const char *simpleData = "A simple string";
    Buffer *compressed = NULL;
    Buffer *decompressed = bufNewC(simpleData, strlen(simpleData));

    VariantList *compressParamList = varLstNew();
    varLstAdd(compressParamList, varNewUInt(1));

    // Create default storage object for testing
    Storage *storageTest = storagePosixNew(strNew(testPath()), STORAGE_MODE_FILE_DEFAULT, STORAGE_MODE_PATH_DEFAULT, true, NULL);

    TEST_TITLE("simple data");

    TEST_ASSIGN(
        compressed,
        testCompress(
            compressFilterVar(strNewFmt("%sCompress", strPtr(compressTypeStr(type))), compressParamList), decompressed, 1024,
            256 * 1024 * 1024),
        "simple data - compress large in/large out buffer");

    TEST_RESULT_BOOL(
        bufEq(compressed, testCompress(compressFilter(type, 1), decompressed, 1024, 1)), true,
        "simple data - compress large in/small out buffer");

    TEST_RESULT_BOOL(
        bufEq(compressed, testCompress(compressFilter(type, 1), decompressed, 1, 1024)), true,
        "simple data - compress small in/large out buffer");

    TEST_RESULT_BOOL(
        bufEq(compressed, testCompress(compressFilter(type, 1), decompressed, 1, 1)), true,
        "simple data - compress small in/small out buffer");

    TEST_RESULT_BOOL(
        bufEq(
            decompressed,
            testDecompress(
                compressFilterVar(strNewFmt("%sDecompress", strPtr(compressTypeStr(type))), NULL), compressed, 1024, 1024)),
        true, "simple data - decompress large in/large out buffer");

    TEST_RESULT_BOOL(
        bufEq(decompressed, testDecompress(decompressFilter(type), compressed, 1024, 1)), true,
        "simple data - decompress large in/small out buffer");

    TEST_RESULT_BOOL(
        bufEq(decompressed, testDecompress(decompressFilter(type), compressed, 1, 1024)), true,
        "simple data - decompress small in/large out buffer");

    TEST_RESULT_BOOL(
        bufEq(decompressed, testDecompress(decompressFilter(type), compressed, 1, 1)), true,
        "simple data - decompress small in/small out buffer");

    // -------------------------------------------------------------------------------------------------------------------------
    if (decompressCmd != NULL)
    {
        TEST_TITLE("compressed output can be decompressed with command-line tool");

        storagePutP(storageNewWriteP(storageTest, STRDEF("test.cmp")), compressed);
        TEST_SYSTEM_FMT("%s {[path]}/test.cmp > {[path]}/test.out", decompressCmd);
        TEST_RESULT_BOOL(bufEq(decompressed, storageGetP(storageNewReadP(storageTest, STRDEF("test.out")))), true, "check output");
    }

    // -------------------------------------------------------------------------------------------------------------------------
    TEST_TITLE("error on no compression data");

    TEST_ERROR(testDecompress(decompressFilter(type), bufNew(0), 1, 1), FormatError, "unexpected eof in compressed data");

    // -------------------------------------------------------------------------------------------------------------------------
    TEST_TITLE("error on truncated compression data");

    Buffer *truncated = bufNew(0);
    bufCatSub(truncated, compressed, 0, bufUsed(compressed) - 1);

    TEST_RESULT_UINT(bufUsed(truncated), bufUsed(compressed) - 1, "check truncated buffer size");
    TEST_ERROR(testDecompress(decompressFilter(type), truncated, 512, 512), FormatError, "unexpected eof in compressed data");

    // -------------------------------------------------------------------------------------------------------------------------
    TEST_TITLE("compress a large zero input buffer into small output buffer");

    decompressed = bufNew(1024 * 1024 - 1);
    memset(bufPtr(decompressed), 0, bufSize(decompressed));
    bufUsedSet(decompressed, bufSize(decompressed));

    TEST_ASSIGN(
        compressed, testCompress(compressFilter(type, 3), decompressed, bufSize(decompressed), 1024),
        "zero data - compress large in/small out buffer");

    TEST_RESULT_BOOL(
        bufEq(decompressed, testDecompress(decompressFilter(type), compressed, bufSize(compressed), 1024 * 256)), true,
        "zero data - decompress large in/small out buffer");
}

/***********************************************************************************************************************************
Test Run
***********************************************************************************************************************************/
void
testRun(void)
{
    FUNCTION_HARNESS_VOID();

    // *****************************************************************************************************************************
    if (testBegin("gz"))
    {
        // Run standard test suite
        testSuite(compressTypeGzip, "gzip -dc");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("gzipError()");

        TEST_RESULT_INT(gzipError(Z_OK), Z_OK, "check ok");
        TEST_RESULT_INT(gzipError(Z_STREAM_END), Z_STREAM_END, "check stream end");
        TEST_ERROR(gzipError(Z_NEED_DICT), AssertError, "zlib threw error: [2] need dictionary");
        TEST_ERROR(gzipError(Z_ERRNO), AssertError, "zlib threw error: [-1] file error");
        TEST_ERROR(gzipError(Z_STREAM_ERROR), FormatError, "zlib threw error: [-2] stream error");
        TEST_ERROR(gzipError(Z_DATA_ERROR), FormatError, "zlib threw error: [-3] data error");
        TEST_ERROR(gzipError(Z_MEM_ERROR), MemoryError, "zlib threw error: [-4] insufficient memory");
        TEST_ERROR(gzipError(Z_BUF_ERROR), AssertError, "zlib threw error: [-5] no space in buffer");
        TEST_ERROR(gzipError(Z_VERSION_ERROR), FormatError, "zlib threw error: [-6] incompatible version");
        TEST_ERROR(gzipError(999), AssertError, "zlib threw error: [999] unknown error");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("gzipDecompressToLog() and gzipCompressToLog()");

        GzipDecompress *decompress = (GzipDecompress *)ioFilterDriver(gzipDecompressNew());

        TEST_RESULT_STR_Z(gzipDecompressToLog(decompress), "{inputSame: false, done: false, availIn: 0}", "format object");

        decompress->inputSame = true;
        decompress->done = true;

        TEST_RESULT_STR_Z(gzipDecompressToLog(decompress), "{inputSame: true, done: true, availIn: 0}", "format object");
    }

    // *****************************************************************************************************************************
    if (testBegin("lz4"))
    {
#ifdef HAVE_LIBLZ4
        // Run standard test suite
        testSuite(compressTypeLz4, "lz4 -dc");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("lz4Error()");

        TEST_RESULT_UINT(lz4Error(0), 0, "check success");
        TEST_ERROR(lz4Error((size_t)-2), FormatError, "lz4 error: [-2] ERROR_maxBlockSize_invalid");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("lz4DecompressToLog() and lz4CompressToLog()");

        Lz4Compress *compress = (Lz4Compress *)ioFilterDriver(lz4CompressNew(7));

        compress->inputSame = true;
        compress->flushing = true;

        TEST_RESULT_STR_Z(
            lz4CompressToLog(compress), "{level: 7, first: true, inputSame: true, flushing: true}", "format object");

        Lz4Decompress *decompress = (Lz4Decompress *)ioFilterDriver(lz4DecompressNew());

        decompress->inputSame = true;
        decompress->done = true;
        decompress->inputOffset = 999;

        TEST_RESULT_STR_Z(
            lz4DecompressToLog(decompress), "{inputSame: true, inputOffset: 999, frameDone false, done: true}",
            "format object");
#else
        TEST_ERROR(compressTypePresent(compressTypeLz4), OptionInvalidValueError, "pgBackRest not compiled with lz4 support");
#endif // HAVE_LIBLZ4
    }

    // Test everything in the helper that is not tested in the individual compression type tests
    // *****************************************************************************************************************************
    if (testBegin("helper"))
    {
        TEST_TITLE("compressTypeEnum()");

        TEST_RESULT_UINT(compressTypeEnum(STRDEF("none")), compressTypeNone, "none enum");
        TEST_RESULT_UINT(compressTypeEnum(STRDEF("gz")), compressTypeGzip, "gz enum");
        TEST_ERROR(compressTypeEnum(strNew(BOGUS_STR)), AssertError, "invalid compression type 'BOGUS'");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressTypePresent()");

        TEST_RESULT_VOID(compressTypePresent(compressTypeNone), "type none always present");
        TEST_ERROR(compressTypePresent(compressTypeZst), OptionInvalidValueError, "pgBackRest not compiled with zst support");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressTypeFromName()");

        TEST_RESULT_UINT(compressTypeFromName(STRDEF("file")), compressTypeNone, "type from name");
        TEST_RESULT_UINT(compressTypeFromName(STRDEF("file.gz")), compressTypeGzip, "type from name");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressFilterVar()");

        TEST_RESULT_PTR(compressFilterVar(STRDEF("BOGUS"), 0), NULL, "no filter match");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressExtStr()");

        TEST_RESULT_STR_Z(compressExtStr(compressTypeNone), "", "one ext");
        TEST_RESULT_STR_Z(compressExtStr(compressTypeGzip), ".gz", "gz ext");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressExtCat()");

        String *file = strNew("file");
        TEST_RESULT_VOID(compressExtCat(file, compressTypeGzip), "cat gzip ext");
        TEST_RESULT_STR_Z(file, "file.gz", "    check gzip ext");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressExtStrip()");

        TEST_ERROR(compressExtStrip(STRDEF("file"), compressTypeGzip), FormatError, "'file' must have '.gz' extension");
        TEST_RESULT_STR_Z(compressExtStrip(STRDEF("file"), compressTypeNone), "file", "nothing to strip");
        TEST_RESULT_STR_Z(compressExtStrip(STRDEF("file.gz"), compressTypeGzip), "file", "strip gz");

        // -------------------------------------------------------------------------------------------------------------------------
        TEST_TITLE("compressLevelDefault()");

        TEST_RESULT_INT(compressLevelDefault(compressTypeNone), 0, "none level=0");
        TEST_RESULT_INT(compressLevelDefault(compressTypeGzip), 6, "gz level=6");
    }

    FUNCTION_HARNESS_RESULT_VOID();
}
