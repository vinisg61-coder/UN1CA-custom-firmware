if [[ "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" == "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" ]] && \
    [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" == "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]]; then
    LOG "\033[0;33m! Nothing to do\033[0m"
    return 0
fi

_LOG() { if $DEBUG; then LOGW "$1"; else ABORT "$1"; fi }

# The donor hardcodes its own SIOP policy name inside <clinit>()V, and the
# SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME value in unica/configs may be
# stale (it was copied from the S23 FE configuration). Read the real constant
# from the decoded donor smali instead of trusting the config file.
FIND_DONOR_SSRM_POLICY()
{
    local SMALI_FILE="$1"
    local CANDIDATES
    local FOUND

    [ -f "$SMALI_FILE" ] || return 1

    CANDIDATES="$(awk '
        /^\.method/ && index($0, "<clinit>()V") { inside = 1 }
        inside { print }
        inside && /^\.end method/ { exit }
    ' "$SMALI_FILE" | grep -o "siop_[A-Za-z0-9_]*" | sort -u)"
    [ "$CANDIDATES" ] || return 1

    # Prefer the device specific policy over generic fallback names.
    FOUND="$(grep -vxF "siop_default" <<< "$CANDIDATES" | head -n 1)"
    [ "$FOUND" ] || FOUND="$(head -n 1 <<< "$CANDIDATES")"

    echo "$FOUND"
}

# Samsung renames the obfuscated SDHMS classes between platform releases.
# Keep the known One UI 8.0 paths as the default and select their 8.5
# counterparts when building from the S23 FE source.
DVFS_FEATURE_SMALI="smali/r1/c.smali"
DVFS_PROPERTIES_SMALI="smali/z1/e.smali"
SSRM_FEATURE_SMALI="smali/U1/w.smali"
if [ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]; then
    DVFS_FEATURE_SMALI="smali/c4/c.smali"
    DVFS_PROPERTIES_SMALI="smali/k4/e.smali"
    SSRM_FEATURE_SMALI="smali/o5/w.smali"
fi

# SEC_PRODUCT_FEATURE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME
if [[ "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" != "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" ]]; then
    SMALI_PATCH "system" "system/framework/ssrm.jar" \
        "smali/com/android/server/ssrm/Feature.smali" "replace" \
        "<clinit>()V" \
        "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME"

    DECODE_APK "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

    if [ -f "$SRC_DIR/target/$TARGET_CODENAME/dvfs/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml" ]; then
        LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml"
        EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/dvfs/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml\""
    elif [ ! -f "$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml" ]; then
        _LOG "\"$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME\" does not exist in SDHMS app"
    fi

    # com/sec/android/sdhms/performance/PerformanceFeature
    SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
        "$DVFS_FEATURE_SMALI" "replace" \
        "<clinit>()V" \
        "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME"
    # com/sec/android/sdhms/performance/settings/PerformanceProperties
    SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
        "$DVFS_PROPERTIES_SMALI" "replace" \
        "<init>(Landroid/content/Context;)V" \
        "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME"
fi

# SEC_PRODUCT_FEATURE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME
if [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]]; then
    SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_SYSTEM_CONFIG_SIOP_POLICY_FILENAME" "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"

    DECODE_APK "system" "system/framework/ssrm.jar"
    DONOR_SSRM="$(FIND_DONOR_SSRM_POLICY "$APKTOOL_DIR/system/framework/ssrm.jar/smali/com/android/server/ssrm/Feature.smali")" || DONOR_SSRM=""

    if [ ! "$DONOR_SSRM" ]; then
        # One UI 8.5 may read the SIOP policy from floating_feature.xml only.
        LOG "- Donor does not hardcode an SSRM policy in ssrm.jar; floating_feature.xml value is used"
    elif [ "$DONOR_SSRM" == "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]; then
        LOG "- ssrm.jar already targets \"$DONOR_SSRM\"; skipping"
    else
        if [ "$DONOR_SSRM" != "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]; then
            LOG "- Donor SSRM policy detected as \"$DONOR_SSRM\" (config: \"$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME\")"
        fi
        SMALI_PATCH "system" "system/framework/ssrm.jar" \
            "smali/com/android/server/ssrm/Feature.smali" "replace" \
            "<clinit>()V" \
            "$DONOR_SSRM" \
            "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"
    fi

    DECODE_APK "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

    if [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "ssrm_default" ]] && \
            [[ "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" == "ssrm_default" ]]; then
        LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default"
        EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default\""
        LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model"
        EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model\""
        LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default"
        EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default\""
        LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml"
        EVAL "cp -a \"$MODPATH/assets/siop_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml\""
        LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml"
        EVAL "cp -a \"$MODPATH/assets/siop_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml\""
    fi

    # com/sec/android/sdhms/util/Feature
    DONOR_SSRM="$(FIND_DONOR_SSRM_POLICY "$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/$SSRM_FEATURE_SMALI")" || DONOR_SSRM=""
    if [ ! "$DONOR_SSRM" ]; then
        LOG "- Donor does not hardcode an SSRM policy in SDHMS; floating_feature.xml value is used"
    elif [ "$DONOR_SSRM" == "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]; then
        LOG "- SDHMS already targets \"$DONOR_SSRM\"; skipping"
    else
        SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
            "$SSRM_FEATURE_SMALI" "replace" \
            "<clinit>()V" \
            "$DONOR_SSRM" \
            "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"
    fi
fi

if [ -f "$SRC_DIR/target/$TARGET_CODENAME/dvfs/siop_model.xml" ]; then
    DECODE_APK "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

    LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default"
    EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default\""
    LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model"
    EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model\""
    LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default"
    EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default\""

    LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml"
    EVAL "cp -a \"$MODPATH/assets/siop_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml\""
    LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/dvfs/siop_model.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME.xml\""
    LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml"
    EVAL "cp -a \"$MODPATH/assets/siop_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml\""
else
    if [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]] && \
            [[ "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "ssrm_default" ]]; then
        _LOG "File not found: $SRC_DIR/target/$TARGET_CODENAME/dvfs/siop_model.xml"
    fi
fi

unset -f _LOG
unset -f FIND_DONOR_SSRM_POLICY
unset DVFS_FEATURE_SMALI DVFS_PROPERTIES_SMALI SSRM_FEATURE_SMALI
