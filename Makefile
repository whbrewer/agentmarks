# agentmarks — bashmarks-style install.
#   make install     install to ~/.local/bin (override with PREFIX=...)
#   make uninstall   remove it

PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin

install:
	install -d $(BINDIR)
	install -m 644 agentmarks.sh $(BINDIR)/agentmarks.sh
	install -m 755 xs $(BINDIR)/xs
	ln -sf xs $(BINDIR)/xg
	ln -sf xs $(BINDIR)/xl
	ln -sf xs $(BINDIR)/xd
	@echo ''
	@echo 'Installed to $(BINDIR).'
	@echo 'For the full xg (one that leaves your shell in the mark''s directory),'
	@echo 'add this to your ~/.bashrc — above the "not interactive" guard, so'
	@echo 'that `! xs` also works inside Claude Code sessions:'
	@echo ''
	@echo '  source $(BINDIR)/agentmarks.sh'

uninstall:
	rm -f $(BINDIR)/agentmarks.sh $(BINDIR)/xs $(BINDIR)/xg $(BINDIR)/xl $(BINDIR)/xd

.PHONY: install uninstall
