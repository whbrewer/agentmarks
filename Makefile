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

# Install the /mark skill into every Claude Code config dir (~/.claude*),
# so Claude can bookmark its own session with an auto-generated summary.
install-skill:
	@for d in $(HOME)/.claude $(HOME)/.claude-*; do \
	  [ -d $$d ] || continue; \
	  install -d $$d/skills/mark; \
	  install -m 644 skills/mark/SKILL.md $$d/skills/mark/SKILL.md; \
	  echo "installed /mark skill → $$d/skills/mark"; \
	done

uninstall-skill:
	rm -rf $(HOME)/.claude/skills/mark $(HOME)/.claude-*/skills/mark

.PHONY: install uninstall install-skill uninstall-skill
