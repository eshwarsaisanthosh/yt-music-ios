#!/usr/bin/env python3
"""Generate YTMusic.xcodeproj/project.pbxproj.

Xcode projects are just a plist-ish object graph. This script emits a minimal
but valid project for the SwiftUI app: one app target, all Swift sources in
the Sources build phase, Assets.xcassets in Resources, Debug/Release configs.

Re-run after adding/removing source files:
    python3 generate_project.py
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = "YTMusic"
PROJECT_DIR = os.path.join(ROOT, f"{APP}.xcodeproj")

SOURCES = [
    "YTMusicApp.swift",
    "Config/AppConfig.swift",
    "Models/Models.swift",
    "Services/APIClient.swift",
    "Services/PlaybackEngine.swift",
    "Services/DownloadManager.swift",
    "Services/LibraryStore.swift",
    "Views/Components.swift",
    "Views/ContentView.swift",
    "Views/LibraryView.swift",
    "Views/PlaylistsView.swift",
    "Views/SearchView.swift",
    "Views/AddVideoView.swift",
    "Views/PlayerViews.swift",
    "Views/SettingsView.swift",
]

RESOURCES = [
    "Resources/Assets.xcassets",
]

# ---------------------------------------------------------------------------
# Deterministic 24-char hex IDs (Xcode's format), stable across regenerations.
# ---------------------------------------------------------------------------

def uid(*parts: str) -> str:
    h = hashlib.sha1("\x00".join(parts).encode()).hexdigest().upper()
    return h[:24]


def q(s: str) -> str:
    return s  # paths here need no quoting


def main() -> None:
    missing = [s for s in SOURCES if not os.path.exists(os.path.join(ROOT, APP, s))]
    if missing:
        sys.exit(f"missing source files: {missing}")

    build_files = {}
    file_refs = {}
    for s in SOURCES:
        p = f"{APP}/{s}"
        bf = uid("buildfile", p)
        fr = uid("fileref", p)
        build_files[bf] = (fr, os.path.basename(s))
        file_refs[fr] = (p, "sourcecode.swift", os.path.basename(s))
    for r in RESOURCES:
        p = f"{APP}/{r}"
        bf = uid("buildfile", p)
        fr = uid("fileref", p)
        build_files[bf] = (fr, os.path.basename(r))
        file_refs[fr] = (p, "folder.assetcatalog", os.path.basename(r))
    # Info.plist reference (not a build file; referenced via INFOPLIST_FILE).
    plist_ref = uid("fileref", f"{APP}/Info.plist")
    file_refs[plist_ref] = (f"{APP}/Info.plist", "text.plist.xml", "Info.plist")

    # IDs for structural objects.
    ids = {k: uid("obj", k) for k in [
        "project", "mainGroup", "appGroup", "configGroup", "modelsGroup",
        "servicesGroup", "viewsGroup", "resourcesGroup", "productsGroup",
        "target", "sourcesPhase", "resourcesPhase", "frameworksPhase",
        "projectConfigList", "targetConfigList",
        "projectDebug", "projectRelease", "targetDebug", "targetRelease",
        "appProduct",
    ]}

    L = []
    A = L.append

    def section(name: str) -> None:
        A(f"\n/* Begin {name} section */")

    def end_section(name: str) -> None:
        A(f"/* End {name} section */")

    A("// !$*UTF8*$!")
    A("{")
    A("\tarchiveVersion = 1;")
    A("\tclasses = {")
    A("\t};")
    A("\tobjectVersion = 77;")
    A("\tobjects = {")

    # ---- PBXBuildFile ----
    section("PBXBuildFile")
    for bf, (fr, name) in sorted(build_files.items()):
        A(f"\t\t{bf} /* {name} in {'Sources' if name.endswith('.swift') else 'Resources'} */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    end_section("PBXBuildFile")

    # ---- PBXFileReference ----
    section("PBXFileReference")
    for fr, (path, ftype, name) in sorted(file_refs.items()):
        A(f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {q(path)}; sourceTree = \"<group>\"; }};")
    app_product = ids["appProduct"]
    A(f"\t\t{app_product} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    end_section("PBXFileReference")

    # ---- PBXFrameworksBuildPhase (empty; Swift auto-links on import) ----
    section("PBXFrameworksBuildPhase")
    A(f"\t\t{ids['frameworksPhase']} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
    end_section("PBXFrameworksBuildPhase")

    # ---- PBXGroup ----
    section("PBXGroup")

    def group(gid: str, name: str, children: list[str], path: str | None = None) -> None:
        kids = ", ".join(f"{c}" for c in children)
        path_part = f"path = {path}; " if path else ""
        A(f"\t\t{gid} /* {name} */ = {{isa = PBXGroup; children = ({kids}, ); {path_part}sourceTree = \"<group>\"; }};")

    def child_refs(prefix: str, files: list[str]) -> list[str]:
        out = []
        for f in files:
            p = f"{APP}/{f}"
            out.append(f"{uid('fileref', p)} /* {os.path.basename(f)} */")
        return out

    src_by_dir: dict[str, list[str]] = {}
    for s in SOURCES:
        d, _ = os.path.split(s)
        src_by_dir.setdefault(d, []).append(s)

    group(ids["configGroup"], "Config", child_refs("", src_by_dir.get("Config", [])), "Config")
    group(ids["modelsGroup"], "Models", child_refs("", src_by_dir.get("Models", [])), "Models")
    group(ids["servicesGroup"], "Services", child_refs("", src_by_dir.get("Services", [])), "Services")
    group(ids["viewsGroup"], "Views", child_refs("", src_by_dir.get("Views", [])), "Views")
    group(ids["resourcesGroup"], "Resources",
          [f"{uid('fileref', APP + '/' + r)} /* {os.path.basename(r)} */" for r in RESOURCES], "Resources")

    top_level_swift = [s for s in SOURCES if "/" not in s]
    app_children = (
        [f"{uid('fileref', APP + '/' + s)} /* {os.path.basename(s)} */" for s in top_level_swift]
        + [f"{uid('fileref', APP + '/Info.plist')} /* Info.plist */"]
        + [f"{ids['configGroup']} /* Config */", f"{ids['modelsGroup']} /* Models */",
           f"{ids['servicesGroup']} /* Services */", f"{ids['viewsGroup']} /* Views */",
           f"{ids['resourcesGroup']} /* Resources */"]
    )
    group(ids["appGroup"], APP, app_children, APP)
    group(ids["productsGroup"], "Products", [f"{app_product} /* {APP}.app */"])
    group(ids["mainGroup"], "main", [f"{ids['appGroup']} /* {APP} */", f"{ids['productsGroup']} /* Products */"])
    end_section("PBXGroup")

    # ---- PBXNativeTarget ----
    section("PBXNativeTarget")
    t = ids["target"]
    A(f"\t\t{t} /* {APP} */ = {{isa = PBXNativeTarget; buildConfigurationList = {ids['targetConfigList']} /* Build configuration list for PBXNativeTarget \"{APP}\" */; buildPhases = (")
    A(f"\t\t\t{ids['sourcesPhase']} /* Sources */,")
    A(f"\t\t\t{ids['frameworksPhase']} /* Frameworks */,")
    A(f"\t\t\t{ids['resourcesPhase']} /* Resources */,")
    A("\t\t);")
    A(f"\t\t\tbuildRules = ();")
    A(f"\t\t\tdependencies = ();")
    A(f"\t\t\tname = {APP};")
    A(f"\t\t\tproductName = {APP};")
    A(f"\t\t\tproductReference = {app_product} /* {APP}.app */;")
    A(f"\t\t\tproductType = \"com.apple.product-type.application\";")
    A("\t\t};")
    end_section("PBXNativeTarget")

    # ---- PBXProject ----
    section("PBXProject")
    p = ids["project"]
    A(f"\t\t{p} /* Project object */ = {{")
    A("\t\t\tisa = PBXProject;")
    A(f"\t\t\tbuildConfigurationList = {ids['projectConfigList']} /* Build configuration list for PBXProject \"{APP}\" */;")
    A("\t\t\tcompatibilityVersion = \"Xcode 15.0\";")
    A("\t\t\tdevelopmentRegion = en;")
    A("\t\t\thasScannedForEncodings = 0;")
    A("\t\t\tknownRegions = (en, Base, );")
    A(f"\t\t\tmainGroup = {ids['mainGroup']};")
    A(f"\t\t\tproductRefGroup = {ids['productsGroup']} /* Products */;")
    A("\t\t\tprojectDirPath = \"\";")
    A("\t\t\tprojectRoot = \"\";")
    A("\t\t\ttargets = (")
    A(f"\t\t\t\t{t} /* {APP} */,")
    A("\t\t\t);")
    A("\t\t};")
    end_section("PBXProject")

    # ---- PBXResourcesBuildPhase ----
    section("PBXResourcesBuildPhase")
    res_files = ", ".join(
        f"{bf} /* {os.path.basename(r)} in Resources */"
        for bf, (fr, name) in sorted(build_files.items())
        for r in RESOURCES if name == os.path.basename(r)
    )
    A(f"\t\t{ids['resourcesPhase']} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({res_files}, ); runOnlyForDeploymentPostprocessing = 0; }};")
    end_section("PBXResourcesBuildPhase")

    # ---- PBXSourcesBuildPhase ----
    section("PBXSourcesBuildPhase")
    src_files = ", ".join(
        f"{bf} /* {os.path.basename(s)} in Sources */"
        for bf, (fr, name) in sorted(build_files.items())
        for s in SOURCES if name == os.path.basename(s)
    )
    A(f"\t\t{ids['sourcesPhase']} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({src_files}, ); runOnlyForDeploymentPostprocessing = 0; }};")
    end_section("PBXSourcesBuildPhase")

    # ---- XCBuildConfiguration ----
    section("XCBuildConfiguration")

    def xcconfig(cid: str, name: str, settings: dict[str, str]) -> None:
        A(f"\t\t{cid} /* {name} */ = {{")
        A("\t\t\tisa = XCBuildConfiguration;")
        A("\t\t\tbuildSettings = {")
        for k, v in settings.items():
            A(f"\t\t\t\t{k} = {v};")
        A("\t\t\t};")
        A(f"\t\t\tname = {name};")
        A("\t\t};")

    xcconfig(ids["projectDebug"], "Debug", {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    xcconfig(ids["projectRelease"], "Release", {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
    })

    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": '""',
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP}/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "CURRENT_PROJECT_VERSION": "1",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.YTMusic",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
    }
    xcconfig(ids["targetDebug"], "Debug", target_common)
    xcconfig(ids["targetRelease"], "Release", target_common)
    end_section("XCBuildConfiguration")

    # ---- XCConfigurationList ----
    section("XCConfigurationList")
    A(f"\t\t{ids['projectConfigList']} /* Build configuration list for PBXProject \"{APP}\" */ = {{")
    A("\t\t\tisa = XCConfigurationList;")
    A(f"\t\t\tbuildConfigurations = ({ids['projectDebug']} /* Debug */, {ids['projectRelease']} /* Release */, );")
    A("\t\t\tdefaultConfigurationIsVisible = 0;")
    A("\t\t\tdefaultConfigurationName = Release;")
    A("\t\t};")
    A(f"\t\t{ids['targetConfigList']} /* Build configuration list for PBXNativeTarget \"{APP}\" */ = {{")
    A("\t\t\tisa = XCConfigurationList;")
    A(f"\t\t\tbuildConfigurations = ({ids['targetDebug']} /* Debug */, {ids['targetRelease']} /* Release */, );")
    A("\t\t\tdefaultConfigurationIsVisible = 0;")
    A("\t\t\tdefaultConfigurationName = Release;")
    A("\t\t};")
    end_section("XCConfigurationList")

    A("\t};")
    A(f"\trootObject = {p} /* Project object */;")
    A("}")

    os.makedirs(PROJECT_DIR, exist_ok=True)
    out_path = os.path.join(PROJECT_DIR, "project.pbxproj")
    with open(out_path, "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
