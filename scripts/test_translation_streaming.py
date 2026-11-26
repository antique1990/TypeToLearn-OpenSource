#!/usr/bin/env python3
"""Compile real TranslationService with a controlled API double on native macOS.

This is an isolated unit test, not an iOS runtime or device validation. All build
output is temporary; no downloaded language assets or network access are needed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests/TranslationServiceTests"


def run(*args, timeout=90):
    subprocess.run(args, check=True, cwd=ROOT, timeout=timeout)


with tempfile.TemporaryDirectory(prefix="translation-stream-tests-") as temporary:
    build = Path(temporary)
    swift = ["xcrun", "swiftc", "-swift-version", "6",
             "-module-cache-path", str(build / "module-cache")]
    core = ROOT / "Sources/KeyboardCore"
    run(*swift, "-emit-module", "-emit-library", "-static", "-module-name", "KeyboardCore",
        "-emit-module-path", str(build / "KeyboardCore.swiftmodule"),
        "-o", str(build / "libKeyboardCore.a"),
        *[str(core / name) for name in ["BoundedCache.swift", "TranslationText.swift",
                                      "LearnedWords.swift", "KeyboardTypes.swift", "Composition.swift"]])
    run(*swift, "-emit-module", "-emit-library", "-static", "-module-name", "Translation",
        "-emit-module-path", str(build / "Translation.swiftmodule"),
        "-o", str(build / "libTranslation.a"), str(FIXTURES / "TranslationDouble.swift"))
    executable = build / "translation-service-tests"
    run(*swift, "-parse-as-library", "-I", str(build), "-L", str(build),
        "-lKeyboardCore", "-lTranslation", str(ROOT / "Shared/TranslationService.swift"),
        str(FIXTURES / "TranslationServiceTests.swift"), "-o", str(executable))
    # A missing callback fails with a bounded timeout instead of hanging CI.
    run(str(executable), timeout=20)
