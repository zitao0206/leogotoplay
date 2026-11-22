#!/usr/bin/env python3
"""生成 iOS / macOS 两个 Xcode 工程 + 一个 workspace。

不依赖 XcodeGen：按目录扫描源码，生成稳定的 project.pbxproj、共享 scheme 与 workspace。
结构约定（与本仓库目录保持一致）：

    apps/ios/LeogotoPlay-iOS.xcodeproj      ← 源码 apps/ios/Sources
    apps/macos/LeogotoPlay-macOS.xcodeproj  ← 源码 apps/macos/Sources
    packages/LeogotoPlayCore                ← 两端共享的 Swift Package
    LeogotoPlay.xcworkspace                 ← 平时只打开这个

新增 / 删除 Swift 文件后重新执行 `python3 scripts/generate_xcodeproj.py` 即可。
"""
import hashlib
import os

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_NAME = "LeogotoPlay"
PRODUCT_NAME = APP_NAME
PACKAGE_PRODUCT = "LeogotoPlayCore"
PACKAGE_RELATIVE_PATH = "../../packages/LeogotoPlayCore"
CORE_SOURCES = ["Models/Models.swift",
                "Store/LibraryStore.swift",
                "Store/AuthStore.swift",
                "Services/VideoFileStore.swift",
                "Services/VideoImporter.swift",
                "Services/VideoExporter.swift",
                "Services/ThumbnailService.swift",
                "Services/KeychainStore.swift",
                "Services/AuthService.swift",
                "Services/ExportSettings.swift"]


def uid(kind, key):
    return hashlib.md5(f"{kind}:{key}".encode("utf-8")).hexdigest()[:24].upper()


def q(value):
    """旧式 plist 字符串：必要时加引号。"""
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$/:.")
    if value and all(c in allowed for c in value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_settings(settings):
    lines = []
    for key in sorted(settings.keys()):
        value = settings[key]
        if isinstance(value, list):
            body = ", ".join(q(str(item)) for item in value)
            lines.append(f"\t\t\t\t{key} = ({body});\n")
        else:
            lines.append(f"\t\t\t\t{key} = {q(str(value))};\n")
    return "".join(lines)


def collect_swift(root):
    files = []
    for dirpath, dirs, filenames in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not d.endswith(".xcassets"))
        for name in sorted(filenames):
            if name.endswith(".swift"):
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                files.append(rel.replace(os.sep, "/"))
    return sorted(files)


COMMON_PROJECT_DEBUG = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_TESTABILITY": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "MTL_FAST_MATH": "YES",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}

COMMON_PROJECT_RELEASE = dict(COMMON_PROJECT_DEBUG)
COMMON_PROJECT_RELEASE.update({
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "ONLY_ACTIVE_ARCH": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "VALIDATE_PRODUCT": "YES",
})
COMMON_PROJECT_RELEASE.pop("ENABLE_TESTABILITY", None)
COMMON_PROJECT_RELEASE.pop("GCC_PREPROCESSOR_DEFINITIONS", None)
COMMON_PROJECT_RELEASE.pop("SWIFT_ACTIVE_COMPILATION_CONDITIONS", None)


def generate_project(project_dir, sources_dir, bundle_id, deployment_target, platform,
                     plist_rel, infoplist_project_path, resource_files, extra_target_settings):
    """生成一个单 target 的 App 工程。"""
    swift_files = collect_swift(sources_dir)

    project_debug = dict(COMMON_PROJECT_DEBUG)
    project_release = dict(COMMON_PROJECT_RELEASE)
    if platform == "ios":
        project_debug["SDKROOT"] = "iphoneos"
        project_debug["IPHONEOS_DEPLOYMENT_TARGET"] = deployment_target
        project_release["SDKROOT"] = "iphoneos"
        project_release["IPHONEOS_DEPLOYMENT_TARGET"] = deployment_target
    else:
        project_debug["SDKROOT"] = "macosx"
        project_debug["MACOSX_DEPLOYMENT_TARGET"] = deployment_target
        project_release["SDKROOT"] = "macosx"
        project_release["MACOSX_DEPLOYMENT_TARGET"] = deployment_target

    # ---------- 目录树 ----------
    tree = {"dirs": {}, "files": []}

    def add_node(rel_path):
        parts = rel_path.split("/")
        node = tree
        for part in parts[:-1]:
            node = node["dirs"].setdefault(part, {"dirs": {}, "files": []})
        node["files"].append(rel_path)

    for rel in swift_files + [plist_rel] + resource_files:
        add_node(rel)

    group_records = []

    def build_groups(node, key, name, path):
        gid = uid(platform + "-group", key)
        children = []
        for dir_name, sub in sorted(node["dirs"].items()):
            child_id = build_groups(sub, f"{key}/{dir_name}", dir_name, dir_name)
            children.append(child_id)
        for rel in sorted(node["files"]):
            children.append(uid(platform + "-file", rel))
        body = "".join(f"\t\t\t\t{child} /* child */,\n" for child in children)
        group_records.append(
            "\t\t{gid} /* {name} */ = {{\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n{body}\t\t\t);\n"
            "\t\t\tpath = {path};\n"
            "\t\t\tsourceTree = \"<group>\";\n"
            "\t\t}};\n".format(gid=gid, name=name, body=body, path=q(path))
        )
        return gid

    sources_group = build_groups(tree, "Sources", "Sources", "Sources")

    # ---------- ID ----------
    MAIN_GROUP = uid(platform + "-group", "MAIN")
    PRODUCTS_GROUP = uid(platform + "-group", "PRODUCTS")
    PACKAGE_GROUP = uid(platform + "-group", "PACKAGES")
    PRODUCT_REF = uid(platform + "-file", "product")
    TARGET_ID = uid(platform + "-target", APP_NAME)
    PROJECT_ID = uid(platform + "-project", APP_NAME)
    PROJECT_CONFIG_LIST = uid(platform + "-configlist", "project")
    TARGET_CONFIG_LIST = uid(platform + "-configlist", "target")
    SOURCES_PHASE = uid(platform + "-phase", "sources")
    FRAMEWORKS_PHASE = uid(platform + "-phase", "frameworks")
    RESOURCES_PHASE = uid(platform + "-phase", "resources")
    PKG_REF = uid(platform + "-pkgref", PACKAGE_RELATIVE_PATH)
    PKG_PRODUCT = uid(platform + "-pkgproduct", PACKAGE_PRODUCT)
    PKG_BUILD_FILE = uid(platform + "-build", "package")
    SOURCES_GROUP_ID = sources_group
    PACKAGE_FILE_GROUP = uid(platform + "-group", "LeogotoPlayCore-files")

    # ---------- PBXBuildFile / PBXFileReference ----------
    build_files = []
    file_refs = []
    source_build_ids = []

    for rel in swift_files:
        fid = uid(platform + "-file", rel)
        bid = uid(platform + "-build", rel)
        source_build_ids.append(bid)
        name = os.path.basename(rel)
        build_files.append(
            f"\t\t{bid} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};\n"
        )
        file_refs.append(
            f"\t\t{fid} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {q(name)}; sourceTree = \"<group>\"; }};\n"
        )

    resource_build_ids = []
    for rel in resource_files:
        fid = uid(platform + "-file", rel)
        bid = uid(platform + "-build", rel)
        resource_build_ids.append(bid)
        name = os.path.basename(rel)
        kind = "folder.assetcatalog" if name.endswith(".xcassets") else "file"
        build_files.append(
            f"\t\t{bid} /* {name} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};\n"
        )
        file_refs.append(
            f"\t\t{fid} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = {kind}; "
            f"path = {q(name)}; sourceTree = \"<group>\"; }};\n"
        )

    build_files.append(
        f"\t\t{PKG_BUILD_FILE} /* {PACKAGE_PRODUCT} in Frameworks */ = "
        f"{{isa = PBXBuildFile; productRef = {PKG_PRODUCT} /* {PACKAGE_PRODUCT} */; }};\n"
    )

    plist_id = uid(platform + "-file", plist_rel)
    file_refs.append(
        f"\t\t{plist_id} /* Info.plist */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
        f"path = \"Info.plist\"; sourceTree = \"<group>\"; }};\n"
    )

    file_refs.append(
        f"\t\t{PRODUCT_REF} /* {PRODUCT_NAME}.app */ = "
        f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {q(PRODUCT_NAME + '.app')}; sourceTree = BUILT_PRODUCTS_DIR; }};\n"
    )

    # ---------- 目标构建设置 ----------
    target_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": infoplist_project_path,
        "INFOPLIST_KEY_CFBundleDisplayName": PRODUCT_NAME,
        "MARKETING_VERSION": "1.1.0" if platform == "ios" else "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
    }
    target_settings.update(extra_target_settings)
    target_settings.update({
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)",
                                    "@executable_path/Frameworks" if platform == "ios"
                                    else "@executable_path/../Frameworks"],
    })

    config_debug_id = uid(platform + "-config", "project/debug")
    config_release_id = uid(platform + "-config", "project/release")
    target_debug_id = uid(platform + "-config", "target/debug")
    target_release_id = uid(platform + "-config", "target/release")

    # ---------- 组装 ----------
    sections = []

    sections.append(
        "/* Begin PBXBuildFile section */\n"
        + "".join(build_files)
        + "/* End PBXBuildFile section */\n"
    )

    sections.append(
        "/* Begin PBXFileReference section */\n"
        + "".join(file_refs)
        + "/* End PBXFileReference section */\n"
    )

    sections.append(
        "/* Begin PBXFrameworksBuildPhase section */\n"
        f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{PKG_BUILD_FILE} /* {PACKAGE_PRODUCT} in Frameworks */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXFrameworksBuildPhase section */\n"
    )

    sections.append(
        "/* Begin PBXGroup section */\n"
        f"\t\t{MAIN_GROUP} = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{SOURCES_GROUP_ID} /* Sources */,\n"
        f"\t\t\t\t{PACKAGE_GROUP} /* Packages */,\n"
        f"\t\t\t\t{PRODUCTS_GROUP} /* Products */,\n"
        "\t\t\t);\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
        f"\t\t{PRODUCTS_GROUP} /* Products */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{PRODUCT_REF} /* {PRODUCT_NAME}.app */,\n"
        "\t\t\t);\n"
        "\t\t\tname = Products;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
        f"\t\t{PACKAGE_GROUP} /* Packages */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t// {PACKAGE_PRODUCT} 由 packageProductDependencies 提供\n"
        "\t\t\t);\n"
        "\t\t\tname = Packages;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
        + "".join(group_records)
        + "/* End PBXGroup section */\n"
    )

    sections.append(
        "/* Begin PBXNativeTarget section */\n"
        f"\t\t{TARGET_ID} /* {APP_NAME} */ = {{\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        "\t\t\tbuildConfigurationList = "
        f"{TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */;\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{SOURCES_PHASE} /* Sources */,\n"
        f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,\n"
        f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n"
        "\t\t\t);\n"
        "\t\t\tdependencies = (\n"
        "\t\t\t);\n"
        f"\t\t\tname = {q(APP_NAME)};\n"
        "\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{PKG_PRODUCT} /* {PACKAGE_PRODUCT} */,\n"
        "\t\t\t);\n"
        f"\t\t\tproductName = {q(PRODUCT_NAME)};\n"
        f"\t\t\tproductReference = {PRODUCT_REF} /* {PRODUCT_NAME}.app */;\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n"
        "\t\t};\n"
        "/* End PBXNativeTarget section */\n"
    )

    sections.append(
        "/* Begin PBXProject section */\n"
        f"\t\t{PROJECT_ID} /* Project object */ = {{\n"
        "\t\t\tisa = PBXProject;\n"
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 1520;\n"
        "\t\t\t\tLastUpgradeCheck = 1520;\n"
        "\t\t\t\tTargetAttributes = {\n"
        f"\t\t\t\t\t{TARGET_ID} = {{\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.2;\n"
        "\t\t\t\t\t};\n"
        "\t\t\t\t};\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject \"{APP_NAME}\" */;\n"
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        "\t\t\tdevelopmentRegion = en;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n"
        "\t\t\t\ten,\n"
        "\t\t\t\tBase,\n"
        "\t\t\t);\n"
        f"\t\t\tmainGroup = {MAIN_GROUP};\n"
        "\t\t\tpackageReferences = (\n"
        f"\t\t\t\t{PKG_REF} /* XCLocalSwiftPackageReference \"{PACKAGE_RELATIVE_PATH}\" */,\n"
        "\t\t\t);\n"
        f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;\n"
        "\t\t\tprojectDirPath = \"\";\n"
        "\t\t\tprojectRoot = \"\";\n"
        "\t\t\ttargets = (\n"
        f"\t\t\t\t{TARGET_ID} /* {APP_NAME} */,\n"
        "\t\t\t);\n"
        "\t\t};\n"
        "/* End PBXProject section */\n"
    )

    sections.append(
        "/* Begin PBXResourcesBuildPhase section */\n"
        f"\t\t{RESOURCES_PHASE} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        + "".join(
            f"\t\t\t\t{uid(platform + '-build', rel)} /* {os.path.basename(rel)} in Resources */,\n"
            for rel in resource_files
        )
        + "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXResourcesBuildPhase section */\n"
    )

    sections.append(
        "/* Begin PBXSourcesBuildPhase section */\n"
        f"\t\t{SOURCES_PHASE} /* Sources */ = {{\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        + "".join(
            f"\t\t\t\t{uid(platform + '-build', rel)} /* {os.path.basename(rel)} in Sources */,\n"
            for rel in swift_files
        )
        + "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXSourcesBuildPhase section */\n"
    )

    sections.append(
        "/* Begin XCBuildConfiguration section */\n"
        f"\t\t{config_debug_id} /* Debug */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        + render_settings(project_debug)
        + "\t\t\t};\n"
        "\t\t\tname = Debug;\n"
        "\t\t};\n"
        f"\t\t{config_release_id} /* Release */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        + render_settings(project_release)
        + "\t\t\t};\n"
        "\t\t\tname = Release;\n"
        "\t\t};\n"
        f"\t\t{target_debug_id} /* Debug */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        + render_settings(target_settings)
        + "\t\t\t};\n"
        "\t\t\tname = Debug;\n"
        "\t\t};\n"
        f"\t\t{target_release_id} /* Release */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        + render_settings(target_settings)
        + "\t\t\t};\n"
        "\t\t\tname = Release;\n"
        "\t\t};\n"
        "/* End XCBuildConfiguration section */\n"
    )

    sections.append(
        "/* Begin XCConfigurationList section */\n"
        f"\t\t{PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject \"{APP_NAME}\" */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{config_debug_id} /* Debug */,\n"
        f"\t\t\t\t{config_release_id} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};\n"
        f"\t\t{TARGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"{APP_NAME}\" */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{target_debug_id} /* Debug */,\n"
        f"\t\t\t\t{target_release_id} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};\n"
        "/* End XCConfigurationList section */\n"
    )

    sections.append(
        "/* Begin XCLocalSwiftPackageReference section */\n"
        f"\t\t{PKG_REF} /* XCLocalSwiftPackageReference \"{PACKAGE_RELATIVE_PATH}\" */ = {{\n"
        "\t\t\tisa = XCLocalSwiftPackageReference;\n"
        f"\t\t\trelativePath = {q(PACKAGE_RELATIVE_PATH)};\n"
        "\t\t};\n"
        "/* End XCLocalSwiftPackageReference section */\n"
    )

    sections.append(
        "/* Begin XCSwiftPackageProductDependency section */\n"
        f"\t\t{PKG_PRODUCT} /* {PACKAGE_PRODUCT} */ = {{\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tproductName = {q(PACKAGE_PRODUCT)};\n"
        f"\t\t\tpackage = {PKG_REF} /* XCLocalSwiftPackageReference \"{PACKAGE_RELATIVE_PATH}\" */;\n"
        "\t\t};\n"
        "/* End XCSwiftPackageProductDependency section */\n"
    )

    content = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n"
        "\t};\n"
        "\tobjectVersion = 56;\n"
        "\tobjects = {\n\n"
        + "\n".join(sections)
        + "\t};\n"
        f"\trootObject = {PROJECT_ID} /* Project object */;\n"
        "}\n"
    )

    proj_name = f"{APP_NAME}-{'iOS' if platform == 'ios' else 'macOS'}"
    project_bundle = f"{proj_name}.xcodeproj"
    os.makedirs(os.path.join(project_dir, project_bundle, "xcshareddata", "xcschemes"), exist_ok=True)
    with open(os.path.join(project_dir, project_bundle, "project.pbxproj"), "w", encoding="utf-8") as fh:
        fh.write(content)

    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1520" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{TARGET_ID}" BuildableName="{PRODUCT_NAME}.app" BlueprintName="{APP_NAME}" ReferencedContainer="container:{project_bundle}"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{TARGET_ID}" BuildableName="{PRODUCT_NAME}.app" BlueprintName="{APP_NAME}" ReferencedContainer="container:{project_bundle}"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""
    with open(os.path.join(project_dir, project_bundle, "xcshareddata", "xcschemes",
                           f"{proj_name}.xcscheme"), "w", encoding="utf-8") as fh:
        fh.write(scheme)

    return proj_name, len(swift_files)


def generate_workspace(projects):
    path = os.path.join(REPO_DIR, f"{APP_NAME}.xcworkspace")
    os.makedirs(path, exist_ok=True)
    refs = "".join(
        f'   <FileRef location = "group:{rel}"></FileRef>\n' for rel in projects
    )
    content = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace\n'
        '   version = "1.0">\n'
        + refs +
        '</Workspace>\n'
    )
    with open(os.path.join(path, "contents.xcworkspacedata"), "w", encoding="utf-8") as fh:
        fh.write(content)


def main():
    ios = generate_project(
        project_dir=os.path.join(REPO_DIR, "apps", "ios"),
        sources_dir=os.path.join(REPO_DIR, "apps", "ios", "Sources"),
        bundle_id="com.leogotoplay.app",
        deployment_target="16.0",
        platform="ios",
        plist_rel="Resources/Info.plist",
        infoplist_project_path="Sources/Resources/Info.plist",
        resource_files=["Resources/Assets.xcassets"],
        extra_target_settings={
            "TARGETED_DEVICE_FAMILY": "1,2",
        },
    )
    mac = generate_project(
        project_dir=os.path.join(REPO_DIR, "apps", "macos"),
        sources_dir=os.path.join(REPO_DIR, "apps", "macos", "Sources"),
        bundle_id="com.leogotoplay.mac",
        deployment_target="13.0",
        platform="macos",
        plist_rel="Resources/Info.plist",
        infoplist_project_path="Sources/Resources/Info.plist",
        resource_files=[],
        extra_target_settings={
            "CODE_SIGN_IDENTITY": "-",
            "CODE_SIGN_STYLE": "Manual",
            "ENABLE_HARDENED_RUNTIME": "NO",
            "COMBINE_HIDPI_IMAGES": "YES",
        },
    )
    generate_workspace([
        "apps/ios/LeogotoPlay-iOS.xcodeproj",
        "apps/macos/LeogotoPlay-macOS.xcodeproj",
    ])
    print(f"generated: {ios[0]} ({ios[1]} swift files)")
    print(f"generated: {mac[0]} ({mac[1]} swift files)")
    print(f"generated: {APP_NAME}.xcworkspace")


if __name__ == "__main__":
    main()
