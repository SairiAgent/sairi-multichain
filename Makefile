PYTHON ?= python3
.PHONY: check
check:
	$(PYTHON) tools/check_repository.py
