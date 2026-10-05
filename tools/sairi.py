"""Launcher: `python3.12 tools/sairi.py <command> ...` (see `--help`). Offline, standard library only."""
import sys

from sairi_tools.cli import main

if __name__ == "__main__":
    sys.exit(main())
