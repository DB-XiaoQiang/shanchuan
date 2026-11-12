#!/usr/bin/env python3
"""Release tags are deliberately strict: all platforms share VERSION."""
import pathlib
import re
import sys
version = (pathlib.Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or sys.argv[1:] != ['v' + version]:
    sys.exit('标签必须等于 v + VERSION，且版本号为 x.y.z。')
print(version)
