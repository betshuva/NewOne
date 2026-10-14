#!/usr/bin/env python3
"""Compile the actual map WebView callback with test fakes; no APK or network.

MAP_PREVIEW_HTML_OUT optionally exports the production-generated wrapper for
an independent browser check. --source can select a frozen regression baseline.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, help="Alternate LocationMapPreview.kt, for a frozen baseline")
parser.add_argument("--case", help="Run one named callback case")
arguments = parser.parse_args()

cache = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle"))) / "caches/modules-2/files-2.1"
version = os.environ.get("MAP_CHECK_KOTLIN_VERSION", "2.2.20")


def jar(group, module, release=None):
    location = cache / group / module
    if release:
        location /= release
    matches = sorted(location.rglob("*.jar"))
    if not matches:
        raise SystemExit(f"Missing cached compiler dependency: {group}/{module}/{release or '*'}")
    return str(matches[-1])


java = str(Path(os.environ["JAVA_HOME"]) / "bin/java") if os.environ.get("JAVA_HOME") else shutil.which("java")
if not java:
    raise SystemExit("Set JAVA_HOME to a Java 17 or newer JDK.")
stdlib = jar("org.jetbrains.kotlin", "kotlin-stdlib", version)
compiler_dependencies = [
    jar("org.jetbrains.kotlin", "kotlin-compiler-embeddable", version),
    stdlib,
    jar("org.jetbrains.kotlin", "kotlin-script-runtime", version),
    jar("org.jetbrains.kotlin", "kotlin-reflect"),
    jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm"),
    jar("org.jetbrains", "annotations"),
]
android = Path(__file__).resolve().parent.parent
source = arguments.source or android / "app/src/main/kotlin/com/betshuva/app/LocationMapPreview.kt"
if not source.is_file():
    raise SystemExit(f"Missing Kotlin source: {source}")
fakes = sorted((android / "tests/location_map_preview_fakes").glob("*.kt"))
with tempfile.TemporaryDirectory(prefix="betshuva-map-preview-check-") as temporary:
    classes = Path(temporary) / "classes"
    subprocess.run([
        java, "-cp", os.pathsep.join(compiler_dependencies),
        "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
        "-jvm-target", "17", "-classpath", stdlib, "-d", str(classes),
        str(source), str(android / "tests/LocationMapPreviewCheck.kt"),
        *(str(fake) for fake in fakes),
    ], check=True)
    result = subprocess.run([
        java, "-cp", os.pathsep.join([str(classes), stdlib]), "LocationMapPreviewCheckKt",
        *([arguments.case] if arguments.case else []),
    ])
    raise SystemExit(result.returncode)
