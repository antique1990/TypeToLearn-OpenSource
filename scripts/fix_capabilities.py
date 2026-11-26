#!/usr/bin/env python3
"""Normalize nested target capabilities serialized as strings by XcodeGen 2.46.

Safe to rerun, and a no-op for XcodeGen versions that write nested dictionaries.
Only the two known LearnKeyboard App Group capability values are changed.
"""
import json
import re
import subprocess
from pathlib import Path

project = Path(__file__).resolve().parent.parent / 'LearnKeyboard.xcodeproj/project.pbxproj'
text = project.read_text()
pattern = r'SystemCapabilities = "\[\\"com\.apple\.ApplicationGroups\.iOS\\": \[\\"enabled\\": 1\]\]";'
replacement = '''SystemCapabilities = {
                            com.apple.ApplicationGroups.iOS = {
                                enabled = 1;
                            };
                        };'''
updated, count = re.subn(pattern, replacement, text)
if count:
    project.write_text(updated)

parsed = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))
objects = parsed['objects']
attributes = objects[parsed['rootObject']]['attributes']['TargetAttributes']
for target in objects[parsed['rootObject']]['targets']:
    if objects[target]['name'] in ('LearnKeyboard', 'LearnKeyboardExtension'):
        capability = attributes[target]['SystemCapabilities']
        assert isinstance(capability, dict), 'SystemCapabilities must be a dictionary'
        assert str(capability['com.apple.ApplicationGroups.iOS']['enabled']) == '1'
print(f'App Group capabilities verified; repaired {count} serialized values.')
