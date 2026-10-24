PYTHON ?= python3

.PHONY: docs test test-async

docs:
	$(PYTHON) scripts/vimdoc2md.py doc/vim-rest-console.txt doc/vim-rest-console.md

test:
	vim -Nu NONE -n -es -S test/run.vim

test-async:
	vim -Nu NONE -n -es -S test/async.vim
