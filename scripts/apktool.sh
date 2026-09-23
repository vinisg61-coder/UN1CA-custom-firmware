#!/usr/bin/env bash
# Copyright (c) 2025 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# [
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1

FRAMEWORK_DIR="$TOOLS_DIR/apktool/framework"
FRAMEWORK_TAG="$(GET_PROP "system" "ro.build.version.incremental")"

FORCE=false
JOBS="1"
PARTITION=""
FILE=""

HEAP_SIZE=""
THREAD_COUNT=""
INPUT_FILE=""
OUTPUT_PATH=""

# _FRAMEWORK_DEX_REBALANCE <decoded_dir>
# The One UI 8.5 donor ships framework classes.dex with its method pool right
# at the 64K edge; the methods our patches add push rebuilt invokes past it
# ("Unsigned short value out of range" in apktool). Move the first big
# peripheral package out of smali/ into a new dex to free pool room. Any dex
# split is functionally identical (bootclasspath loads every dex by name).
_FRAMEWORK_DEX_REBALANCE()
{
    local DECODED_DIR="$1"

    [ -d "$DECODED_DIR/smali/android" ] || return 0
    [ -d "$DECODED_DIR/smali_classes8" ] && return 0

    local CANDIDATE PKG_COUNT
    for CANDIDATE in media hardware net print service provider database text util graphics content view app os; do
        [ -d "$DECODED_DIR/smali/android/$CANDIDATE" ] || continue
        PKG_COUNT="$(find "$DECODED_DIR/smali/android/$CANDIDATE" -type f -name '*.smali' | wc -l)"
        LOG "  - smali/android/$CANDIDATE: $PKG_COUNT smali files"
        if [ "$PKG_COUNT" -ge 200 ]; then
            mkdir -p "$DECODED_DIR/smali_classes8/android"
            mv "$DECODED_DIR/smali/android/$CANDIDATE" "$DECODED_DIR/smali_classes8/android/$CANDIDATE"
            LOG "  - Moved smali/android/$CANDIDATE ($PKG_COUNT files) to smali_classes8 (64K method pool relief)"
            return 0
        fi
    done
    LOGW "  - No suitable package found to relieve framework classes.dex"
}

# _APKTOOL_STASH_BUILD_FAILURE <decoded_dir> <build_log>
# Debug aid: save the offending smali file plus per-dex unique method
# reference counts, so failures like a 64K method pool overflow of the
# rebuilt dex can be diagnosed from the CI artifact.
_APKTOOL_STASH_BUILD_FAILURE()
{
    local DECODED_DIR="$1"
    local BUILD_LOG="$2"
    local JAR_NAME DEX_FOLDER METHOD CLASS REL STASH_BASE SMALI_FILE

    JAR_NAME="$(basename "$INPUT_FILE")"
    STASH_BASE="$OUT_DIR/target/$TARGET_CODENAME/debug/apktool_failures/$JAR_NAME"

    DEX_FOLDER="$(grep -m1 -o 'Could not smali folder: [^ ]*' "$BUILD_LOG" | head -n 1)"
    DEX_FOLDER="${DEX_FOLDER##*folder: }"
    [ "$DEX_FOLDER" ] || DEX_FOLDER="smali"

    # Parse error format ("Could not smali file: <path>") as well as the
    # code-item format ("for method <class;->method").
    SMALI_FILE="$(grep -m1 -o 'Could not smali file: [^ ]*' "$BUILD_LOG" | head -n 1)"
    SMALI_FILE="${SMALI_FILE##*file: }"
    if [ "$SMALI_FILE" ]; then
        REL="${SMALI_FILE#$DECODED_DIR/}"
        [ "$REL" = "$SMALI_FILE" ] && REL=""
    else
        METHOD="$(grep -m1 -o 'for method [^ ]*' "$BUILD_LOG" | head -n 1)"
        METHOD="${METHOD##*method }"
        if [ "$METHOD" ]; then
            CLASS="${METHOD%%;->*}"
            CLASS="${CLASS#L}"
            CLASS="${CLASS%;}"
            REL="$DEX_FOLDER/$CLASS.smali"
        fi
    fi

    if [ "$REL" ]; then
        if [ -f "$DECODED_DIR/$REL" ]; then
            mkdir -p "$STASH_BASE/$(dirname "$REL")"
            cp -a "$DECODED_DIR/$REL" "$STASH_BASE/$REL"
            LOG "  - Stashed $JAR_NAME/$REL for artifact upload"
        else
            LOGW "  - Culprit smali $REL not found in decoded tree"
        fi
    else
        LOGW "  - Could not parse failing file from apktool output"
    fi

    local D FCOUNT MCOUNT
    for D in "$DECODED_DIR"/smali*; do
        [ -d "$D" ] || continue
        FCOUNT="$(find "$D" -type f -name '*.smali' | wc -l)"
        # Unique method references (class+name+proto, registers stripped).
        MCOUNT="$(grep -rhoE -- 'L[^ ]+;->[^ ]+\([^)]*\)[^ ]*' "$D" 2>/dev/null | sort -u | wc -l)"
        LOG "  - $(basename "$D"): $FCOUNT smali files, $MCOUNT unique method references"
    done
    LOG "  - Top-level packages in $DEX_FOLDER: $(ls "$DECODED_DIR/$DEX_FOLDER" 2>/dev/null | tr '\n' ' ')"
}

BUILD()
{
    if [ ! -d "$OUTPUT_PATH" ]; then
        LOGE "Folder not found: ${OUTPUT_PATH//$SRC_DIR\//}"
        exit 1
    fi

    LOG "- Building ${INPUT_FILE//$WORK_DIR/}"

    # Copy original META-INF
    mkdir -p "$OUTPUT_PATH/build/apk"
    cp -a "$OUTPUT_PATH/original/META-INF" "$OUTPUT_PATH/build/apk/META-INF"

    # Patched framework.jar overflows the 64K method pool of classes.dex on
    # rebuild (One UI 8.5 donor is already at the edge). Rebalance first.
    case "$INPUT_FILE" in
        *"/system/framework/framework.jar")
            _FRAMEWORK_DEX_REBALANCE "$OUTPUT_PATH"
            ;;
    esac

    # Build APK with --shorten-resource-paths (https://developer.android.com/tools/aapt2#optimize_options)
    # Capture the output: on failure it is diagnosed below (offending smali
    # file + per-dex reference counts for 64K pool overflow detection) so the
    # One UI 8.5 failure can be fixed from the uploaded artifact instead of
    # another blind run.
    local BUILD_LOG
    BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/apktool-build.XXXXXX")"
    if apktool -JXmx${HEAP_SIZE}m b -j "$THREAD_COUNT" -p "$FRAMEWORK_DIR" -srp "$OUTPUT_PATH" > "$BUILD_LOG" 2>&1; then
        rm -f "$BUILD_LOG"
    else
        LOGE "apktool build failed for ${INPUT_FILE//$WORK_DIR/}"
        tail -n 25 "$BUILD_LOG" | sed 's/^/    /'
        _APKTOOL_STASH_BUILD_FAILURE "$OUTPUT_PATH" "$BUILD_LOG"
        rm -f "$BUILD_LOG"
        exit 1
    fi

    local FILE_NAME
    FILE_NAME="$(basename "$INPUT_FILE")"

    if [[ "$INPUT_FILE" == *".apk" ]]; then
        local CERT_PREFIX="aosp"
        $ROM_IS_OFFICIAL && CERT_PREFIX="unica"

        LOG "- Signing ${INPUT_FILE//$WORK_DIR/}"
        EVAL "signapk \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$OUTPUT_PATH/dist/$FILE_NAME\" \"$OUTPUT_PATH/dist/temp.apk\"" || exit 1
        mv -f "$OUTPUT_PATH/dist/temp.apk" "$OUTPUT_PATH/dist/$FILE_NAME"
    else
        LOG "- Zipaligning ${INPUT_FILE//$WORK_DIR/}"
        EVAL "zipalign -p 4 \"$OUTPUT_PATH/dist/$FILE_NAME\" \"$OUTPUT_PATH/dist/temp\"" || exit 1
        mv -f "$OUTPUT_PATH/dist/temp" "$OUTPUT_PATH/dist/$FILE_NAME"
    fi

    mkdir -p "$(dirname "$INPUT_FILE")"
    mv -f "$OUTPUT_PATH/dist/$FILE_NAME" "$INPUT_FILE"
    rm -rf "$OUTPUT_PATH/build" && rm -rf "$OUTPUT_PATH/dist"

    if [ -d "${INPUT_FILE%/*}/oat" ]; then
        DELETE_FROM_WORK_DIR "$PARTITION" "${FILE%/*}/oat"
    fi
    if [ -f "${INPUT_FILE%/*}/$FILE_NAME.prof" ]; then
        DELETE_FROM_WORK_DIR "$PARTITION" "${FILE%/*}/$FILE_NAME.prof"
    fi
    if [ -f "${INPUT_FILE%/*}/$FILE_NAME.bprof" ]; then
        DELETE_FROM_WORK_DIR "$PARTITION" "${FILE%/*}/$FILE_NAME.bprof"
    fi
}

DECODE()
{
    local CACHE_KEY=""
    local CACHE_PATH=""
    local EXPECTED_CLASS_COUNT="0"

    if [ ! -f "$INPUT_FILE" ]; then
        LOGE "File not found: ${INPUT_FILE//$WORK_DIR/}"
        exit 1
    elif [ -d "$OUTPUT_PATH" ]; then
        if $FORCE; then
            rm -rf "$OUTPUT_PATH"
        else
            LOGE "Output directory already exists (${OUTPUT_PATH//$SRC_DIR\//}). Use --force flag if you want to overwrite it."
            exit 1
        fi
    fi

    if [[ "$(READ_BYTES_AT "$INPUT_FILE" "0" "4")" != "04034b50" ]]; then
        LOGE "File not valid: ${INPUT_FILE//$WORK_DIR/}"
        exit 1
    fi

    # Every DEX class definition must produce exactly one smali file. Besides
    # detecting interrupted cache writes, this catches decoded trees that were
    # accidentally cached while apktool was still processing another DEX.
    while IFS= read -r dex; do
        local DEX_TEMP
        local DEX_VERSION
        local DEX_OFFSET="0"
        local DEX_FILE_SIZE
        local DEX_CONTAINER_SIZE
        local DEX_CLASS_COUNT

        mkdir -p "$TMP_DIR"
        DEX_TEMP="$(mktemp "$TMP_DIR/dex-header.XXXXXX")"
        if ! unzip -p "$INPUT_FILE" "$dex" > "$DEX_TEMP"; then
            rm -f "$DEX_TEMP"
            LOGE "Failed to inspect $dex in ${INPUT_FILE//$WORK_DIR/}"
            exit 1
        fi

        DEX_VERSION="$(dd if="$DEX_TEMP" status=none bs=1 skip=4 count=3)"
        DEX_CONTAINER_SIZE="$(stat -c %s "$DEX_TEMP")"
        while [ "$DEX_OFFSET" -lt "$DEX_CONTAINER_SIZE" ]; do
            DEX_CLASS_COUNT="$(od -An -tu4 --endian=little \
                -j $((DEX_OFFSET + 96)) -N 4 "$DEX_TEMP" | tr -d ' ')"
            [ "$DEX_CLASS_COUNT" ] || DEX_CLASS_COUNT="0"
            EXPECTED_CLASS_COUNT=$((EXPECTED_CLASS_COUNT + DEX_CLASS_COUNT))

            # DEX 041 may store multiple logical dex files in one container.
            # file_size points to the next embedded header; older versions
            # contain only one logical dex per ZIP entry.
            [ "$DEX_VERSION" = "041" ] || break
            DEX_FILE_SIZE="$(od -An -tu4 --endian=little \
                -j $((DEX_OFFSET + 32)) -N 4 "$DEX_TEMP" | tr -d ' ')"
            [ "$DEX_FILE_SIZE" -gt "0" ] || break
            DEX_OFFSET=$((DEX_OFFSET + DEX_FILE_SIZE))
        done
        rm -f "$DEX_TEMP"
    done < <(zipinfo -1 "$INPUT_FILE" | grep -E '^classes([0-9]+)?\.dex$')

    # Cache only the pristine apktool output. Patch modules run after this
    # function returns, so cached trees never contain changes from an older
    # build. The key ties the tree to both the input and framework version.
    if [ -n "$APK_DECODE_CACHE_DIR" ]; then
        CACHE_KEY="$({
            sha256sum "$INPUT_FILE"
            sha256sum "$FRAMEWORK_DIR/1-$FRAMEWORK_TAG.apk"
            printf '%s\n' "$FRAMEWORK_TAG" "unica-apktool-decode-v1"
        } | sha256sum | cut -d " " -f 1)"
        CACHE_PATH="$APK_DECODE_CACHE_DIR/$CACHE_KEY"

        if [ "$APK_DECODE_CACHE_MODE" = "reuse" ] && [ -f "$CACHE_PATH/.complete" ] && \
                [ "$(cat "$CACHE_PATH/.class_count" 2> /dev/null)" = "$EXPECTED_CLASS_COUNT" ]; then
            local CACHED_CLASS_COUNT
            CACHED_CLASS_COUNT="$(find "$CACHE_PATH/tree" -type f -name '*.smali' | wc -l)"
            if [ "$CACHED_CLASS_COUNT" = "$EXPECTED_CLASS_COUNT" ]; then
                LOG "- Restoring decoded cache for ${INPUT_FILE//$WORK_DIR/}"
                mkdir -p "$OUTPUT_PATH"
                cp -a --reflink=auto "$CACHE_PATH/tree/." "$OUTPUT_PATH/" || exit 1
                return 0
            fi
            LOGW "Decoded cache is incomplete for ${INPUT_FILE//$WORK_DIR/}; regenerating"
        fi
    fi

    LOG "- Decoding ${INPUT_FILE//$WORK_DIR/}"

    # Decode APK with --no-debug-info, which will disassemble DEX file with the following flags:
    # - Disabled synthetic accessors comments
    # - Disabled debug info
    # - Use .locals directive instead of the .registers one
    # - Use a sequential numbering scheme for labels
    EVAL "apktool -JXmx${HEAP_SIZE}m d --no-debug-info -j \"$THREAD_COUNT\" -o \"$OUTPUT_PATH\" -p \"$FRAMEWORK_DIR\" -t \"$FRAMEWORK_TAG\" \"$INPUT_FILE\"" || exit 1

    if [ -n "$CACHE_PATH" ]; then
        local DECODED_CLASS_COUNT
        DECODED_CLASS_COUNT="$(find "$OUTPUT_PATH" -type f -name '*.smali' | wc -l)"
        if [ "$DECODED_CLASS_COUNT" != "$EXPECTED_CLASS_COUNT" ]; then
            LOGE "Incomplete decode for ${INPUT_FILE//$WORK_DIR/}: expected $EXPECTED_CLASS_COUNT classes, found $DECODED_CLASS_COUNT"
            exit 1
        fi

        local CACHE_TMP="$CACHE_PATH.tmp.$$"
        rm -rf "$CACHE_TMP"
        mkdir -p "$CACHE_TMP/tree"
        cp -a --reflink=auto "$OUTPUT_PATH/." "$CACHE_TMP/tree/" || exit 1
        printf '%s\n' "$EXPECTED_CLASS_COUNT" > "$CACHE_TMP/.class_count"
        touch "$CACHE_TMP/.complete"
        rm -rf "$CACHE_PATH"
        mv "$CACHE_TMP" "$CACHE_PATH"
    fi
}

PREPARE_SCRIPT()
{
    local MEM_TOTAL_MB
    local MAX_THREADS

    if [[ "$#" == 0 ]]; then
        PRINT_USAGE
        exit 1
    fi

    ACTION="$1"
    if [[ "$ACTION" != "decode" ]] && [[ "$ACTION" != "d" ]] && \
            [[ "$ACTION" != "build" ]] && [[ "$ACTION" != "b" ]]; then
        PRINT_USAGE
        exit 1
    fi

    shift

    while [[ "$1" == "-"* ]]; do
        if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
            FORCE=true
        elif [[ "$1" == "--jobs" ]] || [[ "$1" == "-j" ]]; then
            shift; JOBS="$1"
            if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
                LOGE "Jobs number not valid: $JOBS"
                exit 1
            fi
        else
            LOGE "Unknown option: $1"
            exit 1
        fi

        shift
    done

    MEM_TOTAL_MB="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"

    if [ "$JOBS" -gt "1" ]; then
        # Split 3/4 of total system memory between the requested instances
        HEAP_SIZE="$(bc -l <<< "scale=0; (($MEM_TOTAL_MB * 3) / 4) / $JOBS")"
        [ "$HEAP_SIZE" -lt "1024" ] && HEAP_SIZE="1024"

        MAX_THREADS="$(bc -l <<< "scale=0; $(nproc) / $JOBS")"
        [ "$MAX_THREADS" -lt "1" ] && MAX_THREADS="1"
        [ -n "$GITHUB_ACTIONS" ] && MAX_THREADS="1"

        # Do not use more threads than half the heap in GB
        THREAD_COUNT="$(bc -l <<< "scale=0; $HEAP_SIZE / (1024 * 2)")"
        [ "$THREAD_COUNT" -gt "$MAX_THREADS" ] && THREAD_COUNT="$MAX_THREADS"
        [ "$THREAD_COUNT" -lt "1" ] && THREAD_COUNT="1"
    else
        # https://github.com/iBotPeaches/Apktool/blob/main/scripts/linux/apktool#L61
        HEAP_SIZE="1024"

        MAX_THREADS="$(nproc)"
        [ -n "$GITHUB_ACTIONS" ] && MAX_THREADS="1"

        # Do not use more threads than half the total system memory in GB
        THREAD_COUNT="$(bc -l <<< "scale=0; $MEM_TOTAL_MB / (1024 * 2)")"
        [ "$THREAD_COUNT" -gt "$MAX_THREADS" ] && THREAD_COUNT="$MAX_THREADS"
        [ "$THREAD_COUNT" -lt "1" ] && THREAD_COUNT="1"
    fi

    PARTITION="$1"
    if [ ! "$PARTITION" ]; then
        PRINT_USAGE
        exit 1
    elif ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        exit 1
    fi

    shift

    if [ ! "$1" ]; then
        PRINT_USAGE
        exit 1
    fi

    FILE="$1"
    while [[ "${FILE:0:1}" == "/" ]]; do
        FILE="${FILE:1}"
    done

    local FILE_PATH="$WORK_DIR"
    case "$PARTITION" in
        "system_ext")
            if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
                FILE_PATH+="/system_ext"
            else
                FILE_PATH+="/system/system/system_ext"
            fi
            ;;
        *)
            FILE_PATH+="/$PARTITION"
            ;;
    esac
    FILE_PATH+="/$FILE"

    INPUT_FILE="$FILE_PATH"
    OUTPUT_PATH="$APKTOOL_DIR/$PARTITION/${FILE//system\//}"
}

PRINT_USAGE()
{
    echo "Usage: apktool d[ecode]/b[uild] [options] <partition> <file>" >&2
    echo " -f, --force : Force delete output directory" >&2
    echo " -j, --jobs : Specify the number of concurrent instances" >&2
}
# ]

ACTION=""

PREPARE_SCRIPT "$@"

if [ ! "$FRAMEWORK_TAG" ]; then
    LOGE "Work dir needs to be set up before using this script"
    exit 1
elif [ ! -f "$FRAMEWORK_DIR/1-$FRAMEWORK_TAG.apk" ]; then
    LOGW "framework-res.apk for \"$FRAMEWORK_TAG\" not found, installing"
    EVAL "apktool if -p \"$FRAMEWORK_DIR\" -t \"$FRAMEWORK_TAG\" \"$WORK_DIR/system/system/framework/framework-res.apk\"" || exit 1
fi

case "$ACTION" in
    "d" | "decode")
        DECODE
        ;;
    "b" | "build")
        BUILD
        ;;
esac

exit 0
