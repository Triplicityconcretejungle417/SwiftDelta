//===--- CDiagnosticReader.h - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

#ifndef C_DIAGNOSTIC_READER_H
#define C_DIAGNOSTIC_READER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*SDDiagnosticFixItCallback)(
    const char *file_path,
    uint32_t start_offset,
    uint32_t end_offset,
    uint32_t start_line,
    uint32_t start_column,
    uint32_t end_line,
    uint32_t end_column,
    const char *replacement,
    const char *diagnostic_text,
    uint32_t diagnostic_severity,
    uint32_t diagnostic_index,
    uint32_t fixit_index,
    void *context
);

int sd_load_diagnostic_fixits(
    const char *libclang_path,
    const char *diagnostics_path,
    SDDiagnosticFixItCallback callback,
    void *context,
    char **error_message
);

void sd_free_diagnostic_error(char *error_message);

#ifdef __cplusplus
}
#endif

#endif
