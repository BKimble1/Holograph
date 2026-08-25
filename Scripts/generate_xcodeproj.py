#!/usr/bin/env python3
"""Generate Holograph.xcodeproj deterministically from the source tree.

The project file is committed, so a contributor only needs Xcode. Re-run this
after adding or removing source files:

    python3 Scripts/generate_xcodeproj.py

Object identifiers are derived from stable keys (md5 of a path/role string), so
regenerating produces a byte-identical file and diffs stay readable.
"""
from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "Holograph"
APP_TARGET = "Holograph"
UNIT_TARGET = "HolographTests"
UI_TARGET = "HolographUITests"
BUNDLE_ID = "com.idlery.holograph"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "6.0"
XCODE_OBJECT_VERSION = "56"

SOURCE_ROOTS = {
    APP_TARGET: "Holograph",
    UNIT_TARGET: "HolographTests",
    UI_TARGET: "HolographUITests",
}

# Directories treated as opaque bundles rather than walked into.
BUNDLE_SUFFIXES = (".xcassets",)

SAFE = re.compile(r"^[A-Za-z0-9_./$][A-Za-z0-9_./$+-]*$")


def uid(key: str) -> str:
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


def q(value: str) -> str:
    """Quote a value the way Xcode's OpenStep writer does."""
    if value == "":
        return '""'
    if SAFE.match(value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def file_type(path: Path) -> str:
    name = path.name
    if name.endswith(".swift"):
        return "sourcecode.swift"
    if name.endswith(".xcassets"):
        return "folder.assetcatalog"
    if name.endswith(".plist"):
        return "text.plist.xml"
    if name.endswith(".png"):
        return "image.png"
    if name.endswith(".md"):
        return "net.daringfireball.markdown"
    return "text"


class Node:
    """A group in the project navigator."""

    def __init__(self, name: str, path: Path):
        self.name = name
        self.path = path
        self.children: list[Node] = []
        self.files: list[Path] = []

    @property
    def uid(self) -> str:
        return uid(f"group:{self.path}")


def collect(directory: Path) -> Node:
    node = Node(directory.name, directory.relative_to(ROOT))
    entries = sorted(directory.iterdir(), key=lambda p: (p.is_dir() and not p.name.endswith(BUNDLE_SUFFIXES), p.name.lower()))
    for entry in entries:
        if entry.name.startswith("."):
            continue
        if entry.is_dir() and not entry.name.endswith(BUNDLE_SUFFIXES):
            child = collect(entry)
            if child.files or child.children:
                node.children.append(child)
        else:
            node.files.append(entry.relative_to(ROOT))
    return node


def iter_files(node: Node):
    for path in node.files:
        yield path
    for child in node.children:
        yield from iter_files(child)


def is_source(path: Path) -> bool:
    return path.suffix == ".swift"


def is_resource(path: Path) -> bool:
    return path.name.endswith(BUNDLE_SUFFIXES)


class Writer:
    def __init__(self):
        self.lines: list[str] = []

    def add(self, text: str = "") -> None:
        self.lines.append(text)

    def render(self) -> str:
        return "\n".join(self.lines) + "\n"


def build() -> str:
    trees = {target: collect(ROOT / relative) for target, relative in SOURCE_ROOTS.items()}

    product_uids = {
        APP_TARGET: uid("product:app"),
        UNIT_TARGET: uid("product:unit"),
        UI_TARGET: uid("product:ui"),
    }
    product_names = {
        APP_TARGET: f"{APP_TARGET}.app",
        UNIT_TARGET: f"{UNIT_TARGET}.xctest",
        UI_TARGET: f"{UI_TARGET}.xctest",
    }
    target_uids = {name: uid(f"target:{name}") for name in SOURCE_ROOTS}

    project_uid = uid("project")
    main_group_uid = uid("group:main")
    products_group_uid = uid("group:products")

    w = Writer()
    w.add("// !$*UTF8*$!")
    w.add("{")
    w.add("\tarchiveVersion = 1;")
    w.add("\tclasses = {")
    w.add("\t};")
    w.add(f"\tobjectVersion = {XCODE_OBJECT_VERSION};")
    w.add("\tobjects = {")

    # ---- PBXBuildFile -------------------------------------------------
    w.add("")
    w.add("/* Begin PBXBuildFile section */")
    build_files: dict[str, list[tuple[str, Path]]] = {name: [] for name in SOURCE_ROOTS}
    resource_files: dict[str, list[tuple[str, Path]]] = {name: [] for name in SOURCE_ROOTS}
    rows: list[str] = []
    for target, tree in trees.items():
        for path in sorted(iter_files(tree)):
            if is_source(path):
                bf = uid(f"buildfile:{target}:{path}")
                build_files[target].append((bf, path))
                rows.append(
                    f"\t\t{bf} /* {path.name} in Sources */ = {{isa = PBXBuildFile; "
                    f"fileRef = {uid(f'file:{path}')} /* {path.name} */; }};"
                )
            elif is_resource(path):
                bf = uid(f"buildfile:{target}:{path}")
                resource_files[target].append((bf, path))
                rows.append(
                    f"\t\t{bf} /* {path.name} in Resources */ = {{isa = PBXBuildFile; "
                    f"fileRef = {uid(f'file:{path}')} /* {path.name} */; }};"
                )
    for row in sorted(rows):
        w.add(row)
    w.add("/* End PBXBuildFile section */")

    # ---- PBXContainerItemProxy ---------------------------------------
    w.add("")
    w.add("/* Begin PBXContainerItemProxy section */")
    for test_target in (UNIT_TARGET, UI_TARGET):
        proxy = uid(f"proxy:{test_target}")
        w.add(f"\t\t{proxy} /* PBXContainerItemProxy */ = {{")
        w.add("\t\t\tisa = PBXContainerItemProxy;")
        w.add(f"\t\t\tcontainerPortal = {project_uid} /* Project object */;")
        w.add("\t\t\tproxyType = 1;")
        w.add(f"\t\t\tremoteGlobalIDString = {target_uids[APP_TARGET]};")
        w.add(f"\t\t\tremoteInfo = {APP_TARGET};")
        w.add("\t\t};")
    w.add("/* End PBXContainerItemProxy section */")

    # ---- PBXFileReference --------------------------------------------
    w.add("")
    w.add("/* Begin PBXFileReference section */")
    refs: list[str] = []
    for tree in trees.values():
        for path in sorted(iter_files(tree)):
            refs.append(
                f"\t\t{uid(f'file:{path}')} /* {path.name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = {file_type(path)}; path = {q(path.name)}; sourceTree = \"<group>\"; }};"
            )
    for target, product in product_names.items():
        explicit = "wrapper.application" if target == APP_TARGET else "wrapper.cfbundle"
        refs.append(
            f"\t\t{product_uids[target]} /* {product} */ = {{isa = PBXFileReference; "
            f"explicitFileType = {explicit}; includeInIndex = 0; path = {q(product)}; "
            "sourceTree = BUILT_PRODUCTS_DIR; };"
        )
    for row in sorted(refs):
        w.add(row)
    w.add("/* End PBXFileReference section */")

    # ---- PBXFrameworksBuildPhase -------------------------------------
    w.add("")
    w.add("/* Begin PBXFrameworksBuildPhase section */")
    for target in SOURCE_ROOTS:
        phase = uid(f"frameworks:{target}")
        w.add(f"\t\t{phase} /* Frameworks */ = {{")
        w.add("\t\t\tisa = PBXFrameworksBuildPhase;")
        w.add("\t\t\tbuildActionMask = 2147483647;")
        w.add("\t\t\tfiles = (")
        w.add("\t\t\t);")
        w.add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w.add("\t\t};")
    w.add("/* End PBXFrameworksBuildPhase section */")

    # ---- PBXGroup -----------------------------------------------------
    w.add("")
    w.add("/* Begin PBXGroup section */")

    def emit_group(node: Node) -> None:
        w.add(f"\t\t{node.uid} /* {node.name} */ = {{")
        w.add("\t\t\tisa = PBXGroup;")
        w.add("\t\t\tchildren = (")
        for child in node.children:
            w.add(f"\t\t\t\t{child.uid} /* {child.name} */,")
        for path in node.files:
            w.add(f"\t\t\t\t{uid(f'file:{path}')} /* {path.name} */,")
        w.add("\t\t\t);")
        w.add(f"\t\t\tpath = {q(node.name)};")
        w.add("\t\t\tsourceTree = \"<group>\";")
        w.add("\t\t};")
        for child in node.children:
            emit_group(child)

    w.add(f"\t\t{main_group_uid} = {{")
    w.add("\t\t\tisa = PBXGroup;")
    w.add("\t\t\tchildren = (")
    for target in SOURCE_ROOTS:
        node = trees[target]
        w.add(f"\t\t\t\t{node.uid} /* {node.name} */,")
    w.add(f"\t\t\t\t{products_group_uid} /* Products */,")
    w.add("\t\t\t);")
    w.add("\t\t\tsourceTree = \"<group>\";")
    w.add("\t\t};")

    w.add(f"\t\t{products_group_uid} /* Products */ = {{")
    w.add("\t\t\tisa = PBXGroup;")
    w.add("\t\t\tchildren = (")
    for target in SOURCE_ROOTS:
        w.add(f"\t\t\t\t{product_uids[target]} /* {product_names[target]} */,")
    w.add("\t\t\t);")
    w.add("\t\t\tname = Products;")
    w.add("\t\t\tsourceTree = \"<group>\";")
    w.add("\t\t};")

    for target in SOURCE_ROOTS:
        emit_group(trees[target])
    w.add("/* End PBXGroup section */")

    # ---- PBXNativeTarget ----------------------------------------------
    w.add("")
    w.add("/* Begin PBXNativeTarget section */")
    for target in SOURCE_ROOTS:
        product_type = {
            APP_TARGET: "com.apple.product-type.application",
            UNIT_TARGET: "com.apple.product-type.bundle.unit-test",
            UI_TARGET: "com.apple.product-type.bundle.ui-testing",
        }[target]
        w.add(f"\t\t{target_uids[target]} /* {target} */ = {{")
        w.add("\t\t\tisa = PBXNativeTarget;")
        w.add(f"\t\t\tbuildConfigurationList = {uid(f'configlist:{target}')} /* Build configuration list for PBXNativeTarget \"{target}\" */;")
        w.add("\t\t\tbuildPhases = (")
        w.add(f"\t\t\t\t{uid(f'sources:{target}')} /* Sources */,")
        w.add(f"\t\t\t\t{uid(f'frameworks:{target}')} /* Frameworks */,")
        w.add(f"\t\t\t\t{uid(f'resources:{target}')} /* Resources */,")
        w.add("\t\t\t);")
        w.add("\t\t\tbuildRules = (")
        w.add("\t\t\t);")
        w.add("\t\t\tdependencies = (")
        if target != APP_TARGET:
            w.add(f"\t\t\t\t{uid(f'dependency:{target}')} /* PBXTargetDependency */,")
        w.add("\t\t\t);")
        w.add(f"\t\t\tname = {target};")
        w.add(f"\t\t\tproductName = {target};")
        w.add(f"\t\t\tproductReference = {product_uids[target]} /* {product_names[target]} */;")
        w.add(f"\t\t\tproductType = {q(product_type)};")
        w.add("\t\t};")
    w.add("/* End PBXNativeTarget section */")

    # ---- PBXProject ----------------------------------------------------
    w.add("")
    w.add("/* Begin PBXProject section */")
    w.add(f"\t\t{project_uid} /* Project object */ = {{")
    w.add("\t\t\tisa = PBXProject;")
    w.add("\t\t\tattributes = {")
    w.add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w.add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    w.add("\t\t\t\tLastUpgradeCheck = 1600;")
    w.add("\t\t\t\tTargetAttributes = {")
    for target in SOURCE_ROOTS:
        w.add(f"\t\t\t\t\t{target_uids[target]} = {{")
        w.add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
        if target == UNIT_TARGET:
            w.add(f"\t\t\t\t\t\tTestTargetID = {target_uids[APP_TARGET]};")
        if target == UI_TARGET:
            w.add(f"\t\t\t\t\t\tTestTargetID = {target_uids[APP_TARGET]};")
        w.add("\t\t\t\t\t};")
    w.add("\t\t\t\t};")
    w.add("\t\t\t};")
    w.add(f"\t\t\tbuildConfigurationList = {uid('configlist:project')} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    w.add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w.add("\t\t\tdevelopmentRegion = en;")
    w.add("\t\t\thasScannedForEncodings = 0;")
    w.add("\t\t\tknownRegions = (")
    w.add("\t\t\t\ten,")
    w.add("\t\t\t\tBase,")
    w.add("\t\t\t);")
    w.add(f"\t\t\tmainGroup = {main_group_uid};")
    w.add(f"\t\t\tproductRefGroup = {products_group_uid} /* Products */;")
    w.add("\t\t\tprojectDirPath = \"\";")
    w.add("\t\t\tprojectRoot = \"\";")
    w.add("\t\t\ttargets = (")
    for target in SOURCE_ROOTS:
        w.add(f"\t\t\t\t{target_uids[target]} /* {target} */,")
    w.add("\t\t\t);")
    w.add("\t\t};")
    w.add("/* End PBXProject section */")

    # ---- PBXResourcesBuildPhase ----------------------------------------
    w.add("")
    w.add("/* Begin PBXResourcesBuildPhase section */")
    for target in SOURCE_ROOTS:
        w.add(f"\t\t{uid(f'resources:{target}')} /* Resources */ = {{")
        w.add("\t\t\tisa = PBXResourcesBuildPhase;")
        w.add("\t\t\tbuildActionMask = 2147483647;")
        w.add("\t\t\tfiles = (")
        for bf, path in sorted(resource_files[target], key=lambda item: item[1].name):
            w.add(f"\t\t\t\t{bf} /* {path.name} in Resources */,")
        w.add("\t\t\t);")
        w.add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w.add("\t\t};")
    w.add("/* End PBXResourcesBuildPhase section */")

    # ---- PBXSourcesBuildPhase ------------------------------------------
    w.add("")
    w.add("/* Begin PBXSourcesBuildPhase section */")
    for target in SOURCE_ROOTS:
        w.add(f"\t\t{uid(f'sources:{target}')} /* Sources */ = {{")
        w.add("\t\t\tisa = PBXSourcesBuildPhase;")
        w.add("\t\t\tbuildActionMask = 2147483647;")
        w.add("\t\t\tfiles = (")
        for bf, path in sorted(build_files[target], key=lambda item: item[1].name):
            w.add(f"\t\t\t\t{bf} /* {path.name} in Sources */,")
        w.add("\t\t\t);")
        w.add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w.add("\t\t};")
    w.add("/* End PBXSourcesBuildPhase section */")

    # ---- PBXTargetDependency -------------------------------------------
    w.add("")
    w.add("/* Begin PBXTargetDependency section */")
    for test_target in (UNIT_TARGET, UI_TARGET):
        w.add(f"\t\t{uid(f'dependency:{test_target}')} /* PBXTargetDependency */ = {{")
        w.add("\t\t\tisa = PBXTargetDependency;")
        w.add(f"\t\t\ttarget = {target_uids[APP_TARGET]} /* {APP_TARGET} */;")
        w.add(f"\t\t\ttargetProxy = {uid(f'proxy:{test_target}')} /* PBXContainerItemProxy */;")
        w.add("\t\t};")
    w.add("/* End PBXTargetDependency section */")

    # ---- XCBuildConfiguration -------------------------------------------
    w.add("")
    w.add("/* Begin XCBuildConfiguration section */")
    for scope, configs in build_configurations(target_uids).items():
        for config_name, settings in configs.items():
            w.add(f"\t\t{uid(f'config:{scope}:{config_name}')} /* {config_name} */ = {{")
            w.add("\t\t\tisa = XCBuildConfiguration;")
            w.add("\t\t\tbuildSettings = {")
            for key in sorted(settings):
                value = settings[key]
                if isinstance(value, list):
                    w.add(f"\t\t\t\t{key} = (")
                    for entry in value:
                        w.add(f"\t\t\t\t\t{q(entry)},")
                    w.add("\t\t\t\t);")
                else:
                    w.add(f"\t\t\t\t{key} = {q(value)};")
            w.add("\t\t\t};")
            w.add(f"\t\t\tname = {config_name};")
            w.add("\t\t};")
    w.add("/* End XCBuildConfiguration section */")

    # ---- XCConfigurationList ---------------------------------------------
    w.add("")
    w.add("/* Begin XCConfigurationList section */")
    for scope in ["project"] + list(SOURCE_ROOTS):
        owner = f'PBXProject "{PROJECT_NAME}"' if scope == "project" else f'PBXNativeTarget "{scope}"'
        w.add(f"\t\t{uid(f'configlist:{scope}')} /* Build configuration list for {owner} */ = {{")
        w.add("\t\t\tisa = XCConfigurationList;")
        w.add("\t\t\tbuildConfigurations = (")
        for config_name in ("Debug", "Release"):
            w.add(f"\t\t\t\t{uid(f'config:{scope}:{config_name}')} /* {config_name} */,")
        w.add("\t\t\t);")
        w.add("\t\t\tdefaultConfigurationIsVisible = 0;")
        w.add("\t\t\tdefaultConfigurationName = Release;")
        w.add("\t\t};")
    w.add("/* End XCConfigurationList section */")

    w.add("\t};")
    w.add(f"\trootObject = {project_uid} /* Project object */;")
    w.add("}")
    return w.render()


def build_configurations(target_uids: dict[str, str]) -> dict[str, dict[str, dict]]:
    shared = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
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
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
    }

    project_debug = dict(shared)
    project_debug.update(
        {
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        }
    )

    project_release = dict(shared)
    project_release.update(
        {
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "VALIDATE_PRODUCT": "YES",
        }
    )

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        # Previews stay on, but the app must be one ordinary binary: Xcode
        # otherwise ships a stub executable plus <Product>.debug.dylib, and a
        # unit-test bundle that binds against TEST_HOST then cannot resolve the
        # app's symbols. That fails as an opaque trap before XCTest connects.
        "ENABLE_DEBUG_DYLIB": "NO",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Holograph/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_MODULE_NAME": APP_TARGET,
        "PRODUCT_NAME": APP_TARGET,
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "2",
    }

    unit_common = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "LD_RUNPATH_SEARCH_PATHS": [
            "$(inherited)",
            "@executable_path/Frameworks",
            "@loader_path/Frameworks",
        ],
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TARGETED_DEVICE_FAMILY": "2",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP_TARGET}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP_TARGET}",
    }

    ui_common = {
        "CODE_SIGN_STYLE": "Automatic",
        "LD_RUNPATH_SEARCH_PATHS": [
            "$(inherited)",
            "@executable_path/Frameworks",
            "@loader_path/Frameworks",
        ],
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.uitests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TARGETED_DEVICE_FAMILY": "2",
        "TEST_TARGET_NAME": APP_TARGET,
    }

    return {
        "project": {"Debug": project_debug, "Release": project_release},
        APP_TARGET: {"Debug": dict(app_common), "Release": dict(app_common)},
        UNIT_TARGET: {"Debug": dict(unit_common), "Release": dict(unit_common)},
        UI_TARGET: {"Debug": dict(ui_common), "Release": dict(ui_common)},
    }


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_uid}"
               BuildableName = "Holograph.app"
               BlueprintName = "Holograph"
               ReferencedContainer = "container:Holograph.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{unit_uid}"
               BuildableName = "HolographTests.xctest"
               BlueprintName = "HolographTests"
               ReferencedContainer = "container:Holograph.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_uid}"
               BuildableName = "HolographUITests.xctest"
               BlueprintName = "HolographUITests"
               ReferencedContainer = "container:Holograph.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_uid}"
            BuildableName = "Holograph.app"
            BlueprintName = "Holograph"
            ReferencedContainer = "container:Holograph.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_uid}"
            BuildableName = "Holograph.app"
            BlueprintName = "Holograph"
            ReferencedContainer = "container:Holograph.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def main() -> int:
    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    (project_dir / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)

    (project_dir / "project.pbxproj").write_text(build(), encoding="utf-8")

    (project_dir / "xcshareddata" / "xcschemes" / f"{PROJECT_NAME}.xcscheme").write_text(
        SCHEME.format(
            app_uid=uid(f"target:{APP_TARGET}"),
            unit_uid=uid(f"target:{UNIT_TARGET}"),
            ui_uid=uid(f"target:{UI_TARGET}"),
        ),
        encoding="utf-8",
    )

    workspace = project_dir / "project.xcworkspace"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace\n'
        '   version = "1.0">\n'
        '   <FileRef\n'
        '      location = "self:">\n'
        '   </FileRef>\n'
        '</Workspace>\n',
        encoding="utf-8",
    )

    print(f"wrote {project_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
