#!/bin/bash
# 构建号自增脚本（构建阶段自动执行，仅 Release 配置）
#
# 职责边界：
# - 只递增构建号 CURRENT_PROJECT_VERSION（CFBundleVersion），保证每次打包的构建唯一可辨
# - 绝不触碰营销版本号 MARKETING_VERSION——那是发布语义，由 Scripts/bump_version.sh 手动管理
# - project.yml 是构建号的唯一事实源；构建产物 Info.plist 用 sed 整段替换
#   （历史教训：PlistBuddy 对 XML plist 的写回会破坏格式，导致版本号被逐次拼接成脏值）

# 仅 Release 配置时执行
if [ "$CONFIGURATION" != "Release" ]; then
    exit 0
fi

if [ -z "$SRCROOT" ]; then
    SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
PROJECT_YML="${SRCROOT}/project.yml"

# 读取当前构建号
CURRENT=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' "$PROJECT_YML" | head -1)
CURRENT=${CURRENT:-0}
NEW_BUILD=$((CURRENT + 1))

# 写回 project.yml（下次 xcodegen generate 后工程文件同步更新）
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" "$PROJECT_YML"

# 更新构建产物的 Info.plist，使当前构建立即携带新构建号
# （编译时工程文件里还是旧值，需事后补丁；sed 按 <string> 整段替换，幂等不破坏格式）
if [ -n "$BUILT_PRODUCTS_DIR" ] && [ -n "$INFOPLIST_PATH" ]; then
    INFOPLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
    if [ -f "$INFOPLIST" ]; then
        sed -i '' -E "/CFBundleVersion/{n;s#(<string>)[^<]*(</string>)#\1${NEW_BUILD}\2#;}" "$INFOPLIST"
    fi
fi

echo "Build number bumped: ${CURRENT} → ${NEW_BUILD}"
