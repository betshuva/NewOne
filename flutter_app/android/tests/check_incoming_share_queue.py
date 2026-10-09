#!/usr/bin/env python3
"""Run the durable sharing queue checks using the cached Kotlin compiler; no APK."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

cache = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle"))) / "caches/modules-2/files-2.1"
version = os.environ.get("SHARE_CHECK_KOTLIN_VERSION", "2.2.20")


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
with tempfile.TemporaryDirectory(prefix="betshuva-share-check-") as temporary:
    classes = Path(temporary) / "classes"
    subprocess.run([
        java, "-cp", os.pathsep.join(compiler_dependencies),
        "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
        "-jvm-target", "17", "-classpath", stdlib, "-d", str(classes),
        str(android / "app/src/main/kotlin/com/betshuva/app/IncomingShareQueue.kt"),
        str(android / "tests/IncomingShareQueueCheck.kt"),
    ], check=True)
    subprocess.run([
        java, "-cp", os.pathsep.join([str(classes), stdlib]), "IncomingShareQueueCheckKt",
    ], check=True)
