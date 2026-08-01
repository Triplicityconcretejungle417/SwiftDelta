//===--- CDiagnosticReader.c - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

#include "CDiagnosticReader.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *CXDiagnosticSet;
typedef void *CXDiagnostic;
typedef void *CXFile;

typedef struct {
    const void *data;
    unsigned private_flags;
} CXString;

typedef struct {
    const void *ptr_data[2];
    unsigned int_data;
} CXSourceLocation;

typedef struct {
    const void *ptr_data[2];
    unsigned begin_int_data;
    unsigned end_int_data;
} CXSourceRange;

typedef CXDiagnosticSet (*LoadDiagnostics)(const char *, int *, CXString *);
typedef unsigned (*GetNumDiagnostics)(CXDiagnosticSet);
typedef CXDiagnostic (*GetDiagnostic)(CXDiagnosticSet, unsigned);
typedef unsigned (*GetNumFixIts)(CXDiagnostic);
typedef CXString (*GetFixIt)(CXDiagnostic, unsigned, CXSourceRange *);
typedef CXString (*GetDiagnosticSpelling)(CXDiagnostic);
typedef unsigned (*GetDiagnosticSeverity)(CXDiagnostic);
typedef CXSourceLocation (*GetRangeLocation)(CXSourceRange);
typedef void (*GetExpansionLocation)(
    CXSourceLocation,
    CXFile *,
    unsigned *,
    unsigned *,
    unsigned *
);
typedef CXString (*GetFileName)(CXFile);
typedef const char *(*GetCString)(CXString);
typedef void (*DisposeString)(CXString);
typedef void (*DisposeDiagnosticSet)(CXDiagnosticSet);

static void set_error(char **destination, const char *message) {
    if (destination == NULL) {
        return;
    }
    const char *text = message == NULL ? "Unknown diagnostic reader error." : message;
    size_t length = strlen(text);
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        *destination = NULL;
        return;
    }
    memcpy(copy, text, length + 1);
    *destination = copy;
}

static void *load_symbol(void *library, const char *name, char **error_message) {
    dlerror();
    void *symbol = dlsym(library, name);
    const char *error = dlerror();
    if (error != NULL) {
        char message[512];
        snprintf(
            message,
            sizeof(message),
            "The selected libclang does not export %s: %s",
            name,
            error
        );
        set_error(error_message, message);
        return NULL;
    }
    return symbol;
}

int sd_load_diagnostic_fixits(
    const char *libclang_path,
    const char *diagnostics_path,
    SDDiagnosticFixItCallback callback,
    void *context,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (libclang_path == NULL || diagnostics_path == NULL || callback == NULL) {
        set_error(error_message, "Diagnostic reader received an invalid argument.");
        return 1;
    }

    // Resolve libclang at runtime so diagnostics follow the selected Xcode.
    void *library = dlopen(libclang_path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        set_error(error_message, dlerror());
        return 2;
    }

#define LOAD_SYMBOL(variable, type, name) \
    type variable = (type)load_symbol(library, name, error_message); \
    if (variable == NULL) { \
        dlclose(library); \
        return 3; \
    }

    LOAD_SYMBOL(load_diagnostics, LoadDiagnostics, "clang_loadDiagnostics")
    LOAD_SYMBOL(get_num_diagnostics, GetNumDiagnostics, "clang_getNumDiagnosticsInSet")
    LOAD_SYMBOL(get_diagnostic, GetDiagnostic, "clang_getDiagnosticInSet")
    LOAD_SYMBOL(get_num_fixits, GetNumFixIts, "clang_getDiagnosticNumFixIts")
    LOAD_SYMBOL(get_fixit, GetFixIt, "clang_getDiagnosticFixIt")
    LOAD_SYMBOL(get_spelling, GetDiagnosticSpelling, "clang_getDiagnosticSpelling")
    LOAD_SYMBOL(get_severity, GetDiagnosticSeverity, "clang_getDiagnosticSeverity")
    LOAD_SYMBOL(get_range_start, GetRangeLocation, "clang_getRangeStart")
    LOAD_SYMBOL(get_range_end, GetRangeLocation, "clang_getRangeEnd")
    LOAD_SYMBOL(get_expansion_location, GetExpansionLocation, "clang_getExpansionLocation")
    LOAD_SYMBOL(get_file_name, GetFileName, "clang_getFileName")
    LOAD_SYMBOL(get_c_string, GetCString, "clang_getCString")
    LOAD_SYMBOL(dispose_string, DisposeString, "clang_disposeString")
    LOAD_SYMBOL(dispose_set, DisposeDiagnosticSet, "clang_disposeDiagnosticSet")

#undef LOAD_SYMBOL

    int load_error = 0;
    CXString load_error_text = {0};
    CXDiagnosticSet set = load_diagnostics(
        diagnostics_path,
        &load_error,
        &load_error_text
    );
    if (set == NULL) {
        const char *details = get_c_string(load_error_text);
        char message[512];
        snprintf(
            message,
            sizeof(message),
            "Could not load serialized diagnostics (%d): %s",
            load_error,
            details == NULL ? "no details" : details
        );
        dispose_string(load_error_text);
        set_error(error_message, message);
        dlclose(library);
        return 4;
    }
    dispose_string(load_error_text);

    unsigned diagnostic_count = get_num_diagnostics(set);
    for (unsigned diagnostic_index = 0;
         diagnostic_index < diagnostic_count;
         diagnostic_index += 1) {
        CXDiagnostic diagnostic = get_diagnostic(set, diagnostic_index);
        CXString spelling = get_spelling(diagnostic);
        const char *diagnostic_text = get_c_string(spelling);
        unsigned severity = get_severity(diagnostic);
        unsigned fixit_count = get_num_fixits(diagnostic);

        for (unsigned fixit_index = 0;
             fixit_index < fixit_count;
             fixit_index += 1) {
            CXSourceRange range;
            CXString replacement = get_fixit(diagnostic, fixit_index, &range);
            CXSourceLocation start = get_range_start(range);
            CXSourceLocation end = get_range_end(range);
            CXFile start_file = NULL;
            CXFile end_file = NULL;
            unsigned start_line = 0;
            unsigned start_column = 0;
            unsigned start_offset = 0;
            unsigned end_line = 0;
            unsigned end_column = 0;
            unsigned end_offset = 0;
            get_expansion_location(
                start,
                &start_file,
                &start_line,
                &start_column,
                &start_offset
            );
            get_expansion_location(
                end,
                &end_file,
                &end_line,
                &end_column,
                &end_offset
            );
            CXString file_name = get_file_name(start_file);
            const char *path = get_c_string(file_name);
            const char *replacement_text = get_c_string(replacement);
            callback(
                path == NULL ? "" : path,
                start_offset,
                end_offset,
                start_line,
                start_column,
                end_line,
                end_column,
                replacement_text == NULL ? "" : replacement_text,
                diagnostic_text == NULL ? "" : diagnostic_text,
                severity,
                diagnostic_index,
                fixit_index,
                context
            );
            dispose_string(file_name);
            dispose_string(replacement);
        }
        dispose_string(spelling);
    }

    dispose_set(set);
    dlclose(library);
    return 0;
}

void sd_free_diagnostic_error(char *error_message) {
    free(error_message);
}
