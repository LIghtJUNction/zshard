PYTHON ?= python3
.PHONY: check bench
check:
	$(PYTHON) tests/test_runtime.py
bench:
	$(PYTHON) scripts/benchmark.py --output artifacts/benchmark.json
