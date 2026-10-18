#!/bin/bash
#
# build-xcframework.sh
#
# 将当前 Swift Package 的 iOS 库产品打包成 XCFramework（真机 + 模拟器）。
#
# 原理：
#   1. 使用 swift build --triple/--sdk 分别编译真机和模拟器的静态库；
#   2. 把 lib<Product>.a 与 <Product>.swiftmodule(.swiftinterface) 组装成
#      .framework（静态 framework）；
#   3. 使用 xcodebuild -create-xcframework 合并成 XCFramework。
#
# 说明：
#   - 默认编译 Release，真机 arm64，模拟器 arm64 + x86_64。
#   - 只支持静态库产品（SPM .library 默认就是 static）。如果产品显式声明
#     为 .dynamic，本脚本不适用。
#   - 内部依赖（例如本仓库的 ObjC Helper）会被静态链接进同一个 framework。
#     因此 Swift 代码里不能公开 `import Helpers`，否则客户端导入时会报
#     "missing required module 'Helpers'"。本仓库已改为
#     `internal import Helpers`。
#
# 用法：
#   ./build-xcframework.sh
#   ./build-xcframework.sh -o dist -c Debug
#   ./build-xcframework.sh --name MyComponent --ios-min 15.0
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
CONFIGURATION="release"
OUTPUT_DIR="build"
PRODUCT_NAME=""
IOS_MIN=""
SIM_ARCHS="arm64 x86_64"
BUNDLE_ID=""
MARKETING_VERSION="1.0.0"
BUILD_NUMBER="1"
CLEAN=0
VERIFY=1

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
用法: ./build-xcframework.sh [选项]

选项:
  -n, --name <名称>             库产品名（默认自动读取 Package.swift 中第一个 library 产品）
  -o, --output <目录>           输出目录（默认: <Package 根目录>/build）
  -c, --configuration <配置>    release / debug（默认: release）
      --ios-min <版本>          最低 iOS 版本，例如 15.0（默认读取 platforms，否则用 SwiftPM 默认值）
      --sim-archs <架构列表>    模拟器架构，空格或逗号分隔（默认: "arm64 x86_64"）
      --bundle-id <标识>        framework 的 CFBundleIdentifier
      --version <版本>          CFBundleShortVersionString（默认: 1.0.0）
      --build-number <数字>     CFBundleVersion（默认: 1）
      --package-path <目录>     Package.swift 所在目录（默认: 脚本所在目录）
      --clean                   先清理中间产物和旧 XCFramework
      --no-verify               跳过生成后的客户端导入验证
  -h, --help                    显示帮助

示例:
  ./build-xcframework.sh --clean
  ./build-xcframework.sh -c Debug -o dist
  ./build-xcframework.sh --sim-archs arm64
USAGE
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--name)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            PRODUCT_NAME="$2"; shift 2 ;;
        -o|--output)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            OUTPUT_DIR="$2"; shift 2 ;;
        -c|--configuration)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            CONFIGURATION="$2"; shift 2 ;;
        --ios-min)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            IOS_MIN="$2"; shift 2 ;;
        --sim-archs)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            SIM_ARCHS="${2//,/ }"; shift 2 ;;
        --bundle-id)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            BUNDLE_ID="$2"; shift 2 ;;
        --version)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            MARKETING_VERSION="$2"; shift 2 ;;
        --build-number)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            BUILD_NUMBER="$2"; shift 2 ;;
        --package-path)
            [ $# -ge 2 ] || die "$1 缺少参数值"
            PACKAGE_DIR="$2"; shift 2 ;;
        --clean)
            CLEAN=1; shift ;;
        --no-verify)
            VERIFY=0; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            printf '未知参数: %s\n\n' "$1" >&2
            usage >&2
            exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 环境检查
PACKAGE_DIR="$(cd "$PACKAGE_DIR" 2>/dev/null && pwd)" || die "Package 目录不存在"
[ -f "$PACKAGE_DIR/Package.swift" ] || die "在 $PACKAGE_DIR 下没有找到 Package.swift"
command -v swift >/dev/null 2>&1 || die "未找到 swift，请先安装 Xcode 并执行 xcode-select --switch"
command -v xcodebuild >/dev/null 2>&1 || die "未找到 xcodebuild，请先安装 Xcode"
command -v xcrun >/dev/null 2>&1 || die "未找到 xcrun，请先安装 Xcode"
command -v lipo >/dev/null 2>&1 || die "未找到 lipo，请先安装 Xcode Command Line Tools"

case "$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')" in
    release) CONFIGURATION="release" ;;
    debug)   CONFIGURATION="debug" ;;
    *) die "不支持的配置: $CONFIGURATION（只支持 release / debug）" ;;
esac

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$PACKAGE_DIR/$OUTPUT_DIR" ;;
esac
mkdir -p "$OUTPUT_DIR" || die "无法创建输出目录: $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
[ "$OUTPUT_DIR" != "/" ] || die "输出目录不能是 /"

PACKAGE_NAME="$(basename "$PACKAGE_DIR")"

# ---------------------------------------------------------------- 读取 Package 信息
dump_package_json() {
    ( cd "$PACKAGE_DIR" && swift package dump-package --disable-sandbox 2>/dev/null ) || true
}

detect_product_name() {
    local json="" name=""
    json="$(dump_package_json)"
    if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
        name="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for product in data.get("products", []):
    if "library" in product.get("type", {}):
        print(product["name"])
        break
' 2>/dev/null || true)"
    fi
    if [ -z "$name" ]; then
        # 兜底：读取 Package.swift 顶层的 name
        name="$(sed -n 's/^[[:space:]]*name:[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKAGE_DIR/Package.swift" | head -n 1)"
    fi
    printf '%s' "$name"
}

detect_ios_min() {
    local json="" version=""
    json="$(dump_package_json)"
    if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
        version="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for platform in data.get("platforms", []):
    if str(platform.get("platformName", "")).lower() == "ios":
        print(platform.get("version", ""))
        break
' 2>/dev/null || true)"
    fi
    printf '%s' "$version"
}

if [ -z "$PRODUCT_NAME" ]; then
    PRODUCT_NAME="$(detect_product_name)"
fi
[ -n "$PRODUCT_NAME" ] || PRODUCT_NAME="$PACKAGE_NAME"

if [ -z "$IOS_MIN" ]; then
    IOS_MIN="$(detect_ios_min)"
fi

if [ -n "$IOS_MIN" ]; then
    case "$IOS_MIN" in
        *[!0-9.]*) die "无效的 --ios-min: $IOS_MIN" ;;
    esac
    case "$IOS_MIN" in
        *.*) ;;
        *) IOS_MIN="${IOS_MIN}.0" ;;
    esac
fi

if [ -n "$BUNDLE_ID" ]; then
    case "$BUNDLE_ID" in
        *[[:space:]]*) die "CFBundleIdentifier 不能包含空格: $BUNDLE_ID" ;;
    esac
else
    BUNDLE_ID="com.$(printf '%s' "$PACKAGE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-').${PRODUCT_NAME}"
fi

# 模拟器架构：去重、排序（xcframework 的目录名使用排序后的架构）
SIM_ARCH_LIST="$(printf '%s\n' $SIM_ARCHS | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[ -n "$SIM_ARCH_LIST" ] || die "--sim-archs 不能为空"
for arch in $SIM_ARCH_LIST; do
    case "$arch" in
        arm64|x86_64) ;;
        *) die "不支持的模拟器架构: $arch（只支持 arm64 / x86_64）" ;;
    esac
done
SIM_SLICE_ID="ios-$(printf '%s' "$SIM_ARCH_LIST" | tr ' ' '_')-simulator"

# 公共路径
WORK_DIR="$OUTPUT_DIR/.work"
STAGE_DIR="$WORK_DIR/stage"
BUILD_ROOT="$WORK_DIR/build"
CACHE_DIR="$WORK_DIR/swiftpm-cache"
DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$DEVICE_SDK" ] || die "找不到 iPhoneOS SDK，请确认已安装 Xcode iOS 平台"
[ -n "$SIM_SDK" ] || die "找不到 iPhoneSimulator SDK，请确认已安装 Xcode iOS 平台"

XCFRAMEWORK="$OUTPUT_DIR/${PRODUCT_NAME}.xcframework"

safe_rm() {
    case "$1" in
        ""|"/"|"."|"..") die "拒绝删除路径: '$1'" ;;
    esac
    rm -rf "$1"
}

if [ "$CLEAN" -eq 1 ]; then
    info "清理旧产物"
    safe_rm "$WORK_DIR"
    safe_rm "$XCFRAMEWORK"
fi

mkdir -p "$STAGE_DIR" "$BUILD_ROOT" "$CACHE_DIR"
safe_rm "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ---------------------------------------------------------------- 编译
SWIFT_BUILD_BASE=(
    -c "$CONFIGURATION"
    --disable-sandbox
    --cache-path "$CACHE_DIR"
    --enable-parseable-module-interfaces
    -Xswiftc -enable-library-evolution
)

swift_build() {
    local triple="$1" scratch="$2" sdk="$3" mode="${4:-build}"
    if [ "$mode" = "show-bin-path" ]; then
        ( cd "$PACKAGE_DIR" && swift build "${SWIFT_BUILD_BASE[@]}" --scratch-path "$scratch" --triple "$triple" --sdk "$sdk" --show-bin-path 2>/dev/null )
    else
        ( cd "$PACKAGE_DIR" && swift build "${SWIFT_BUILD_BASE[@]}" --scratch-path "$scratch" --triple "$triple" --sdk "$sdk" )
    fi
}

require_artifacts() {
    local bin="$1" label="$2"
    [ -f "$bin/lib${PRODUCT_NAME}.a" ] \
        || die "$label 未生成 lib${PRODUCT_NAME}.a。本脚本只支持静态库产品；dynamic 产品请改用 xcodebuild archive 流程。"
    [ -d "$bin/${PRODUCT_NAME}.swiftmodule" ] \
        || die "$label 未生成 ${PRODUCT_NAME}.swiftmodule"
    compgen -G "$bin/${PRODUCT_NAME}.swiftmodule/*.swiftinterface" >/dev/null \
        || die "$label 未生成 .swiftinterface，无法生成可分发模块"
}

detect_min_os_from_interface() {
    local bin="$1" iface="" version=""
    iface="$(find "$bin/${PRODUCT_NAME}.swiftmodule" -maxdepth 1 -name '*.swiftinterface' -print -quit 2>/dev/null || true)"
    if [ -n "$iface" ]; then
        version="$(sed -n 's/.*-target [^ ]*-apple-ios\([0-9][0-9.]*\).*/\1/p' "$iface" | head -n 1)"
    fi
    printf '%s' "$version"
}

LOCATED_BIN=""
build_slice() {
    local label="$1" triple="$2" scratch="$3" sdk="$4"
    info "编译 $label ($triple)"
    swift_build "$triple" "$scratch" "$sdk"
    LOCATED_BIN="$(swift_build "$triple" "$scratch" "$sdk" show-bin-path)"
    [ -n "$LOCATED_BIN" ] || die "无法获取 $label 的产物目录"
    require_artifacts "$LOCATED_BIN" "$label"
}

# 1) 真机
DEVICE_TRIPLE="arm64-apple-ios${IOS_MIN}"
build_slice "iOS 真机" "$DEVICE_TRIPLE" "$BUILD_ROOT/iphoneos" "$DEVICE_SDK"
DEVICE_BIN="$LOCATED_BIN"

if [ -z "$IOS_MIN" ]; then
    IOS_MIN="$(detect_min_os_from_interface "$DEVICE_BIN")"
    [ -n "$IOS_MIN" ] || IOS_MIN="15.0"
fi

# 2) 模拟器（每个架构单独 scratch，避免 Product 目录互相覆盖）
SIM_LIBS=()
SIM_MODULE_DIRS=()
for arch in $SIM_ARCH_LIST; do
    sim_triple="${arch}-apple-ios${IOS_MIN}-simulator"
    build_slice "iOS 模拟器 $arch" "$sim_triple" "$BUILD_ROOT/iphonesimulator-$arch" "$SIM_SDK"
    SIM_LIBS+=("$LOCATED_BIN/lib${PRODUCT_NAME}.a")
    SIM_MODULE_DIRS+=("$LOCATED_BIN/${PRODUCT_NAME}.swiftmodule")
done

# ---------------------------------------------------------------- 组装 framework
write_info_plist() {
    local plist="$1" supported_platform="$2" min_os="$3"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>MinimumOSVersion</key>
    <string>${min_os}</string>
</dict>
</plist>
EOF
}

copy_module_files() {
    local src="$1" dst="$2"
    # 只复制文件，忽略 debug 构建生成的 Project/ 等目录
    find "$src" -maxdepth 1 -type f \
        \( -name '*.swiftmodule' -o -name '*.swiftinterface' -o -name '*.swiftdoc' -o -name '*.abi.json' \) \
        -exec cp {} "$dst/" \;
}

make_framework() {
    local fw="$1" binary="$2" module_dir="$3" supported_platform="$4" min_os="$5" swift_header="$6"
    mkdir -p "$fw/Modules/${PRODUCT_NAME}.swiftmodule" "$fw/Headers"

    cp "$binary" "$fw/${PRODUCT_NAME}"
    copy_module_files "$module_dir" "$fw/Modules/${PRODUCT_NAME}.swiftmodule"
    if [ -n "$swift_header" ]; then
        cp "$swift_header" "$fw/Headers/"
    fi

    write_info_plist "$fw/Info.plist" "$supported_platform" "$min_os"
}

SWIFT_HEADER="$(find "$BUILD_ROOT/iphoneos" -name "${PRODUCT_NAME}-Swift.h" -print -quit 2>/dev/null || true)"

DEVICE_FW="$STAGE_DIR/ios-arm64/${PRODUCT_NAME}.framework"
make_framework "$DEVICE_FW" "$DEVICE_BIN/lib${PRODUCT_NAME}.a" "$DEVICE_BIN/${PRODUCT_NAME}.swiftmodule" "iPhoneOS" "$IOS_MIN" "$SWIFT_HEADER"

SIM_FW="$STAGE_DIR/${SIM_SLICE_ID}/${PRODUCT_NAME}.framework"
mkdir -p "$SIM_FW/Modules/${PRODUCT_NAME}.swiftmodule" "$SIM_FW/Headers"
if [ "${#SIM_LIBS[@]}" -eq 1 ]; then
    cp "${SIM_LIBS[0]}" "$SIM_FW/${PRODUCT_NAME}"
else
    lipo -create "${SIM_LIBS[@]}" -output "$SIM_FW/${PRODUCT_NAME}"
fi
for module_dir in "${SIM_MODULE_DIRS[@]}"; do
    copy_module_files "$module_dir" "$SIM_FW/Modules/${PRODUCT_NAME}.swiftmodule"
done
if [ -n "$SWIFT_HEADER" ]; then
    cp "$SWIFT_HEADER" "$SIM_FW/Headers/"
fi
write_info_plist "$SIM_FW/Info.plist" "iPhoneSimulator" "$IOS_MIN"

# ---------------------------------------------------------------- 生成 XCFramework
info "生成 XCFramework"
safe_rm "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -framework "$DEVICE_FW" \
    -framework "$SIM_FW" \
    -output "$XCFRAMEWORK"

# ---------------------------------------------------------------- 验证
verify_target() {
    local arch_target="$1" sdk="$2" slice_dir="$3" log="$4" client="$5"
    if ! swiftc -typecheck \
        -target "$arch_target" \
        -sdk "$sdk" \
        -module-cache-path "$WORK_DIR/verify-module-cache" \
        -F "$slice_dir" \
        "$client" >"$log" 2>&1; then
        cat "$log" >&2
        die "客户端导入验证失败（$arch_target）。如果报 missing required module，请确认内部依赖使用了 internal import（或 @_implementationOnly import）。"
    fi
}

if [ "$VERIFY" -eq 1 ]; then
    info "验证模块可被客户端导入"
    mkdir -p "$WORK_DIR/verify-module-cache"
    VERIFY_DIR="$(mktemp -d "$WORK_DIR/verify.XXXXXX")"
    CLIENT_SWIFT="$VERIFY_DIR/main.swift"
    printf 'import %s\n' "$PRODUCT_NAME" > "$CLIENT_SWIFT"

    verify_target "arm64-apple-ios${IOS_MIN}" "$DEVICE_SDK" "$XCFRAMEWORK/ios-arm64" "$VERIFY_DIR/device.log" "$CLIENT_SWIFT"

    for arch in $SIM_ARCH_LIST; do
        verify_target "${arch}-apple-ios${IOS_MIN}-simulator" "$SIM_SDK" "$XCFRAMEWORK/$SIM_SLICE_ID" "$VERIFY_DIR/sim-${arch}.log" "$CLIENT_SWIFT"
    done

    safe_rm "$VERIFY_DIR"
    info "客户端导入验证通过"
fi

# 架构检查
DEVICE_ARCHS="$(lipo -archs "$DEVICE_FW/${PRODUCT_NAME}")"
SIM_ARCHS_FOUND="$(lipo -archs "$SIM_FW/${PRODUCT_NAME}")"
case " $DEVICE_ARCHS " in
    *" arm64 "*) ;;
    *) die "真机 framework 不包含 arm64 架构" ;;
esac
for arch in $SIM_ARCH_LIST; do
    case " $SIM_ARCHS_FOUND " in
        *" $arch "*) ;;
        *) die "模拟器 framework 不包含 $arch 架构" ;;
    esac
done

# ---------------------------------------------------------------- 完成
SIZE="$(du -sh "$XCFRAMEWORK" | awk '{print $1}')"
cat <<EOF

✅ 生成成功：$XCFRAMEWORK
   库产品：$PRODUCT_NAME
   配置：$CONFIGURATION
   真机：ios-arm64 ($DEVICE_ARCHS)
   模拟器：$SIM_SLICE_ID ($SIM_ARCHS_FOUND)
   最低系统：iOS $IOS_MIN
   大小：$SIZE

使用方式：
   把 ${PRODUCT_NAME}.xcframework 拖入 Target 的
   "Frameworks, Libraries, and Embedded Content"，
   静态库产物请选择 "Do Not Embed"。

   客户端代码中直接 import ${PRODUCT_NAME} 即可。
EOF
